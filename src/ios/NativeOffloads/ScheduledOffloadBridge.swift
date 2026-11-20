//
//  ScheduledOffloadBridge.swift
//  MinisApp
//
//  Swift bridge for the `minis-scheduled` offload (T-p2-minis-scheduled).
//  Parses the CLI's argument bag into an AgentJob, arms it via
//  ScheduledJobRunner, and answers with the same JSON shapes Android's
//  ScheduledTaskOffloadHandler emits so a Skill written on one platform
//  reads the same fields on the other.
//

import Foundation

private let logger = AppLogger(category: "ScheduledOffload")

@objc public class ScheduledOffloadBridge: NSObject {

    /// Blocking helper: the offload handler runs on the iSH guest thread,
    /// never on main, so a semaphore around a main-actor Task is safe here.
    private static func onMain<T>(_ body: @escaping @MainActor () async -> T) -> T? {
        let sem = DispatchSemaphore(value: 0)
        var out: T!
        Task { @MainActor in
            out = await body()
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时直接返回 nil：旧代码只 NSLog 一句，然后 `return out`，
            // 此时 out 仍是未赋值的 T!，强解包当场崩。调用方拿到 nil 会走
            // 各自的失败分支（字典返回值转成 ok:false，Bool 当失败）。
            NSLog("[CLIBridge] semaphore wait timed out")
            return nil
        }
        return out
    }

    // MARK: - [persona] F3: caller identification and enforcement

    /// The session whose shell invoked this CLI call, resolved from the
    /// invoking shell's own fs_context (same mechanism as F6-a), falling back
    /// to the mounted-session snapshot when no per-command context was
    /// captured. Captured at the @objc entry point, on the guest thread,
    /// before the hop to @MainActor — the thread-local record belongs to
    /// that thread. Using the same session for target resolution and persona
    /// stamping keeps the two from disagreeing under a mount race.
    private static func callerSessionId() -> String? {
        MinisFsRouter.shared.sid(for: MinisFsRouter.callingFsContext())
            ?? ISHExecutionCoordinator.mountedSessionIdSnapshot
    }

    /// [persona] F3: who is calling, three states. `noSession` is the
    /// management view (the command ran outside any chat, like the in-app
    /// task list — unfiltered by design). `lookupFailed` means a session id
    /// was present but its persona could not be read (prepare error / row
    /// gone): fail closed, never the management view — a DB error must not
    /// silently widen what the caller can see or change.
    private enum CallerPersona {
        case persona(String)
        case noSession
        case lookupFailed
    }

    /// The persona of the session whose shell invoked this call. `noSession`
    /// = no session context (the command ran outside any chat); enforcement
    /// is skipped only then. `lookupFailed` = a session was present but its
    /// persona could not be read — callers must fail closed on it.
    @MainActor
    private static func callerPersona(invokingFsContext: UInt64) async -> CallerPersona {
        let sid = MinisFsRouter.shared.sid(for: invokingFsContext)
            ?? ISHExecutionCoordinator.mountedSessionIdSnapshot
        guard let sid, !sid.isEmpty else { return .noSession }
        guard let pid = await ChatStore.shared.personaId(for: sid) else { return .lookupFailed }
        return .persona(pid)
    }

    /// nil = allowed (the job belongs to the caller, or the caller has no
    /// session context — the management view). Otherwise an explicit
    /// cross-persona error, never a silent no-op or a filtered-out row.
    /// A failed caller lookup is denied, not treated as "no session context".
    @MainActor
    private static func crossPersonaError(job: AgentJob, caller: CallerPersona) async -> NSDictionary? {
        switch caller {
        case .noSession:
            return nil
        case .lookupFailed:
            return ["ok": false, "error": "persona_lookup_failed",
                    "message": "could not determine the persona of the calling session; nothing was changed."] as NSDictionary
        case .persona(let pid):
            let owner = await AgentJobRegistry.shared.ensurePersonaId(job)
            guard owner != pid else { return nil }
            return ["ok": false, "error": "cross_persona",
                    "message": "task \(job.id.prefix(8)) belongs to persona \"\(owner)\"; it cannot be changed from persona \"\(pid)\". Use the task list in the app to manage another persona's tasks."] as NSDictionary
        }
    }

    /// [persona] F3: outcome of checking a job's target session against the
    /// caller. `allowed` carries the resolved personas (nil when there was
    /// no session context / no target session) so the caller can stamp the
    /// job from them without re-resolving.
    private enum TargetPersonaCheck {
        case allowed(callerPersonaId: String?, targetPersonaId: String?)
        case refused(NSDictionary)
    }

