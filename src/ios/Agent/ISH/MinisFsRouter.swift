//
//  MinisFsRouter.swift
//  MinisApp
//
//  Routes guest paths under /var/minis/{offloads,attachments,workspace,browser}
//  to per-session host directories via the iSH fakefs path-translate hook.
//
//  Each session gets a unique fs_context token (u64) that is stamped on the
//  task group spawned for that session. When the task (or any of its forked
//  children) touches a path under one of the per-session buckets, the C-level
//  hook looks up the token here and rewrites to ~/Library/.../minis/<sid>/<bucket>/...
//

import Foundation

final class MinisFsRouter: @unchecked Sendable {
    static let shared = MinisFsRouter()

    /// Guest path prefixes that route per-session. Anything under one of these
    /// becomes ~/Library/.../minis/<sid>/<bucket>/<tail>. Paths under
    /// /var/minis/{memory,skills,shared} stay global and are NOT listed here —
    /// they fall through to the legacy g_bind_mounts[] table.
    private let perSessionBuckets: [(linuxPrefix: String, hostSubdir: String)] = [
        (AIChatViewModel.minisOffloadsLinuxDir,    "offloads"),
        (AIChatViewModel.minisAttachmentsLinuxDir, "attachments"),
        (AIChatViewModel.minisWorkspaceLinuxDir,   "workspace"),
        (AIChatViewModel.minisBrowserLinuxDir,     "browser"),
    ]

    private let lock = NSLock()
    private var nextContext: UInt64 = 1
    private var contextToSid: [UInt64: String] = [:]
    private var sidToContext: [String: UInt64] = [:]

    /// ［persona］F1: session → persona, for the memory rules in `translate`.
    /// Lock-protected because the path-translate hook runs on iSH worker
    /// threads, unlike `PersonaStore.sessionPersonaCache` which is
    /// @MainActor-confined. Populated at loadSession (next to
    /// `PersonaStore.notePersonaId`) and, as a backstop, in
    /// `ISHExecutionCoordinator.execute()` before the first command of a
    /// session runs. Session ids are UUIDs, never reused, so entries are
    /// dropped only on `sessionDidTerminate`. A session with no entry here
    /// has an unknown persona — the hook fails closed for its memory paths.
    private let personaLock = NSLock()
    private var sidToPersona: [String: String] = [:]

    /// ［persona］F1: remember which persona a session belongs to (see above).
    func notePersona(sessionId: String, personaId: String) {
        personaLock.lock(); defer { personaLock.unlock() }
        sidToPersona[sessionId] = personaId
    }

    /// ［persona］F1: the persona noted for a session, or nil when unknown.
    /// Thread-safe; safe to call from the translate hook.
    func persona(forSession sid: String) -> String? {
        personaLock.lock(); defer { personaLock.unlock() }
        return sidToPersona[sid]
    }

