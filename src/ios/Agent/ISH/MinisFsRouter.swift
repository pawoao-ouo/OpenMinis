//
//  MinisFsRouter.swift
//  MinisApp
//
//  Routes guest paths under /var/minis/{offloads,attachments,workspace,browser}
//  to per-session host directories, guest paths under /var/minis/memory to
//  the per-persona host directory, and guest paths under
//  /var/minis/{skills,mcp-servers,shared} to the single GLOBAL host
//  directories (skills and MCP servers are shared by all personas — user
//  decision 2026-11-20), via the iSH fakefs path-translate hook.
//  Shared routes to the FLAT shared/ dir (item 12): the flat dir is the
//  live read/write runtime area (events.jsonl, together/, heartbeat) and
//  the app side reads it persona-first-flat-after, so the guest must see
//  the same flat area — routing it into shared/<pid>/ split every
//  runtime file per session and hid the live area from the guest. A
//  persona's own shared namespace stays reachable as a subdir:
//  /var/minis/shared/<pid>/... maps to shared/<pid>/... (it is a subpath
//  of the flat dir), and the app-side resolvers keep the persona-first
//  order for reads.
//
//  Each session gets a unique fs_context token (u64) that is stamped on the
//  task group spawned for that session. When the task (or any of its forked
//  children) touches a path under one of the per-session buckets, the C-level
//  hook looks up the token here and rewrites to
//  ~/Library/.../minis/<personaId>/<sid>/<bucket>/...
//  Per-persona buckets rewrite to <app-group>/<bucket>/<personaId>/...
//  except memory, which rewrites to <app-group>/memory/personas/<personaId>/
//  (the runtime layout, crosscheck-verdict §4). Skills and MCP servers are
//  NOT per-persona: they route to the single global dirs in globalBuckets
//  below (user decision 2026-11-20 — splitting them would make the model
//  download duplicates; the shell must write new skills where SkillStore
//  loads them from, i.e. skills/default/). mcp-servers lives under
//  MinisConfig instead of the app group.
//
//  Shared routes to the flat live area (see globalBuckets). The flat
//  shared/ dir is NOT locked — it is the live read/write runtime area
//  (events.jsonl, together/, heartbeat) for host-side services, and
//  isolation for shared lives in resolution, not in a filesystem lock
//  (see PersonaStore.isCrossPersonaSharedPath). A persona's own
//  namespace (shared/<pid>/) is a subdir of that flat area, reachable
//  from the guest as /var/minis/shared/<pid>/..., and the app-side
//  resolvers read persona-namespace-first, flat-after.
//

import Foundation

final class MinisFsRouter: @unchecked Sendable {
    static let shared = MinisFsRouter()

    /// Guest path prefixes that route per-session. Anything under one of these
    /// becomes ~/Library/.../minis/<personaId>/<sid>/<bucket>/<tail>.
    private let perSessionBuckets: [(linuxPrefix: String, hostSubdir: String)] = [
        (AIChatViewModel.minisOffloadsLinuxDir,    "offloads"),
        (AIChatViewModel.minisAttachmentsLinuxDir, "attachments"),
        (AIChatViewModel.minisWorkspaceLinuxDir,   "workspace"),
        (AIChatViewModel.minisBrowserLinuxDir,     "browser"),
    ]

    /// Guest path prefixes that route per-persona (not per-session).
    /// Anything under one of these becomes <hostRoot>/[<personaPrefix>/]<personaId>/<tail>.
    /// Memory carries the "personas" prefix (memory/personas/<id>/ — the
    /// runtime layout). Shared is NOT here anymore (item 12): it routes
    /// to the flat live area via globalBuckets below.
    /// These used to fall through to the legacy g_bind_mounts[] table,
    /// where the first session to mount won and every persona saw the
    /// same global files — that is the leak this isolation work closes.
    private let perPersonaBuckets: [(linuxPrefix: String, hostRoot: URL, personaPrefix: String)] = [
        (AIChatViewModel.minisMemoryLinuxDir,     AIChatViewModel.minisMemoryPersistentDir, "personas"),
    ]