    /// [persona] F3: a job's target session must belong to the caller's
    /// persona. No caller session context (management view) → no check.
    /// Either lookup failing (session row gone / DB error) → refuse: a
    /// missing persona is never read as "another persona is fine". The
    /// caller is resolved FIRST so a `.new` target cannot be stamped
    /// "default" on a lookup failure either.
    @MainActor
    private static func checkTargetPersona(target: AgentJobTarget, callerSessionId: String?) async -> TargetPersonaCheck {
        var callerPid: String? = nil
        if let callerSid = callerSessionId {
            guard let resolved = await ChatStore.shared.personaId(for: callerSid) else {
                return .refused(["ok": false, "error": "persona_lookup_failed",
                                 "message": "the calling session has no readable persona; nothing was changed."] as NSDictionary)
            }
            callerPid = resolved
        }
        let targetSid: String? = {
            switch target {
            case .new: return nil
            case .followUp(let sid): return sid
            case .rerun(let sid, _): return sid
            case .childOfCurrent(let parent, _): return parent
            }
        }()
        guard let targetSid else { return .allowed(callerPersonaId: callerPid, targetPersonaId: nil) }
        guard let targetPid = await ChatStore.shared.personaId(for: targetSid) else {
            return .refused(["ok": false, "error": "persona_lookup_failed",
                             "message": "target session \(targetSid.prefix(8)) has no readable persona (it may have been deleted); nothing was changed."] as NSDictionary)
        }
        if let callerPid, targetPid != callerPid {
            return .refused(["ok": false, "error": "cross_persona",
                             "message": "target session \(targetSid.prefix(8)) belongs to persona \"\(targetPid)\"; it cannot be targeted from persona \"\(callerPid)\". Use the task list in the app to manage another persona's tasks."] as NSDictionary)
        }
        return .allowed(callerPersonaId: callerPid, targetPersonaId: targetPid)
    }

    // MARK: - create