    /// ［persona］F1: forget a terminated session's persona mapping.
    func dropSession(_ sid: String) {
        personaLock.lock(); defer { personaLock.unlock() }
        sidToPersona[sid] = nil
    }

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
        return ctx
    }

    /// Reverse lookup. Returns nil if the token was never issued or has been
    /// freed. Hot-path: keep this branchless.
    func sid(for context: UInt64) -> String? {
        if context == 0 { return nil }
        lock.lock(); defer { lock.unlock() }
        return contextToSid[context]
    }

    // MARK: - Calling-task fs_context (thread-local)

    /// ThreadDictionary key for the fs_context most recently seen on this
    /// thread. See noteCallingFsContext.
    private static let callingFsContextKey = "com.openminis.callingFsContext"

    /// ［persona］Record the fs_context of the task whose path translation
    /// just ran on this thread. The fakefs path-translate hook is invoked
    /// with `current->group->fs_context` for EVERY guest path translation
    /// (fakefs `bind_mount_translate_path_ex`, called with the calling
    /// task's token before the static bind-mount table), on the calling
    /// iSH worker thread — and a native offload handler runs synchronously
    /// on that same guest thread (`native_offload.c` `exec_handler`:
    /// argv paths are translated, then the handler is called, then
    /// `do_exit()`). So when a guest shell execs `minis-config`, the
    /// argv[0] translation records that shell's own token on this thread
    /// immediately before the handler reads it — no global snapshot, no
    /// race with other sessions' shells. A thread runs one task at a time,
    /// and every translation refreshes the record, so a reused thread
    /// cannot serve a stale token: the exec's own argv translation
    /// overwrites it first.
    ///
    /// Only non-zero tokens are recorded (0 = "no override", the global
    /// view). Hot path: one dictionary write per translation.
    static func noteCallingFsContext(_ context: UInt64) {
        guard context != 0 else { return }
        Thread.current.threadDictionary[callingFsContextKey] = NSNumber(value: context)
    }

    /// The fs_context recorded for the current thread by
    /// noteCallingFsContext, or 0 when this thread has never translated a
    /// path (e.g. a Debug RPC thread, or an in-app UI thread). Callers
    /// must treat 0 as "no per-command context" and fall back.
    static func callingFsContext() -> UInt64 {
        (Thread.current.threadDictionary[callingFsContextKey] as? NSNumber)?.uint64Value ?? 0
    }

    /// Install the path-translate hook on ISHKernel. Idempotent; call once
    /// at boot before any session task is spawned. Installs both the
    /// forward hook (guest→host) and the reverse hook (host→guest) — the
    /// reverse hook is needed by readdir/getpath when fakefs has resolved
    /// a hook-routed path through F_GETPATH and needs to map it back so
    /// meta.db inode lookup works.
    func installHook() {
        ISHKernel.shared.installPathTranslateHandler { [weak self] guestPath, fsContext in
            // ［persona］Record the calling task's token on this thread
            // BEFORE translating: an offload handler invoked from this
            // task reads it back to identify its caller (F6-a). See
            // noteCallingFsContext.
            MinisFsRouter.noteCallingFsContext(fsContext)
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
        // ［persona］F1: memory is allowlisted per session (own persona dir
        // + the user profile) BEFORE the bucket check. A refused path gets a
        // host path that cannot exist, so the guest operation fails with
        // ENOENT instead of falling through to the flat static mount.
        if let refused = translateMemory(guestPath: guestPath, sid: sid) {
            return refused
        }
        return hostPath(forGuest: guestPath, sid: sid)
    }

    /// ［persona］F1: per-session memory rules for the translate hook.
    ///
    /// The guest mount for `/var/minis/memory` is the flat root, so without
    /// this the shell of ANY persona can `cat` another persona's SOUL.md /
    /// GLOBAL.md / daily logs, `rg` the whole tree, or `ls` the registry.
    /// This is the mount layer the write guard's comment points at as the
    /// full enforcement ("the mount layer keeps full enforcement as a
    /// follow-up").
    ///
    /// Allowlist — everything else under `/var/minis/memory` is refused:
    /// - `/var/minis/memory/personas/<own>/...` (the session's own memory;
    ///   these are exactly the paths the system prompt teaches the model)
    /// - `/var/minis/memory/personas/me/...` (the user profile — the model
    ///   is told to write confirmed new facts there, same allowance as the
    ///   file-tool write guard's B28 R15)
    ///
    /// Refused, by design: the bare memory root and `personas/` listings
    /// (they enumerate persona ids), `personas.json` (the registry),
    /// legacy root files, and every other persona's directory.
    ///
    /// Returns nil when the path is allowed (fall through to the static
    /// mount table, as today) or is not a memory path at all; otherwise
    /// returns a host path that cannot exist, so the guest operation fails.
    /// The guest path is standardized lexically first, so a `..` that walks
    /// out of the own dir (`personas/<own>/../../personas/<other>/...`) is
    /// judged on where it actually lands, not on the first segment. A
    /// symlink inside the own dir pointing out is NOT caught here (the hook
    /// sees the lexical path) — that escape is caught host-side by the
    /// canonical check in `resolvePathForDirectRead`, and a guest-created
    /// symlink to a guest absolute path is re-translated on follow, so it
    /// lands back here.
    ///
    /// fs_context 0 (no session token — e.g. the user's own terminal, which
    /// spawns its shell outside `execute()`) never reaches this code:
    /// `translate` returns nil before it, so the terminal keeps its full
    /// view. Only session-stamped shells are scoped.
    private func translateMemory(guestPath: String, sid: String) -> String? {
        let prefix = AIChatViewModel.minisMemoryLinuxDir
        guard guestPath == prefix || guestPath.hasPrefix(prefix + "/") else { return nil }
        // Unknown persona fails closed: an unnoted session sees no memory.
        guard let persona = persona(forSession: sid) else {
            return blockedPath(forSession: sid)
        }
        let std = (guestPath as NSString).standardizingPath
        guard std.hasPrefix(prefix + "/") else {
            // The bare root (or a trailing-slash form of it) — a listing
            // would enumerate the tree; refuse.
            return blockedPath(forSession: sid)
        }
        let tail = String(std.dropFirst(prefix.count + 1))  // after "/var/minis/memory/"
        guard tail.hasPrefix("personas/") else {
            // personas.json, legacy root files — not addressable per-persona.
            return blockedPath(forSession: sid)
        }
        let afterPersonas = String(tail.dropFirst("personas/".count))
        let seg = afterPersonas.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        if seg == persona || seg == PersonaStore.userProfilePersonaID {
            return nil  // own dir (or the user profile) — fall through to the mount.
        }
        return blockedPath(forSession: sid)
    }

    /// ［persona］F1: the host path a refused memory translation resolves
    /// to. It is deliberately a path that does not exist: reads fail with
    /// ENOENT, writes fail because the parent is missing. Per-session, so
    /// one session's refused writes can never become another session's
    /// readable file, and unreachable from every allowed translation — no
    /// bucket, mount, or host-side resolver maps into it.
    private func blockedPath(forSession sid: String) -> String {
        minisBaseURL
            .appendingPathComponent(sid, isDirectory: true)
            .appendingPathComponent("__persona_blocked__", isDirectory: true)
            .path
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

    private func hostPath(forGuest guestPath: String, sid: String) -> String? {
        for bucket in perSessionBuckets {
            let prefix = bucket.linuxPrefix
            guard guestPath.hasPrefix(prefix) else { continue }
            let prefixEnd = guestPath.index(guestPath.startIndex, offsetBy: prefix.count)
            if prefixEnd != guestPath.endIndex && guestPath[prefixEnd] != "/" {
                continue
            }
            let tail = String(guestPath[prefixEnd...])
            let bucketPath = minisBaseURL
                .appendingPathComponent(sid, isDirectory: true)
                .appendingPathComponent(bucket.hostSubdir, isDirectory: true)
                .path
            // The guest controls the tail: appended raw, a "/../../" tail
            // walks straight out of the bucket into the rest of the app
            // sandbox. Standardize lexically (string-only, safe for this
            // hot path) and confine the result to the bucket directory.
            let resolved = (bucketPath + tail as NSString).standardizingPath
            guard resolved == bucketPath || resolved.hasPrefix(bucketPath + "/") else { return nil }
            return resolved
        }
        return nil
    }

    /// Reverse hook: given a host APFS path under <minisBaseURL>/<sid>/<bucket>,
    /// return the canonical guest path /var/minis/<bucket>/<tail>.
    /// Returns nil if the path doesn't live under any per-session bucket
    /// (caller falls back to the static bind_mount_resolve table).
    private func reverse(hostPath: String) -> String? {
        let basePath = minisBaseURL.path
        // F_GETPATH on iOS may resolve /var → /private/var; normalize that
        // so a single prefix compare suffices.
        var stripped = hostPath
        if hostPath.hasPrefix("/private/var/") && basePath.hasPrefix("/var/") {
            stripped = String(hostPath.dropFirst("/private".count))
        }
        guard stripped.hasPrefix(basePath + "/") else { return nil }
        let rest = stripped.dropFirst(basePath.count + 1)  // "<sid>/<bucket>[/tail]"
        // Split into sid / bucket / tail
        let parts = rest.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let sidPart = String(parts[0])
        let bucketName = String(parts[1])
        // Only translate sids we've actually issued a context for. Without this
        // guard, any path that happens to live under <basePath>/<X>/<known-bucket>/
        // would be reverse-translated even when <X> is a stale or unrelated
        // directory — harmless today but masks the cause of bugs.
        lock.lock()
        let known = sidToContext[sidPart] != nil
        lock.unlock()
        guard known else { return nil }
        guard let bucket = perSessionBuckets.first(where: { $0.hostSubdir == bucketName })
        else { return nil }
        let tail = parts.count == 3 ? "/" + parts[2] : ""
        return bucket.linuxPrefix + tail
    }
}
