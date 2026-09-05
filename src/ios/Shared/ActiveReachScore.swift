import Foundation

/// 小梦主动 · 打分引擎（第三刀）。
/// 门闩 allowed 之后：时间分、读会话、挑对话框、调模型。
/// 不发通知。草稿只入队，cap 计数不预占。
///
/// 闸门分区（Yuralume）：
/// 1 启发式：无模型 / 无活对话框 / 读失败
/// 2 意图：情绪分 + 时间分 vs 阈值
/// 3 决策：尊重 wantSend、cap/破例、入草稿

struct ActiveReachTurn: Equatable {
    var role: String
    var text: String
    var date: Date
}

struct TimeScoreResult: Equatable {
    var score: Int
    var timedOut: Bool
    var noPeerTimestamp: Bool
    var minutes: Int?
}

struct DialogPick: Equatable {
    var id: String
    var note: String?
    var lastActive: Date?
}

struct ModelScorePayload: Equatable {
    var emotionScore: Int
    var wantSend: Bool
    var text: String
    var reason: String
}

struct CapDecision: Equatable {
    var shouldDraft: Bool
    var wouldConsumeCap: Bool
    var wouldBreak: Bool
    var reason: String?
}

struct ActiveReachDraft: Equatable, Codable, Identifiable {
    var id: String
    var createdAt: TimeInterval
    var dialogId: String
    var text: String
    var emotion: Int
    var timeScore: Int
    var total: Int
    var wouldBreak: Bool
    var source: String
}

struct ReachCycleResult: Equatable {
    var disposition: String
    var reason: String?
    var dialogId: String?
    var emotionScore: Int?
    var timeScore: Int?
    var totalScore: Int?
    var wouldBreak: Bool
    var wouldConsumeCap: Bool
    var pickNote: String?
    var timedOut: Bool
    var noPeerTimestamp: Bool
    var draft: ActiveReachDraft?
}

protocol ActiveReachSessionReading {
    func sessionExists(dialogId: String) async -> Bool
    func lastActive(dialogId: String) async -> Date?
    func loadTurns(dialogId: String) async throws -> [ActiveReachTurn]
}

protocol ActiveReachModelCalling {
    func complete(modelId: String, system: String, user: String) async -> Result<String, String>
}

enum ActiveReachScore {
    static let peerQuietFloorMinutes = 30
    static let timeScoreCap = 120
    static let scoreThreshold = 60
    static let maxTurns = 10
    static let sinceHours = 24
    static let maxChars = 6000
    static let draftLimit = 20
    static let draftKey = "activeReach.drafts.v1"

    /// `lastPeerMessageAt == nil`：按封顶 120 + `noPeerTimestamp`。
    /// 空态当她离开很久，而不是当刚聊完。
    static func timeScore(
        lastPeerMessageAt: Date?,
        now: Date,
        quietTimeoutMinutes: Int
    ) -> TimeScoreResult {
        guard let last = lastPeerMessageAt else {
            return TimeScoreResult(
                score: timeScoreCap, timedOut: true, noPeerTimestamp: true, minutes: nil)
        }
        let minutes = max(0, Int(now.timeIntervalSince(last) / 60.0))
        let high = max(quietTimeoutMinutes, peerQuietFloorMinutes)
        if minutes < peerQuietFloorMinutes {
            return TimeScoreResult(
                score: 0, timedOut: false, noPeerTimestamp: false, minutes: minutes)
        }
        if minutes > high {
            return TimeScoreResult(
                score: timeScoreCap, timedOut: true, noPeerTimestamp: false, minutes: minutes)
        }
        if high == peerQuietFloorMinutes {
            return TimeScoreResult(
                score: timeScoreCap, timedOut: false, noPeerTimestamp: false, minutes: minutes)
        }
        let t = Double(minutes - peerQuietFloorMinutes) / Double(high - peerQuietFloorMinutes)
        let mapped = 30.0 + t * Double(timeScoreCap - 30)
        return TimeScoreResult(
            score: Int(mapped.rounded()),
            timedOut: false,
            noPeerTimestamp: false,
            minutes: minutes
        )
    }