    /// `args` carries the raw CLI strings (nil when absent). Returns either
    /// `{created: <job>}` or `{ok:false, error, message}`.
    @objc public static func create(args: NSDictionary) -> NSDictionary {
        func str(_ k: String) -> String? {
            guard let v = args[k] as? String, !v.isEmpty else { return nil }
            return v
        }
        let prompt = str("prompt") ?? ""
        let label = str("label")
        let modelEntryId = str("model")
        // [T-scheduled-thinking-level] Validated here rather than silently
        // coerced: a typo like `--thinking hgih` must not quietly run the job
        // at `off` for the rest of its schedule.
        var thinkingLevel: ThinkingLevel? = nil
        if let raw = str("thinking") {
            let parsed = ThinkingLevel.decoded(raw)
            guard parsed.rawValue.caseInsensitiveCompare(raw) == .orderedSame else {
                return error("--thinking must be one of: off, low, medium, high, xhigh")
            }
            thinkingLevel = parsed
        }
        let disabled = (args["disabled"] as? Bool) ?? false
        let isPulse = (args["pulse"] as? Bool) ?? false

        // ── Prefilled Tool ──────────────────────────────────────────────
        var prefilledTool: PrefilledToolCall? = nil
        if let cmd = str("command") {
            let timeout = str("timeout").flatMap { Int($0) }
            let toolName = str("tool") ?? "shell_execute"
            let argsObj: [String: Any] = ["command": cmd, "tool_title": label ?? String(cmd.prefix(40))]
            let argsData = try? JSONSerialization.data(withJSONObject: argsObj)
            prefilledTool = PrefilledToolCall(toolName: toolName,
                                             argsJson: String(data: argsData ?? Data(), encoding: .utf8) ?? "{}",
                                             timeoutSec: timeout)
        } else if let tool = str("tool") {
            let argsJson = str("toolArgs") ?? "{}"
            let timeout = str("timeout").flatMap { Int($0) }
            prefilledTool = PrefilledToolCall(toolName: tool, argsJson: argsJson, timeoutSec: timeout)
        }

        // [AUD-08] Only shell tools can actually be prefilled today —
        // `PrefilledToolCall.shellCommand` returns nil for anything else, and
        // the fire path then silently skips the prefill. That made
        // `--tool weather …` a task that looked created (receipt, `list`, the
        // stored prefilledTool) and then quietly ran nothing. Say so at create
        // time instead, where the caller can still act on it.
        if let prefill = prefilledTool, prefill.shellCommand == nil {
            return error("--tool \(prefill.toolName) is not supported: scheduled prefill runs shell commands only (shell_execute / sh / shell / bash). Drop --tool to use shell_execute, or pass --tool shell_execute with --toolArgs '{\"command\": \"…\"}'.")
        }

        // ── Target ───────────────────────────────────────────────────────
        // [persona] F3: the caller session comes from the invoking shell's
        // own fs_context (see callerSessionId), not the snapshot alone —
        // the persona stamp below must come from the same session the
        // target resolves from, or the two can disagree under a mount race.
        let callerSid = Self.callerSessionId()
        let explicitTarget = str("target")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let targetRaw: String
        let isTargetDefaulted: Bool
        if let exp = explicitTarget, !exp.isEmpty {
            targetRaw = exp
            isTargetDefaulted = false
        } else {
            // Intelligent follow-up targeting when running inside a chat
            if callerSid != nil || str("session") != nil {
                targetRaw = "follow-up"
            } else {
                targetRaw = "new"
            }
            isTargetDefaulted = true
        }

        let target: AgentJobTarget
        let deliverySentence: String
        switch targetRaw {
        case "new":
            target = .new
            let titled = label.map { " titled “Scheduled · \($0)”" } ?? ""
            deliverySentence = "Delivery: each fire opens a NEW separate chat\(titled); the result will NOT appear in this conversation." +
                (isTargetDefaulted ? " Target defaulted to new because no chat was running this command." : "")
        case "follow-up", "followup", "append":
            guard let sid = str("session") ?? callerSid else {
                return error("--session required for follow-up target (or run from inside a session)")
            }
            target = .followUp(sessionId: sid)
            let isThisChat = (sid == callerSid)
            deliverySentence = isThisChat
                ? "Delivery: each fire runs as a new turn IN THIS CHAT (session \(sid.prefix(8)))." +
                    (isTargetDefaulted ? " Target defaulted to follow-up because this command ran inside a chat; use --target new for a separate chat." : "")
                : "Delivery: each fire runs as a new turn in session \(sid.prefix(8)), NOT in this conversation."
        case "rerun":
            guard let sid = str("session") ?? callerSid else { return error("--session required for rerun target") }
            guard let mid = str("message") else { return error("--message required for rerun target") }
            target = .rerun(sessionId: sid, messageId: mid)
            deliverySentence = "Delivery: each fire RE-RUNS user message \(mid.prefix(8)) in session \(sid.prefix(8))."
        case "child-of-current", "child":
            guard AgentToolSwitch.agents.isEnabled else {
                return error("child-of-current is unavailable: Sub Agents are turned off in Settings › Agent Tools. Use --target new or follow-up.")
            }
            guard let sid = str("session") ?? callerSid else {
                return error("child-of-current needs a current session: run this from a chat, or pass --session")
            }
            target = .childOfCurrent(parentSessionId: sid, parentToolUseId: nil)
            deliverySentence = "Delivery: each fire spawns a hidden helper under session \(sid.prefix(8)); its result is posted back here when finished."
        default:
            return error("--target must be new|follow-up|rerun|child-of-current")
        }
        if case .rerun = target {} else if prompt.isEmpty {
            return error("--prompt required (except for rerun target)")
        }

        // ── Trigger (explicit --trigger, else inferred from the given args) ──
        let triggerRaw = str("trigger")?.lowercased()
            ?? (str("after") != nil ? "once"
                : str("interval") != nil ? "loop"
                : str("time") != nil ? "cron"
                : str("of") != nil ? "on-completion"
                : nil)
        guard let triggerKind = triggerRaw else {
            return error("Give a trigger: --after <dur> (once), --interval <dur> [--count N] (loop), --time HH:MM [--repeat …] (cron), or --trigger on-completion --of <jobId>")
        }
        let trigger: AgentJobTrigger
        var count: Int? = nil
        switch triggerKind {
        case "once":
            if let after = str("after") {
                guard let secs = ScheduledJobRunner.parseDuration(after), secs >= 1 else { return error("--after must be a duration like 30m, 2h, 90s") }
                trigger = .once(after: secs)
            } else if let time = str("time") {
                guard let (h, m) = parseTime(time) else { return error("--time must be HH:MM") }
                guard let next = ScheduledJobRunner.nextCronDate(hour: h, minute: m, days: [], start: nil, end: nil, from: Date()) else {
                    return error("no future occurrence of --time \(time)")
                }
                trigger = .once(after: next.timeIntervalSinceNow)
            } else {
                return error("once needs --after <duration> or --time HH:MM")
            }
        case "loop":
            guard let iv = str("interval"), let secs = ScheduledJobRunner.parseDuration(iv), secs >= 60 else {
                return error("--interval must be a duration of at least 60s (e.g. 10m)")
            }
            if let c = str("count") {
                guard let n = Int(c), n >= 1 else { return error("--count must be a positive integer") }
                count = n
            }
            trigger = .loop(interval: secs, count: count)
        case "cron":
            guard let time = str("time"), let (h, m) = parseTime(time) else { return error("--time HH:MM required for cron") }
            let repeatRaw = (str("repeat") ?? "daily").lowercased()
            let days: Set<Int>
            switch repeatRaw {
            case "once":
                guard let next = ScheduledJobRunner.nextCronDate(hour: h, minute: m, days: [], start: nil, end: nil, from: Date()) else {
                    return error("no future occurrence of --time \(time)")
                }
                trigger = .once(after: next.timeIntervalSinceNow)
                return finishCreate(prompt: prompt, label: label, trigger: trigger, target: target,
                                    modelEntryId: modelEntryId, thinkingLevel: thinkingLevel,
                                    creatorSessionId: callerSid, disabled: disabled,
                                    prefilledTool: prefilledTool, isPulse: isPulse,
                                    deliverySentence: deliverySentence)
            case "daily": days = Set(1...7)
            case "weekdays": days = Set(2...6)
            case "custom":
                guard let d = str("days"), let parsed = parseDays(d), !parsed.isEmpty else {
                    return error("--days required for custom repeat (e.g. mon,tue,fri)")
                }
                days = parsed
            default:
                return error("--repeat must be once|daily|weekdays|custom")
            }
            trigger = .cron(hour: h, minute: m, days: days,
                            start: str("start").flatMap(parseDate), end: str("end").flatMap(parseDate))
        case "on-completion", "oncompletion", "on_completion":
            guard let of = str("of") else { return error("--of <jobId> required for on-completion trigger") }
            trigger = .onCompletion(ofJobId: of)
        default:
            return error("--trigger must be once|loop|cron|on-completion")
        }
        return finishCreate(prompt: prompt, label: label, trigger: trigger, target: target,
                            modelEntryId: modelEntryId, thinkingLevel: thinkingLevel,
                            creatorSessionId: callerSid, disabled: disabled,
                            prefilledTool: prefilledTool, isPulse: isPulse,
                            deliverySentence: deliverySentence)
    }