    /// Guest path prefixes that route to a SINGLE global host dir, shared
    /// by all personas (no persona component in the host path).
    /// Skills route to skills/default/ — the 1b migration copy of user
    /// skills and the dir SkillStore loads from; a shell-created skill
    /// written anywhere else would never load. Bundled skills are the
    /// exception (round-2 new problem 5): they live only in the flat
    /// baseline, so hostPath routes a bundled id there (see
    /// bundledSkillHostPath, mirroring SkillStore.dirForSkill). MCP
    /// servers route to the flat <mcp-servers>/ root, where the single
    /// global servers.json lives (the same file MCPStore reads/writes).
    /// Shared routes to the flat shared/ root (item 12) — the live
    /// runtime area — so the guest sees the same events.jsonl /
    /// together/ / heartbeat the host does.
    private let globalBuckets: [(linuxPrefix: String, hostDir: URL)] = [
        (AIChatViewModel.minisSkillsLinuxDir,     PersonaStore.skillsDir(for: PersonaStore.defaultPersonaId)),
        (AIChatViewModel.minisMcpServersLinuxDir, AIChatViewModel.minisMcpServersPersistentDir),
        (AIChatViewModel.minisSharedLinuxDir,     AIChatViewModel.minisSharedPersistentDir),
    ]

    private let lock = NSLock()
    private var nextContext: UInt64 = 1
    private var contextToSid: [UInt64: String] = [:]
    private var sidToContext: [String: UInt64] = [:]
    /// Persona captured when the context was issued (from the PersonaStore
    /// cache — populated at session load/create and warmed at launch, so
    /// this is set by the time a task spawns). A session's persona never
    /// changes. No entry means the persona was unknown at issue time:
    /// persona buckets then fail closed (nil) instead of resolving to
    /// the default persona's files (items 1–2).
    private var contextToPersona: [UInt64: String] = [:]

    /// Host base URL (~/Library/MinisChat/minis). Captured once at install time.
    private let minisBaseURL: URL

    private init() {
        self.minisBaseURL = AIChatViewModel.minisPersistentBase
    }

    /// Allocate a stable fs_context token for `sid`. Repeated calls with the
    /// same sid return the same token, so workers can be respawned without
    /// invalidating prior routing.
    func context(for sid: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if let existing = sidToContext[sid] { return existing }
        let ctx = nextContext
        nextContext &+= 1
        if nextContext == 0 { nextContext = 1 }   // never hand out 0 (= "no override")
        contextToSid[ctx] = sid
        sidToContext[sid] = ctx
        // Capture the persona only when known. A nil (cache miss — the
        // session was never loaded and warmCache has not run) leaves no
        // entry, and persona buckets then fail closed in hostPath instead
        // of silently resolving to the default persona (items 1–2).
        if let pid = PersonaStore.cachedPersonaId(forSessionId: sid) {
            contextToPersona[ctx] = pid
        }
        return ctx
    }

    /// Reverse lookup. Returns nil if the token was never issued or has been
    /// freed. Hot-path: keep this branchless.
    func sid(for context: UInt64) -> String? {
        if context == 0 { return nil }
        lock.lock(); defer { lock.unlock() }
        return contextToSid[context]
    }

    /// Persona captured when the token was issued. Same nil rule as sid(for:).
    func persona(for context: UInt64) -> String? {
        if context == 0 { return nil }
        lock.lock(); defer { lock.unlock() }
        return contextToPersona[context]
    }

