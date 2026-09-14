//
//  MinisFsRouter.swift
//  MinisApp
//
//  Routes guest paths under /var/minis/{offloads,attachments,workspace,browser}
//  and /var/minis/memory to per-owner host directories via the iSH fakefs
//  path-translate hook.
//
//  Each shell task gets a unique fs_context token (u64) stamped on the task
//  group spawned for it. When the task (or any forked child) touches a path
//  under one of the routed buckets, the C-level hook looks up the token here
//  and rewrites to ~/Library/.../minis/<owner>/<bucket>/...
//
//  [T-multi-assistant 09-14] A token carries BOTH ids:
//
//    • session buckets  → <base>/<sessionId>/<bucket>    ("what this chat is doing")
//    • assistant buckets → <base>/<assistantId>/<bucket> ("what this persona lived")
//
//  memory is an ASSISTANT bucket: every conversation of one assistant shares
//  one memory directory, and two assistants never see each other's. skills is
//  deliberately NOT routed here — it is a capability layer shared by every
//  assistant (one file on disk, per-assistant filtering of the *index* only).
//

import Foundation

final class MinisFsRouter: @unchecked Sendable {
    static let shared = MinisFsRouter()

    /// Owner of a route: which conversation, and which persona it belongs to.
    struct RouteKey: Hashable {
        let sessionId: String
        let assistantId: String
    }

    /// [T-multi-assistant 09-14] Assistant id used by every session that has no
    /// assistant of its own. Migration moves the pre-existing /var/minis/memory
    /// into <base>/<defaultAssistantId>/memory, so current behaviour (one shared
    /// memory) is preserved exactly rather than silently becoming per-session.
    static let defaultAssistantId = "default"

    /// Buckets that route per ASSISTANT — "what this persona has lived through".
    /// Every conversation of one assistant shares these; different assistants
    /// are physically isolated. NOTE the key is `assistantId`, NOT `sessionId`.
    ///
    /// `hostBase` differs from the session buckets on purpose: memory lives in
    /// the App Group container (not Library/MinisChat/minis) because the
    /// FileProvider extension must be able to read it. Routing it through a
    /// different base keeps that visibility while still making the SHELL path
    /// per-assistant — the hook rewrites /var/minis/memory to
    /// <appGroup>/memory/<assistantId>, so one assistant's shell cannot see
    /// another's memory even though the user can still browse all of them in
    /// iOS Files.
    private var assistantBuckets: [(linuxPrefix: String, hostSubdir: String, hostBase: URL)] {
        [(AIChatViewModel.minisMemoryLinuxDir, "memory", AIChatViewModel.minisAppGroupRoot)]
    }

    /// Buckets that route per SESSION — "what this conversation is doing".
    /// Two chats of the SAME assistant doing different work must not overwrite
    /// each other's files, so these stay session-scoped.
    private let sessionBuckets: [(linuxPrefix: String, hostSubdir: String)] = [
        (AIChatViewModel.minisOffloadsLinuxDir,    "offloads"),
        (AIChatViewModel.minisAttachmentsLinuxDir, "attachments"),
        (AIChatViewModel.minisWorkspaceLinuxDir,   "workspace"),
        (AIChatViewModel.minisBrowserLinuxDir,     "browser"),
    ]

    private let lock = NSLock()
    private var nextContext: UInt64 = 1
    private var contextToKey: [UInt64: RouteKey] = [:]
    private var keyToContext: [RouteKey: UInt64] = [:]
    /// Known owners, for the reverse hook's "did we issue this?" guard.
    private var knownSessionIds: Set<String> = []
    private var knownAssistantIds: Set<String> = []

    /// Host base URL (~/Library/MinisChat/minis). Captured once at install time.
    private let minisBaseURL: URL

    private init() {
        self.minisBaseURL = AIChatViewModel.minisPersistentBase
    }

    // MARK: - Context allocation

    /// Allocate a stable fs_context token for (session, assistant). Repeated
    /// calls with the same pair return the same token, so workers can be
    /// respawned without invalidating prior routing.
    func context(forSession sessionId: String, assistantId: String) -> UInt64 {
        let key = RouteKey(sessionId: sessionId, assistantId: assistantId)
        lock.lock(); defer { lock.unlock() }
        if let existing = keyToContext[key] { return existing }
        let ctx = nextContext
        nextContext &+= 1
        if nextContext == 0 { nextContext = 1 }   // never hand out 0 (= "no override")
        contextToKey[ctx] = key
        keyToContext[key] = ctx
        knownSessionIds.insert(sessionId)
        knownAssistantIds.insert(assistantId)
        return ctx
    }

    /// Convenience for call sites that do not know an assistant yet — routes
    /// assistant buckets to the shared default assistant, preserving the
    /// single-memory behaviour that predates multi-assistant support.
    func context(for sid: String) -> UInt64 {
        context(forSession: sid, assistantId: Self.defaultAssistantId)
    }

    /// The session that owns this token, or nil if the token was never issued.
    func sid(for context: UInt64) -> String? {
        if context == 0 { return nil }
        lock.lock(); defer { lock.unlock() }
        return contextToKey[context]?.sessionId
    }

    /// The assistant that owns this token, or nil if the token was never issued.
    func assistantId(for context: UInt64) -> String? {
        if context == 0 { return nil }
        lock.lock(); defer { lock.unlock() }
        return contextToKey[context]?.assistantId
    }