    private static func finishCreate(prompt: String, label: String?, trigger: AgentJobTrigger,
                                     target: AgentJobTarget, modelEntryId: String?, thinkingLevel: ThinkingLevel?,
                                     creatorSessionId: String?, disabled: Bool,
                                     prefilledTool: PrefilledToolCall?, isPulse: Bool,
                                     deliverySentence: String) -> NSDictionary {
        onMain {
            let registry = AgentJobRegistry.shared
            // [persona] F3: target-session check + fail-closed stamping — the
            // job fires and lists as this persona from now on, whatever is
            // current later. Caller first, then target; "default" only when
            // the command ran with no session context at all.
            let personaId: String
            switch await Self.checkTargetPersona(target: target, callerSessionId: creatorSessionId) {
            case .refused(let err): return err
            case .allowed(let callerPid, let targetPid):
                personaId = callerPid ?? targetPid ?? PersonaStore.defaultPersonaID
            }
            let job = registry.register(title: label ?? String(prompt.prefix(40)), label: label,
                                        origin: .cli, trigger: trigger, target: target, prompt: prompt,
                                        personaId: personaId)
            job.modelEntryId = modelEntryId
            job.thinkingLevel = thinkingLevel
            job.creatorSessionId = creatorSessionId
            job.isEnabled = !disabled
            job.prefilledTool = prefilledTool
            job.isPulse = isPulse
            job.deliverySentence = deliverySentence
            ScheduledJobRunner.arm(job)
            logger.info("[minis-scheduled] created \(job.logLabel) (pulse=\(isPulse), delivery=\(deliverySentence))")
            var dict = registry.jobDict(job)
            dict["delivery"] = deliverySentence
            var out: [String: Any] = ["created": dict,
                    "delivery": deliverySentence,
                    "note": "Best effort: this timer lives only while the Minis app process is alive. A reminder notification is registered as insurance; for guaranteed background execution use an Apple Shortcuts automation."]
            if isPulse {
                // [T-scheduled-prefill-and-pulse] The model should confirm in its own voice,
                // not only report the CLI envelope; hand it the fact it can mention.
                out["pulse"] = true
                out["reply_hint"] = "This is a proactive pulse: fires are your own heartbeat, not a task report. Tell her you set it up in your own voice — what you might do with the free time — and she can tap the heart icon to see or poke it. Never announce reminders mechanically."
            }
            return out as NSDictionary
        } ?? ["ok": false, "error": "timeout",
              "message": "The app did not answer within 5s; nothing was changed."] as NSDictionary
    }

