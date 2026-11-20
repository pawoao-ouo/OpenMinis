//
//  MinisFsRouter.swift
//  MinisApp
//
//  Routes guest paths under /var/minis/{offloads,attachments,workspace,browser}
//  to per-session host directories, and guest paths under
//  /var/minis/{memory,skills,shared,mcp-servers} to per-persona host
//  directories, via the iSH fakefs path-translate hook.
//
//  Each session gets a unique fs_context token (u64) that is stamped on the
//  task group spawned for that session. When the task (or any of its forked
//  children) touches a path under one of the per-session buckets, the C-level
//  hook looks up the token here and rewrites to
//  ~/Library/.../minis/<personaId>/<sid>/<bucket>/...
//  Per-persona buckets rewrite to <app-group>/<bucket>/<personaId>/...
//  except memory, which rewrites to <app-group>/memory/personas/<personaId>/
//  (the runtime layout, crosscheck-verdict §4). mcp-servers lives under
//  MinisConfig instead of the app group.
//
//  Shared routes to the persona namespace (shared/<personaId>/): new shared
//  data written by a persona is namespaced there. The flat shared/ dir is
//  NOT routed here and NOT locked — it is the live read/write runtime
//  area (events.jsonl, together/, heartbeat) for host-side services, and
//  isolation for shared lives in resolution, not in a filesystem lock
//  (see PersonaStore.isCrossPersonaSharedPath).
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
    /// runtime layout); skills/shared/mcp-servers keep the direct
    /// <bucket>/<id>/ layout. These used to fall through to the legacy
    /// g_bind_mounts[] table, where the first session to mount won and
    /// every persona saw the same global files — that is the leak this
    /// isolation work closes.
    private let perPersonaBuckets: [(linuxPrefix: String, hostRoot: URL, personaPrefix: String)] = [
        (AIChatViewModel.minisMemoryLinuxDir,     AIChatViewModel.minisMemoryPersistentDir, "personas"),
        (AIChatViewModel.minisSkillsLinuxDir,     AIChatViewModel.minisSkillsPersistentDir, ""),
        (AIChatViewModel.minisSharedLinuxDir,     AIChatViewModel.minisSharedPersistentDir, ""),
        (AIChatViewModel.minisMcpServersLinuxDir, AIChatViewModel.minisMcpServersPersistentDir, ""),
    ]

    private let lock = NSLock()
    private var nextContext: UInt64 = 1
    private var contextToSid: [UInt64: String] = [:]
    private var sidToContext: [String: UInt64] = [:]
    /// Persona captured when the context was issued (from the PersonaStore
    /// cache — populated at session load/create, so this is always set by
    /// the time a task spawns). A session's persona never changes.
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
        contextToPersona[ctx] = PersonaStore.personaId(forSessionId: sid)
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
    /// MUST stay non-blocking — only a hash lookup + a few string ops.
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
        // translate hook uses the context-captured value), else the cache
        // ("default" on a miss).
        let personaId = personaId ?? PersonaStore.personaId(forSessionId: sid)
        for bucket in perSessionBuckets {
            if let hit = matchBucket(guestPath, prefix: bucket.linuxPrefix) {
                return minisBaseURL
                    .appendingPathComponent(personaId, isDirectory: true)
                    .appendingPathComponent(sid, isDirectory: true)
                    .appendingPathComponent(bucket.hostSubdir, isDirectory: true)
                    .path + hit
            }
        }
        for bucket in perPersonaBuckets {
            if let hit = matchBucket(guestPath, prefix: bucket.linuxPrefix) {
                var url = bucket.hostRoot
                if !bucket.personaPrefix.isEmpty {
                    url = url.appendingPathComponent(bucket.personaPrefix, isDirectory: true)
                }
                return url
                    .appendingPathComponent(personaId, isDirectory: true)
                    .path + hit
            }
        }
        return nil
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

    /// Reverse hook: given a host APFS path under <minisBaseURL>/<personaId>/<sid>/<bucket>
    /// or under a per-persona bucket root (<app-group>/<bucket>/[<personaPrefix>/]<personaId>),
    /// return the canonical guest path /var/minis/<bucket>/<tail>.
    /// Returns nil if the path doesn't live under any routed bucket
    /// (caller falls back to the static bind_mount_resolve table).
    private func reverse(hostPath: String) -> String? {
        if let hit = reverseSessionBucket(hostPath: hostPath) { return hit }
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