    /// Install the path-translate hook on ISHKernel. Idempotent; call once
    /// at boot before any session task is spawned. Installs both the
    /// forward hook (guest→host) and the reverse hook (host→guest) — the
    /// reverse hook is needed by readdir/getpath when fakefs has resolved
    /// a hook-routed path through F_GETPATH and needs to map it back so
    /// meta.db inode lookup works.
    func installHook() {
        ISHKernel.shared.installPathTranslateHandler { [weak self] guestPath, fsContext in
            return self?.translate(guestPath: guestPath, fsContext: fsContext)
        }
        ISHKernel.shared.installPathReverseHandler { [weak self] hostPath in
            return self?.reverse(hostPath: hostPath)
        }
    }

    // MARK: - Translation

    /// The hook itself. Called on iSH worker threads, on the fakefs hot path.
    /// MUST stay non-blocking — only a hash lookup + a few string ops, plus
    /// the bounded skills-bucket stat() calls in bundledSkillHostPath
    /// (two stats max, only for /var/minis/skills paths).
    private func translate(guestPath: String, fsContext: UInt64) -> String? {
        guard fsContext != 0, let sid = sid(for: fsContext) else { return nil }
        // Use the persona captured at context-issue time, not a fresh cache
        // read — the hot path must not depend on cache lifetime.
        return hostPath(forGuest: guestPath, sid: sid, personaId: persona(for: fsContext))
    }

    /// Resolve a guest path under one of the per-session buckets to its host
    /// URL for the given sid. Returns nil if the path is not under any
    /// per-session bucket (caller should fall back to the static mount table).
    /// Used by Swift call sites that need the host path without going through
    /// iSH (e.g. NSFileCoordinator on attachments).
    func hostURL(forGuest guestPath: String, sid: String) -> URL? {
        guard let path = hostPath(forGuest: guestPath, sid: sid) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func hostPath(forGuest guestPath: String, sid: String, personaId: String? = nil) -> String? {
        // Persona for this session: explicit when the caller has it (the
        // translate hook uses the context-captured value), else the cache.
        // A nil persona fails CLOSED for per-session and per-persona
        // buckets (return nil below) — never "default" (items 1–2). Only
        // the global buckets (skills, mcp-servers, shared) resolve
        // without a persona, because they have no persona component.
        let personaId = personaId ?? PersonaStore.cachedPersonaId(forSessionId: sid)
        for bucket in perSessionBuckets {
            if let hit = matchBucket(guestPath, prefix: bucket.linuxPrefix) {
                // Fail closed: no persona, no per-session path.
                guard let personaId else { return nil }
                return minisBaseURL
                    .appendingPathComponent(personaId, isDirectory: true)
                    .appendingPathComponent(sid, isDirectory: true)
                    .appendingPathComponent(bucket.hostSubdir, isDirectory: true)
                    .path + hit
            }
        }
        for bucket in perPersonaBuckets {
            if let hit = matchBucket(guestPath, prefix: bucket.linuxPrefix) {
                // Fail closed: no persona, no per-persona path.
                guard let personaId else { return nil }
                var url = bucket.hostRoot
                if !bucket.personaPrefix.isEmpty {
                    url = url.appendingPathComponent(bucket.personaPrefix, isDirectory: true)
                }
                return url
                    .appendingPathComponent(personaId, isDirectory: true)
                    .path + hit
            }
        }
        // Global buckets: no persona component — every persona's shell
        // writes to the same dir the app-side stores load from.
        for bucket in globalBuckets {
            if let hit = matchBucket(guestPath, prefix: bucket.linuxPrefix) {
                // Round-2 new problem 5: a bundled skill's files live
                // only in the flat baseline, so a guest path for a
                // bundled id must route there, not to skills/default/
                // (where it 404s). Mirrors SkillStore.dirForSkill.
                if bucket.linuxPrefix == AIChatViewModel.minisSkillsLinuxDir,
                   let bundledPath = bundledSkillHostPath(forTail: hit) {
                    return bundledPath
                }
                return bucket.hostDir.path + hit
            }
        }
        return nil
    }

    /// True when <id> is a bundled skill: its SKILL.md lives in the flat
    /// baseline and there is none in skills/default/. Mirrors
    /// SkillStore.dirForSkill exactly, so the router and the app-side
    /// resolver agree on where a skill lives. Two stat() calls max, used
    /// only for /var/minis/skills paths — never on the per-session /
    /// per-persona hot path.
    private func isBundledSkillId(_ id: String) -> Bool {
        let fm = FileManager.default
        let userSkillFile = PersonaStore.skillsDir(for: PersonaStore.defaultPersonaId)
            .appendingPathComponent(id).appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: userSkillFile.path) { return false }
        let baselineSkillFile = AIChatViewModel.minisSkillsPersistentDir
            .appendingPathComponent(id).appendingPathComponent("SKILL.md")
        return fm.fileExists(atPath: baselineSkillFile.path)
    }