    // MARK: - list / delete / enable / run

    @objc public static func list() -> NSDictionary {
        // [persona] F3: capture the invoking shell's context on the guest
        // thread, before the hop to @MainActor.
        let invokingCtx = MinisFsRouter.callingFsContext()
        onMain {
            let registry = AgentJobRegistry.shared
            let caller = await Self.callerPersona(invokingFsContext: invokingCtx)
            let jobs: [AgentJob]
            switch caller {
            case .lookupFailed:
                // [persona] F3: a failed lookup is not the management view —
                // an unfiltered list would show every persona's tasks.
                return ["ok": false, "error": "persona_lookup_failed",
                        "message": "could not determine the persona of the calling session; nothing was listed."] as NSDictionary
            case .persona(let pid):
                // Backfill first so a job with no persona yet is owned
                // before filtering — otherwise it is silently omitted from
                // EVERY persona's list.
                await registry.backfillMissingPersonaIds()
                jobs = registry.list(forPersona: pid)
            case .noSession:
                // No session context: the management view, same as the
                // in-app task list.
                jobs = registry.list()
            }
            let dicts = jobs.map { registry.jobDict($0) }
            return ["tasks": dicts, "count": dicts.count] as NSDictionary
        } ?? ["ok": false, "error": "timeout",
              "message": "The app did not answer within 5s; nothing was changed."] as NSDictionary
    }

    @objc public static func delete(id: String) -> NSDictionary {
        let invokingCtx = MinisFsRouter.callingFsContext()
        onMain {
            let registry = AgentJobRegistry.shared
            let (resolved, labelNote) = Self.resolveJob(registry, id)
            guard let job = resolved else {
                return ["ok": false, "error": "not_found", "message": "no task with id=\(id)"] as NSDictionary
            }
            if let err = await Self.crossPersonaError(job: job,
                                                     caller: await Self.callerPersona(invokingFsContext: invokingCtx)) {
                return err
            }
            registry.cancel(jobId: job.id, reason: "cli delete")
            registry.remove(jobId: job.id)
            return ["deleted": job.id].merging(labelNote) { _, new in new } as NSDictionary
        } ?? ["ok": false, "error": "timeout",
              "message": "The app did not answer within 5s; nothing was changed."] as NSDictionary
    }

    @objc public static func setEnabled(id: String, enabled: Bool) -> NSDictionary {
        let invokingCtx = MinisFsRouter.callingFsContext()
        onMain {
            let registry = AgentJobRegistry.shared
            let (resolved, labelNote) = Self.resolveJob(registry, id)
            guard let job = resolved else {
                return ["ok": false, "error": "not_found", "message": "no task with id=\(id)"] as NSDictionary
            }
            if let err = await Self.crossPersonaError(job: job,
                                                     caller: await Self.callerPersona(invokingFsContext: invokingCtx)) {
                return err
            }
            registry.setEnabled(jobId: job.id, enabled: enabled)
            return ["id": job.id, "enabled": enabled].merging(labelNote) { _, new in new } as NSDictionary
        } ?? ["ok": false, "error": "timeout",
              "message": "The app did not answer within 5s; nothing was changed."] as NSDictionary
    }

    @objc public static func run(id: String) -> NSDictionary {
        let invokingCtx = MinisFsRouter.callingFsContext()
        onMain {
            let registry = AgentJobRegistry.shared
            let (resolved, labelNote) = Self.resolveJob(registry, id)
            guard let job = resolved else {
                return ["ok": false, "error": "not_found", "message": "no task with id=\(id)"] as NSDictionary
            }
            if let err = await Self.crossPersonaError(job: job,
                                                     caller: await Self.callerPersona(invokingFsContext: invokingCtx)) {
                return err
            }
            let outcome = await ScheduledJobRunner.fireNow(job)
            var out: [String: Any] = ["id": job.id, "ran": outcome["fired"] ?? false]
            if let sid = outcome["session_id"] as? String { out["sessionId"] = sid }
            out["note"] = "Returned as soon as the prompt was handed to the session; poll `minis-sessions-cli status --id <sessionId>` for completion."
            out.merge(labelNote) { _, new in new }
            return out as NSDictionary
        } ?? ["ok": false, "error": "timeout",
              "message": "The app did not answer within 5s; nothing was changed."] as NSDictionary
    }