    static func pickDialog(
        ids: [String],
        lastActive: [String: Date],
        now: Date,
        activeHours: Int
    ) -> Result<DialogPick, String> {
        let window = TimeInterval(max(activeHours, 1) * 3600)
        var fresh: [(String, Date)] = []
        var noMeta: [String] = []
        for id in ids {
            if let at = lastActive[id] {
                if now.timeIntervalSince(at) <= window {
                    fresh.append((id, at))
                }
            } else {
                noMeta.append(id)
            }
        }
        if let best = fresh.max(by: { $0.1 < $1.1 }) {
            return .success(DialogPick(id: best.0, note: nil, lastActive: best.1))
        }
        if let first = noMeta.first {
            return .success(DialogPick(id: first, note: "pickFallbackFirst", lastActive: nil))
        }
        return .failure("noActiveDialog")
    }

    static func windowTurns(
        _ turns: [ActiveReachTurn],
        now: Date,
        maxCount: Int = maxTurns,
        hours: Int = sinceHours,
        maxChars: Int = maxChars
    ) -> [ActiveReachTurn] {
        let since = now.addingTimeInterval(TimeInterval(-hours * 3600))
        let inWindow = turns.filter { $0.date >= since }
        let clipped = Array(inWindow.suffix(maxCount))
        var kept: [ActiveReachTurn] = []
        var count = 0
        for turn in clipped.reversed() {
            let n = turn.text.count
            if count + n > maxChars && !kept.isEmpty { break }
            if n > maxChars && kept.isEmpty {
                let trimmed = String(turn.text.suffix(maxChars))
                kept.append(ActiveReachTurn(role: turn.role, text: trimmed, date: turn.date))
                count = trimmed.count
                break
            }
            kept.append(turn)
            count += n
        }
        return kept.reversed()
    }