    /// Host path for a /var/minis/skills/<id>/... tail when <id> is a
    /// bundled skill (see isBundledSkillId). Returns nil for user skills
    /// (route to skills/default/), for the bare bucket root, and when
    /// the id is unknown in both places — a brand-new skill being
    /// created routes to skills/default/, where SkillStore loads it from.
    private func bundledSkillHostPath(forTail hit: String) -> String? {
        let parts = hit.split(separator: "/", omittingEmptySubsequences: true)
        guard let id = parts.first.map(String.init), !id.isEmpty else { return nil }
        guard isBundledSkillId(id) else { return nil }
        return AIChatViewModel.minisSkillsPersistentDir.path + hit
    }

    /// Prefix match for one bucket: returns the tail (including the leading
    /// "/" when present) or nil. A prefix that is only a string prefix of a
    /// longer component (e.g. "/var/minis/memory2") must not match.
    private func matchBucket(_ guestPath: String, prefix: String) -> String? {
        guard guestPath.hasPrefix(prefix) else { return nil }
        let prefixEnd = guestPath.index(guestPath.startIndex, offsetBy: prefix.count)
        if prefixEnd != guestPath.endIndex && guestPath[prefixEnd] != "/" {
            return nil
        }
        return String(guestPath[prefixEnd...])
    }

    /// Reverse hook: given a host APFS path under <minisBaseURL>/<personaId>/<sid>/<bucket>,
    /// under a per-persona bucket root (<app-group>/<bucket>/[<personaPrefix>/]<personaId>),
    /// or under a global bucket dir (skills/default/, flat mcp-servers/),
    /// return the canonical guest path /var/minis/<bucket>/<tail>.
    /// Returns nil if the path doesn't live under any routed bucket
    /// (caller falls back to the static bind_mount_resolve table).
    private func reverse(hostPath: String) -> String? {
        if let hit = reverseSessionBucket(hostPath: hostPath) { return hit }
        if let hit = reverseGlobalBucket(hostPath: hostPath) { return hit }
        return reversePersonaBucket(hostPath: hostPath)
    }

    private func reverseSessionBucket(hostPath: String) -> String? {
        let basePath = minisBaseURL.path
        // F_GETPATH on iOS may resolve /var → /private/var; normalize that
        // so a single prefix compare suffices.
        var stripped = hostPath
        if hostPath.hasPrefix("/private/var/") && basePath.hasPrefix("/var/") {
            stripped = String(hostPath.dropFirst("/private".count))
        }
        guard stripped.hasPrefix(basePath + "/") else { return nil }
        let rest = stripped.dropFirst(basePath.count + 1)  // "<pid>/<sid>/<bucket>[/tail]"
        // Split into persona / sid / bucket / tail
        let parts = rest.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let sidPart = String(parts[1])
        let bucketName = String(parts[2])
        // Only translate sids we've actually issued a context for. Without this
        // guard, any path that happens to live under <basePath>/<X>/<Y>/<known-bucket>/
        // would be reverse-translated even when <Y> is a stale or unrelated
        // directory — harmless today but masks the cause of bugs.
        lock.lock()
        let known = sidToContext[sidPart] != nil
        lock.unlock()
        guard known else { return nil }
        guard let bucket = perSessionBuckets.first(where: { $0.hostSubdir == bucketName })
        else { return nil }
        let tail = parts.count == 4 ? "/" + parts[3] : ""
        return bucket.linuxPrefix + tail
    }