    @objc public static func runsWithId(_ id: String) -> NSDictionary {
        let invokingCtx = MinisFsRouter.callingFsContext()
        onMain {
            let registry = AgentJobRegistry.shared
            let (resolved, labelNote) = Self.resolveJob(registry, id)
            guard let job = resolved else {
                return ["ok": false, "error": "not_found", "message": "no task with id=\(id)"] as NSDictionary
            }
            if let err = await Self.crossPersonaError(job: job,
                                                     caller: await Self.callerPersona(invokingFsContext: invokingCtx)) {
                return err
            }
            let list = registry.runs(jobId: job.id).map { $0.toDict() }
            return ["id": job.id, "runs": list, "count": list.count].merging(labelNote) { _, new in new } as NSDictionary
        } ?? ["ok": false, "error": "timeout",
              "message": "The app did not answer within 5s; nothing was changed."] as NSDictionary
    }

    /// [AUD-09] Resolve `--id <uuid|label>` for list / delete / enable / run.
    ///
    /// A label is not a key: several tasks can carry the same one, and a
    /// finished task used to be invisible to label lookups even while the list
    /// still showed it. This resolves across every state and hands back the note
    /// the receipt should carry when the label was ambiguous, so the caller
    /// learns which task was actually acted on instead of guessing.
    @MainActor
    private static func resolveJob(_ registry: AgentJobRegistry,
                                   _ input: String) -> (job: AgentJob?, labelNote: [String: Any]) {
        if let byId = registry.job(id: input) { return (byId, [:]) }
        let matches = registry.jobMatches(label: input)
        guard let winner = matches.first else { return (nil, [:]) }
        guard matches.count > 1 else { return (winner, [:]) }
        return (winner, [
            "ambiguous_label": true,
            "matched_jobs": matches.map(\.id),
            "using_job": winner.id,
            "label_note": "\(matches.count) tasks share the label \"\(input)\"; acted on the most recent live one. Use a job UUID to pick a different one.",
        ])
    }

    // MARK: - parsing

    private static func error(_ message: String) -> NSDictionary {
        ["ok": false, "error": "invalid_args", "message": message]
    }