    // MARK: - Hook installation

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
        guard fsContext != 0 else { return nil }
        lock.lock()
        let key = contextToKey[fsContext]
        lock.unlock()
        guard let key else { return nil }
        return hostPath(forGuest: guestPath, key: key)
    }

    /// Resolve a guest path under one of the routed buckets to its host URL for
    /// the given owner. Returns nil if the path is not under any routed bucket
    /// (caller should fall back to the static mount table).
    /// Used by Swift call sites that need the host path without going through
    /// iSH (e.g. NSFileCoordinator on attachments).
    ///
    /// `sid` here is the SESSION id (legacy signature); assistant buckets use
    /// the default assistant. Prefer `hostURL(forGuest:sessionId:assistantId:)`
    /// when the caller knows the assistant.
    func hostURL(forGuest guestPath: String, sid: String) -> URL? {
        hostURL(forGuest: guestPath, sessionId: sid, assistantId: Self.defaultAssistantId)
    }

    func hostURL(forGuest guestPath: String, sessionId: String, assistantId: String) -> URL? {
        guard let path = hostPath(forGuest: guestPath,
                                  key: RouteKey(sessionId: sessionId, assistantId: assistantId))
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func hostPath(forGuest guestPath: String, key: RouteKey) -> String? {
        for bucket in assistantBuckets {
            guard let tail = tailIfUnder(prefix: bucket.linuxPrefix, guestPath: guestPath) else { continue }
            return bucket.hostBase
                .appendingPathComponent(bucket.hostSubdir, isDirectory: true)
                .appendingPathComponent(key.assistantId, isDirectory: true)
                .path + tail
        }
        for bucket in sessionBuckets {
            guard let tail = tailIfUnder(prefix: bucket.linuxPrefix, guestPath: guestPath) else { continue }
            return minisBaseURL
                .appendingPathComponent(key.sessionId, isDirectory: true)
                .appendingPathComponent(bucket.hostSubdir, isDirectory: true)
                .path + tail
        }
        return nil
    }

    /// Returns the path tail (starting at "/", or empty for the bucket root)
    /// when `guestPath` is the prefix itself or lives under it. Enforces a
    /// path-segment boundary so "/var/minis/memoryfoo" does not match
    /// "/var/minis/memory".
    private func tailIfUnder(prefix: String, guestPath: String) -> String? {
        guard guestPath.hasPrefix(prefix) else { return nil }
        let prefixEnd = guestPath.index(guestPath.startIndex, offsetBy: prefix.count)
        if prefixEnd != guestPath.endIndex && guestPath[prefixEnd] != "/" { return nil }
        return String(guestPath[prefixEnd...])
    }

    /// Reverse hook: given a host APFS path under <minisBaseURL>/<owner>/<bucket>,
    /// return the canonical guest path /var/minis/<bucket>/<tail>.
    /// Returns nil if the path doesn't live under any routed bucket
    /// (caller falls back to the static bind_mount_resolve table).
    private func reverse(hostPath: String) -> String? {
        // Two roots: session buckets live under Library/MinisChat/minis, memory
        // under the App Group container. Try the assistant (App Group) root
        // first, then the session root.
        if let guest = reverseUnder(root: AIChatViewModel.minisAppGroupRoot,
                                    hostPath: hostPath,
                                    buckets: assistantBuckets.map { ($0.hostSubdir, $0.linuxPrefix) },
                                    ownerIsAssistant: true) {
            return guest
        }
        return reverseUnder(root: minisBaseURL,
                            hostPath: hostPath,
                            buckets: sessionBuckets.map { ($0.hostSubdir, $0.linuxPrefix) },
                            ownerIsAssistant: false)
    }

    /// Shared body of the reverse hook for one root.
    /// `buckets` maps hostSubdir → guest linux prefix.
    private func reverseUnder(root: URL,
                              hostPath: String,
                              buckets: [(String, String)],
                              ownerIsAssistant: Bool) -> String? {
        let basePath = root.path
        // F_GETPATH on iOS may resolve /var → /private/var; normalize that
        // so a single prefix compare suffices.
        var stripped = hostPath
        if hostPath.hasPrefix("/private/var/") && basePath.hasPrefix("/var/") {
            stripped = String(hostPath.dropFirst("/private".count))
        }
        guard stripped.hasPrefix(basePath + "/") else { return nil }
        let rest = stripped.dropFirst(basePath.count + 1)  // "<owner>/<bucket>[/tail]"
        let parts = rest.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let owner = String(parts[0])
        let bucketName = String(parts[1])
        let tail = parts.count == 3 ? "/" + parts[2] : ""

        // Only translate owners we've actually issued a context for, and only
        // for the bucket kind that owner is allowed to own. Without this guard
        // any path that happens to live under <basePath>/<X>/<known-bucket>/
        // would reverse-translate even when <X> is stale or unrelated — harmless
        // today but it masks the cause of bugs.
        lock.lock()
        let owned = ownerIsAssistant ? knownAssistantIds.contains(owner)
                                     : knownSessionIds.contains(owner)
        lock.unlock()
        guard owned else { return nil }

        guard let (_, prefix) = buckets.first(where: { $0.0 == bucketName }) else { return nil }
        return prefix + tail
    }
}