    static func parseModelJSON(_ raw: String) -> ModelScorePayload? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: nl)...])
            }
            if let fence = s.range(of: "```") {
                s = String(s[..<fence.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let emotion = intValue(obj["emotionScore"] ?? obj["emotion_score"]),
              (0...100).contains(emotion)
        else { return nil }
        guard let want = boolValue(obj["wantSend"] ?? obj["want_send"]) else { return nil }
        let text = stringValue(obj["text"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = stringValue(obj["reason"]) ?? ""
        return ModelScorePayload(emotionScore: emotion, wantSend: want, text: text, reason: reason)
    }

    static func capDecision(
        snapshot: ActiveReachSnapshot,
        timedOut: Bool,
        emotionScore: Int,
        wantSend: Bool,
        total: Int,
        threshold: Int = scoreThreshold
    ) -> CapDecision {
        if !wantSend {
            return CapDecision(
                shouldDraft: false, wouldConsumeCap: false, wouldBreak: false,
                reason: "modelDeclined")
        }
        if total < threshold {
            return CapDecision(
                shouldDraft: false, wouldConsumeCap: false, wouldBreak: false,
                reason: "belowThreshold")
        }
        if snapshot.dailyCapCount < snapshot.dailyCap {
            return CapDecision(
                shouldDraft: true, wouldConsumeCap: true, wouldBreak: false, reason: nil)
        }
        let strong = timedOut || emotionScore >= 80
        if strong && snapshot.dailyBreakCount < snapshot.dailyBreakCap {
            return CapDecision(
                shouldDraft: true, wouldConsumeCap: false, wouldBreak: true, reason: nil)
        }
        return CapDecision(
            shouldDraft: false, wouldConsumeCap: false, wouldBreak: false,
            reason: "capExhausted")
    }

    static func prependDraft(
        _ draft: ActiveReachDraft,
        onto list: [ActiveReachDraft],
        limit: Int = draftLimit
    ) -> [ActiveReachDraft] {
        Array(([draft] + list).prefix(limit))
    }

    static func loadDrafts(from defaults: UserDefaults) -> [ActiveReachDraft] {
        guard let data = defaults.data(forKey: draftKey),
              let decoded = try? JSONDecoder().decode([ActiveReachDraft].self, from: data)
        else { return [] }
        return decoded
    }

    static func encodeDrafts(_ items: [ActiveReachDraft]) -> Data? {
        try? JSONEncoder().encode(items)
    }

    static func systemPrompt() -> String {
        """
        你是小梦。根据最近聊天和时间，只输出 JSON，不要 Markdown，不要文案库里的套话。
        text 必须是你当下想对醒醒说的一两句口语。
        字段：emotionScore 0到100 整数，wantSend 布尔，text 字符串，reason 短字符串。
        """
    }

    static func userPrompt(
        time: TimeScoreResult,
        turns: [ActiveReachTurn],
        memory: String
    ) -> String {
        var lines: [String] = []
        if let m = time.minutes {
            lines.append("距她上一条消息大约 \(m) 分钟。时间分 \(time.score)。")
        } else {
            lines.append("没有她的消息时间戳。时间分按封顶 \(time.score)。")
        }
        if time.timedOut { lines.append("已超时（别骚扰窗口）。") }
        if turns.isEmpty {
            lines.append("最近没有聊天原文。空态。")
            if !memory.isEmpty {
                lines.append("记忆摘录：\n\(memory)")
            }
        } else {
            lines.append("最近聊天：")
            for t in turns {
                lines.append("[\(t.role)] \(t.text)")
            }
        }
        lines.append("请只回 JSON。")
        return lines.joined(separator: "\n")
    }

    static func run(
        snapshot: ActiveReachSnapshot,
        source: String,
        now: Date,
        memorySnippet: String,
        sessions: ActiveReachSessionReading,
        model: ActiveReachModelCalling
    ) async -> ReachCycleResult {
        // Gate 1 · 启发式
        let modelId = snapshot.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if modelId.isEmpty {
            return fail("noModel", source: source, snapshot: snapshot)
        }
        var lastActive: [String: Date] = [:]
        for id in snapshot.dialogIds {
            if let at = await sessions.lastActive(dialogId: id) {
                lastActive[id] = at
            }
        }
        let picked: DialogPick
        switch pickDialog(
            ids: snapshot.dialogIds,
            lastActive: lastActive,
            now: now,
            activeHours: snapshot.dialogActiveHours
        ) {
        case .failure(let reason):
            return fail(reason, source: source, snapshot: snapshot)
        case .success(let pick):
            picked = pick
        }

        let exists = await sessions.sessionExists(dialogId: picked.id)
        if !exists {
            return fail("readFailed", source: source, snapshot: snapshot, dialogId: picked.id, pickNote: picked.note)
        }

        let turns: [ActiveReachTurn]
        do {
            turns = try await sessions.loadTurns(dialogId: picked.id)
        } catch {
            return fail("readFailed", source: source, snapshot: snapshot, dialogId: picked.id, pickNote: picked.note)
        }

        let windowed = windowTurns(turns, now: now)
        let lastPeer = windowed.last(where: { $0.role == "user" })?.date
            ?? turns.last(where: { $0.role == "user" })?.date
        let time = timeScore(
            lastPeerMessageAt: lastPeer,
            now: now,
            quietTimeoutMinutes: snapshot.quietTimeoutMinutes
        )

        let prompt = userPrompt(time: time, turns: windowed, memory: memorySnippet)
        let raw = await model.complete(modelId: modelId, system: systemPrompt(), user: prompt)
        let output: String
        switch raw {
        case .failure:
            return fail(
                "parseFailed", source: source, snapshot: snapshot, dialogId: picked.id,
                pickNote: picked.note, time: time)
        case .success(let text):
            output = text
        }

        guard let payload = parseModelJSON(output) else {
            return fail(
                "parseFailed", source: source, snapshot: snapshot, dialogId: picked.id,
                pickNote: picked.note, time: time)
        }

        let total = payload.emotionScore + time.score
        // Gate 2 · 意图：总分 vs 阈值；Gate 3 · 决策：wantSend + cap
        let cap = capDecision(
            snapshot: snapshot,
            timedOut: time.timedOut,
            emotionScore: payload.emotionScore,
            wantSend: payload.wantSend,
            total: total
        )

        var draft: ActiveReachDraft?
        var disposition = "skipped"
        var reason = cap.reason
        if cap.shouldDraft {
            let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                disposition = "skipped"
                reason = "emptyText"
            } else {
                draft = ActiveReachDraft(
                    id: UUID().uuidString,
                    createdAt: now.timeIntervalSince1970,
                    dialogId: picked.id,
                    text: text,
                    emotion: payload.emotionScore,
                    timeScore: time.score,
                    total: total,
                    wouldBreak: cap.wouldBreak,
                    source: source
                )
                disposition = "drafted"
                reason = cap.wouldBreak ? "wouldBreak" : "wouldConsumeCap"
            }
        }

        return ReachCycleResult(
            disposition: disposition,
            reason: reason,
            dialogId: picked.id,
            emotionScore: payload.emotionScore,
            timeScore: time.score,
            totalScore: total,
            wouldBreak: cap.wouldBreak,
            wouldConsumeCap: cap.wouldConsumeCap,
            pickNote: picked.note,
            timedOut: time.timedOut,
            noPeerTimestamp: time.noPeerTimestamp,
            draft: draft
        )
    }

    private static func fail(
        _ reason: String,
        source: String,
        snapshot: ActiveReachSnapshot,
        dialogId: String? = nil,
        pickNote: String? = nil,
        time: TimeScoreResult? = nil
    ) -> ReachCycleResult {
        ReachCycleResult(
            disposition: "blocked",
            reason: reason,
            dialogId: dialogId,
            emotionScore: nil,
            timeScore: time?.score,
            totalScore: nil,
            wouldBreak: false,
            wouldConsumeCap: false,
            pickNote: pickNote,
            timedOut: time?.timedOut ?? false,
            noPeerTimestamp: time?.noPeerTimestamp ?? false,
            draft: nil
        )
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d.rounded()) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String {
            let t = s.lowercased()
            if t == "true" || t == "1" { return true }
            if t == "false" || t == "0" { return false }
        }
        return nil
    }

    private static func stringValue(_ any: Any?) -> String? {
        any as? String
    }
}

struct ChatStoreReachReading: ActiveReachSessionReading {
    func sessionExists(dialogId: String) async -> Bool {
        await ChatStore.shared.sessionExists(id: dialogId)
    }

    func lastActive(dialogId: String) async -> Date? {
        await ChatStore.shared.getSession(dialogId)?.updatedAt
    }

    func loadTurns(dialogId: String) async throws -> [ActiveReachTurn] {
        let rows = await ChatStore.shared.loadMessages(sessionId: dialogId)
        return rows.compactMap { msg in
            if msg.isToolResultOnly || msg.isInternalBridge { return nil }
            let text = msg.parts.compactMap { part -> String? in
                if case .text(let s) = part { return s }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let role = msg.role == .user ? "user" : "assistant"
            return ActiveReachTurn(role: role, text: text, date: msg.createdAt)
        }
    }
}

struct ModelUseReachCaller: ActiveReachModelCalling {
    func complete(modelId: String, system: String, user: String) async -> Result<String, String> {
        let payload: [String: Any] = [
            "messages": [["role": "user", "content": user]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return .failure("encode failed") }
        return await withCheckedContinuation { cont in
            ModelUseOffloadBridge.runModel(
                idOrName: modelId,
                providerFilter: nil,
                inputJSON: json,
                systemPrompt: system,
                maxTokens: 400,
                temperature: 0.8,
                outputHostPath: nil,
                streamFd: -1
            ) { result, error in
                if let error {
                    cont.resume(returning: .failure(error))
                    return
                }
                let text = (result?["output_text"] as? String) ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cont.resume(returning: .failure("empty model output"))
                } else {
                    cont.resume(returning: .success(text))
                }
            }
        }
    }
}

enum ActiveReachMemorySnippet {
    static func load(now: Date = Date(), limit: Int = 2000) -> String {
        var chunks: [String] = []
        if let body = SoulStore.load()?.body, !body.isEmpty {
            chunks.append(String(body.prefix(800)))
        }
        let dir = RootfsManager.shared.dataPath.appendingPathComponent("var/minis/memory")
        let global = dir.appendingPathComponent("GLOBAL.md")
        if let text = try? String(contentsOf: global, encoding: .utf8), !text.isEmpty {
            chunks.append(String(text.prefix(800)))
        }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let daily = dir.appendingPathComponent("\(fmt.string(from: now)).md")
        if let text = try? String(contentsOf: daily, encoding: .utf8), !text.isEmpty {
            chunks.append(String(text.prefix(800)))
        }
        let joined = chunks.joined(separator: "\n---\n")
        if joined.isEmpty { return "" }
        return String(joined.prefix(limit))
    }
}