    private static func parseTime(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    private static func parseDays(_ s: String) -> Set<Int>? {
        let map: [String: Int] = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        var out = Set<Int>()
        for raw in s.lowercased().split(separator: ",") {
            let key = String(raw.trimmingCharacters(in: .whitespaces).prefix(3))
            guard let d = map[key] else { return nil }
            out.insert(d)
        }
        return out
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }

    // MARK: - Edit in place / export history  [AUD-11]

    /// [AUD-11] Edit an existing task.
    ///
    /// Only what the caller names is changed — prompt, title, label, timing,
    /// target, model, thinking level — and everything else keeps its current
    /// value. Identity (id, created time, counters, run history) is preserved:
    /// before this, the only way to change a task was delete + create, which
    /// left every `--id` reference and every `onCompletion` link dangling and
    /// threw the history away.
    ///
    /// The timing flags are parsed here rather than by sharing `create`'s
    /// parser: that one interleaves target/prompt validation with a receipt
    /// path, so sharing it would mean restructuring `create` in the same change
    /// — not worth the risk. The flags and the inference rules are deliberately
    /// kept in step with it.
    @objc public static func update(args: NSDictionary) -> NSDictionary {
        // [persona] F3: capture the invoking shell's context on the guest
        // thread, before the hop to @MainActor.
        let invokingCtx = MinisFsRouter.callingFsContext()
        let callerSid = Self.callerSessionId()
        onMain {
            func str(_ k: String) -> String? {
                guard let v = args[k] as? String, !v.isEmpty else { return nil }
                return v
            }
            guard let jobRef = str("id") else {
                return error("--id <jobId|label> required")
            }
            let registry = AgentJobRegistry.shared
            let (resolved, labelNote) = Self.resolveJob(registry, jobRef)
            guard let job = resolved else {
                return ["ok": false, "error": "not_found", "message": "no task with id=\(jobRef)"] as NSDictionary
            }
            if let err = await Self.crossPersonaError(job: job,
                                                     caller: await Self.callerPersona(invokingFsContext: invokingCtx)) {
                return err
            }

            // ── Trigger, only when a timing flag is actually given ─────────
            var newTrigger: AgentJobTrigger? = nil
            let timingKeys = ["trigger", "after", "time", "interval", "count", "of", "repeat", "days", "start", "end"]
            if timingKeys.contains(where: { str($0) != nil }) {
                let triggerRaw = str("trigger")?.lowercased()
                    ?? (str("after") != nil ? "once"
                        : str("interval") != nil ? "loop"
                        : str("time") != nil ? "cron"
                        : str("of") != nil ? "on-completion"
                        : nil)
                guard let kind = triggerRaw else {
                    return error("Give a trigger: --after <dur> (once), --interval <dur> [--count N] (loop), --time HH:MM [--repeat …] (cron), or --trigger on-completion --of <jobId>")
                }
                switch kind {
                case "once":
                    if let after = str("after") {
                        guard let secs = ScheduledJobRunner.parseDuration(after), secs >= 1 else {
                            return error("--after must be a duration like 30m, 2h, 90s")
                        }
                        newTrigger = .once(after: secs)
                    } else if let time = str("time") {
                        guard let (h, m) = parseTime(time) else { return error("--time must be HH:MM") }
                        guard let next = ScheduledJobRunner.nextCronDate(hour: h, minute: m, days: [], start: nil, end: nil, from: Date()) else {
                            return error("no future occurrence of --time \(time)")
                        }
                        newTrigger = .once(after: next.timeIntervalSinceNow)
                    } else {
                        return error("once needs --after <duration> or --time HH:MM")
                    }
                case "loop":
                    guard let iv = str("interval"), let secs = ScheduledJobRunner.parseDuration(iv), secs >= 60 else {
                        return error("--interval must be a duration of at least 60s (e.g. 10m)")
                    }
                    var count: Int? = nil
                    if let c = str("count") {
                        guard let n = Int(c), n >= 1 else { return error("--count must be a positive integer") }
                        count = n
                    }
                    newTrigger = .loop(interval: secs, count: count)
                case "cron":
                    guard let time = str("time"), let (h, m) = parseTime(time) else { return error("--time HH:MM required for cron") }
                    switch (str("repeat") ?? "daily").lowercased() {
                    case "once":
                        guard let next = ScheduledJobRunner.nextCronDate(hour: h, minute: m, days: [], start: nil, end: nil, from: Date()) else {
                            return error("no future occurrence of --time \(time)")
                        }
                        newTrigger = .once(after: next.timeIntervalSinceNow)
                    case "daily":
                        newTrigger = .cron(hour: h, minute: m, days: Set(1...7),
                                           start: str("start").flatMap(parseDate), end: str("end").flatMap(parseDate))
                    case "weekdays":
                        newTrigger = .cron(hour: h, minute: m, days: Set(2...6),
                                           start: str("start").flatMap(parseDate), end: str("end").flatMap(parseDate))
                    case "custom":
                        guard let d = str("days"), let parsed = parseDays(d), !parsed.isEmpty else {
                            return error("--days required for custom repeat (e.g. mon,tue,fri)")
                        }
                        newTrigger = .cron(hour: h, minute: m, days: parsed,
                                           start: str("start").flatMap(parseDate), end: str("end").flatMap(parseDate))
                    default:
                        return error("--repeat must be once|daily|weekdays|custom")
                    }
                case "on-completion", "oncompletion", "on_completion":
                    guard let of = str("of") else { return error("--of <jobId> required for on-completion trigger") }
                    newTrigger = .onCompletion(ofJobId: of)
                default:
                    return error("--trigger must be once|loop|cron|on-completion")
                }
            }

            // ── Target, only when named ───────────────────────────────────
            var newTarget: AgentJobTarget? = nil
            if let t = str("target")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                switch t {
                case "new":
                    newTarget = .new
                case "follow-up", "followup", "append":
                    guard let sid = str("session") ?? callerSid else {
                        return error("--session required for follow-up target (or run this from a chat)")
                    }
                    newTarget = .followUp(sessionId: sid)
                case "rerun":
                    guard let sid = str("session") ?? callerSid else { return error("--session required for rerun target") }
                    guard let mid = str("message") else { return error("--message required for rerun target") }
                    newTarget = .rerun(sessionId: sid, messageId: mid)
                case "child-of-current", "child":
                    guard AgentToolSwitch.agents.isEnabled else {
                        return error("child-of-current is unavailable: Sub Agents are turned off in Settings › Agent Tools.")
                    }
                    guard let sid = str("session") ?? callerSid else {
                        return error("child-of-current needs a current session: run this from a chat, or pass --session")
                    }
                    newTarget = .childOfCurrent(parentSessionId: sid, parentToolUseId: nil)
                default:
                    return error("--target must be new|follow-up|rerun|child-of-current")
                }
            } else if let sid = str("session") {
                // A bare --session means "deliver here", matching create's default.
                newTarget = .followUp(sessionId: sid)
            }

            // ── Model / thinking ──────────────────────────────────────────
            var thinking: ThinkingLevel? = nil
            if let raw = str("thinking") {
                let parsed = ThinkingLevel.decoded(raw)
                guard parsed.rawValue.caseInsensitiveCompare(raw) == .orderedSame else {
                    return error("--thinking must be one of: off, low, medium, high, xhigh")
                }
                thinking = parsed
            }

            // [persona] F3: a retarget must not move the fire into another
            // persona's session — the stamp stays, so the fire-time check
            // would refuse it forever; refuse here instead, while the caller
            // can still fix the command.
            if let newTarget {
                if case .refused(let err) = await Self.checkTargetPersona(target: newTarget, callerSessionId: callerSid) {
                    return err
                }
            }

            let newLabel = str("label")
            guard let updated = registry.redefine(jobId: job.id,
                                                  title: str("title") ?? newLabel,
                                                  label: newLabel,
                                                  trigger: newTrigger,
                                                  target: newTarget,
                                                  prompt: str("prompt")) else {
                return ["ok": false, "error": "not_found",
                        "message": "task \(job.id.prefix(8)) disappeared while it was being updated"] as NSDictionary
            }
            if let m = str("model") { updated.modelEntryId = m }
            if let t = thinking { updated.thinkingLevel = t }
            registry.persistScheduledJobs()

            var out = registry.jobDict(updated)
            out["updated"] = true
            out["note"] = "Only the fields you named were changed; the task kept its id, its creation time and its run history."
            return out.merging(labelNote) { _, new in new } as NSDictionary
        } ?? ["ok": false, "error": "timeout",
              "message": "The app did not answer within 5s; nothing was changed."] as NSDictionary
    }