    /// Reverse for the global buckets: a host path under a global bucket
    /// dir maps back to /var/minis/<bucket>/<tail>, with no persona
    /// component. Skills reverse under skills/default/ (the global home)
    /// and under the flat skills/ root for bundled ids (round-2 new
    /// problem 5 — the forward direction routes those to the baseline,
    /// so the reverse must agree, or readdir/getpath would hand the
    /// guest a path that resolves elsewhere). MCP servers reverse from
    /// the flat root, including legacy <pid>/servers.json paths, which
    /// forward to the same flat location.
    private func reverseGlobalBucket(hostPath: String) -> String? {
        for bucket in globalBuckets {
            let basePath = bucket.hostDir.path
            var stripped = hostPath
            if hostPath.hasPrefix("/private/var/") && basePath.hasPrefix("/var/") {
                stripped = String(hostPath.dropFirst("/private".count))
            }
            guard stripped.hasPrefix(basePath + "/") else { continue }
            let tail = stripped.dropFirst(basePath.count)
            return bucket.linuxPrefix + tail
        }
        // Bundled skills under the flat skills/ root: reverse only when
        // the id is bundled by the same test the forward direction uses.
        // The flat root also holds pre-migration user-skill originals,
        // which must NOT reverse here — their guest path resolves to the
        // skills/default/ copy, and reversing them would hand back a
        // path that points at the copy, not the original.
        let flatSkills = AIChatViewModel.minisSkillsPersistentDir.path
        var stripped = hostPath
        if hostPath.hasPrefix("/private/var/") && flatSkills.hasPrefix("/var/") {
            stripped = String(hostPath.dropFirst("/private".count))
        }
        guard stripped.hasPrefix(flatSkills + "/") else { return nil }
        let tail = String(stripped.dropFirst(flatSkills.count))  // "/<id>/..."
        let parts = tail.split(separator: "/", omittingEmptySubsequences: true)
        guard let id = parts.first.map(String.init), !id.isEmpty else { return nil }
        guard isBundledSkillId(id) else { return nil }
        return AIChatViewModel.minisSkillsLinuxDir + tail
    }

    private func reversePersonaBucket(hostPath: String) -> String? {
        // Host paths under a per-persona bucket root, e.g.
        // <app-group>/memory/personas/<pid>/GLOBAL.md → /var/minis/memory/GLOBAL.md.
        // The first component after the root (and after the bucket's
        // persona prefix, if any) is the persona id: "default" or a
        // session id we issued a context for.
        for bucket in perPersonaBuckets {
            let basePath = bucket.hostRoot.path
            var stripped = hostPath
            if hostPath.hasPrefix("/private/var/") && basePath.hasPrefix("/var/") {
                stripped = String(hostPath.dropFirst("/private".count))
            }
            guard stripped.hasPrefix(basePath + "/") else { continue }
            var rest = stripped.dropFirst(basePath.count + 1)  // "[<prefix>/]<pid>[/tail]"
            if !bucket.personaPrefix.isEmpty {
                guard rest.hasPrefix(bucket.personaPrefix + "/") else { continue }
                rest = rest.dropFirst(bucket.personaPrefix.count + 1)
            }
            let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard let pidPart = parts.first else { continue }
            let pid = String(pidPart)
            lock.lock()
            let known = pid == PersonaStore.defaultPersonaId || sidToContext[pid] != nil
            lock.unlock()
            guard known else { continue }
            let tail = parts.count == 2 ? "/" + parts[1] : ""
            return bucket.linuxPrefix + tail
        }
        return nil
    }
}