    /// [AUD-11] Write one task's definition + full run history to a file.
    ///
    /// The history has always been visible in the detail sheet and never
    /// takeable anywhere else. The path is the caller's, so it can land in the
    /// shared workspace where both the app and the sandbox can read it.
    @objc public static func exportRuns(id: String, path: String) -> NSDictionary {
        let invokingCtx = MinisFsRouter.callingFsContext()
        onMain {
            let registry = AgentJobRegistry.shared
            let (resolved, labelNote) = Self.resolveJob(registry, id)
            guard let job = resolved else {
                return ["ok": false, "error": "not_found", "message": "no task with id=\(id)"] as NSDictionary
            }
            if let err = await Self.crossPersonaError(job: job,
                                                     caller: await Self.callerPersona(invokingFsContext: invokingCtx)) {
                return err
            }
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ["ok": false, "error": "path_required", "message": "--export <path> required"] as NSDictionary
            }
            let runs = registry.runs(jobId: job.id)
            var payload: [String: Any] = [
                "task": registry.jobDict(job),
                "exportedAt": ScheduledJobRunner.iso(Date()),
                "runs": runs.map { $0.toDict() },
            ]
            payload.merge(labelNote) { _, new in new }
            guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                         options: [.prettyPrinted, .sortedKeys]) else {
                return ["ok": false, "error": "encode_failed"] as NSDictionary
            }
            let url = URL(fileURLWithPath: path)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                return ["ok": false, "error": "write_failed", "message": error.localizedDescription] as NSDictionary
            }
            logger.info("[minis-scheduled] exported \(runs.count) run(s) of \(job.id.prefix(8)) to \(path)")
            return ["ok": true, "job_id": job.id, "path": path, "count": runs.count]
                .merging(labelNote) { _, new in new } as NSDictionary
        } ?? ["ok": false, "error": "timeout",
              "message": "The app did not answer within 5s; nothing was changed."] as NSDictionary
    }
}
