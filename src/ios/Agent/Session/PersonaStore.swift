import Foundation

/// Multi-persona isolation: persona identity + per-persona directory layout.
///
/// A persona IS a session: `sessions.persona_id` holds the persona id.
/// A new session is its own persona (persona_id == session id) and starts
/// with empty memory/SOUL dirs — it inherits nothing from any other
/// persona. Rows predating the column read back "default" and share the
/// one-time migrated copy of the old shared data at memory/personas/default/.
/// Fork/duplicate inherit the source session's persona id (same persona,
/// new conversation thread). There is no separate Persona type and no
/// persona picker UI — that is a product decision, not an omission here.
///
/// Layout (decisions.md §3 as amended by crosscheck-verdict §4 — the
/// runtime already stores personas this way, so the app adopts the
/// existing layout instead of inventing a second one):
///   memory/personas/<personaId>/GLOBAL.md, .../YYYY-MM-DD.md, .../SOUL.md
///   skills/ and mcp-servers/ are GLOBAL, not per-persona (user decision
///   2026-11-20: splitting them would make the model download duplicates;
///   a tool that exists can just be used): skills load once from
///   skills/default/, MCP from the single flat mcp-servers/servers.json.
///   shared/<personaId>/ — persona namespace for new shared data.
///     The flat shared/ dir itself is a LIVE read/write runtime area
///     (events.jsonl, together/, heartbeat state, user scripts — see
///     crosscheck-verdict §5). It is NOT locked read-only. Isolation for
///     shared lives in the resolution/injection layer, not in a
///     filesystem lock: reads resolve persona-namespace-first, and
///     cross-persona writes are denied by `isCrossPersonaSharedPath`.
///   minisPersistentBase/<personaId>/<sessionId>/<host>/ for session buckets
///   memory/personas/me/ is the USER profile (personas/me/SOUL.md), not a
///   persona — `allPersonaIds()` excludes it everywhere personas are
///   enumerated.
///
/// The old flat locations (memory/GLOBAL.md, skills/, shared/,
/// mcp-servers/servers.json, minisPersistentBase/<sessionId>/) are kept
/// as a legacy baseline and are NEVER written again after the
/// one-time migration — except the flat shared/ dir, which stays live
/// read/write for the runtime services above. The original shared data
/// is never deleted — deletion is the user's call, not this code's.
enum PersonaStore {

    static let defaultPersonaId = "default"
    /// User-profile pseudo-persona (personas/me/SOUL.md): the human's own
    /// profile, injected as "about the person you're talking to" — NOT a
    /// persona. Must be excluded whenever personas are enumerated.
    static let userProfilePersonaId = "me"
    static let migrationFlagKey = "personaIsolation.migrationCompleted.v2"

    // MARK: - Identity

    /// In-memory persona cache, keyed by session id. Populated whenever a
    /// session is loaded or created (AIChatViewModel load/create path) so
    /// sync call sites (static resolveMinisURL, iSH routing) never need an
    /// actor hop into ChatStore. A cache miss resolves to "default" — the
    /// migrated legacy data — never to another persona's data.
    private static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()

    static func notePersonaId(_ personaId: String, forSessionId sid: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[sid] = personaId
    }

    static func personaId(forSessionId sid: String?) -> String {
        guard let sid else { return defaultPersonaId }
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[sid] ?? defaultPersonaId
    }

    static func forgetSession(_ sid: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache.removeValue(forKey: sid)
    }

    // MARK: - Per-persona directories (iOS side)

    /// The personas container: <memory>/personas/. Adopted from the
    /// runtime layout (crosscheck-verdict §4) — the in-app AI already
    /// stores SOUL.md here, so the app uses the same root instead of a
    /// second, parallel memory/<personaId>/ layout.
    static func personasDir() -> URL {
        AIChatViewModel.minisMemoryPersistentDir
            .appendingPathComponent("personas", isDirectory: true)
    }

    /// All persona ids that have a memory dir, EXCLUDING the user-profile
    /// pseudo-persona ("me"). Sorted for determinism. Used wherever
    /// personas are enumerated (backup, sync, @-mention index) so the
    /// user profile is never treated as a persona.
    static func allPersonaIds() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: personasDir().path)) ?? []
        return names
            .filter { $0 != userProfilePersonaId && !$0.hasPrefix(".") }
            .filter { name in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: personasDir().appendingPathComponent(name).path,
                                     isDirectory: &isDir) && isDir.boolValue
            }
            .sorted()
    }

    /// Persona ids this process knows about: the on-disk set plus the
    /// in-memory session→persona cache plus "default". Used by the
    /// cross-persona shared-write guard to tell a persona namespace
    /// (shared/<personaId>/) apart from shared runtime subdirs
    /// (shared/together/, shared/state/, ...).
    static func knownPersonaIds() -> Set<String> {
        var ids = Set(allPersonaIds())
        ids.insert(defaultPersonaId)
        cacheLock.lock(); defer { cacheLock.unlock() }
        for pid in cache.values { ids.insert(pid) }
        return ids
    }

    /// Per-persona memory root: <memory>/personas/<personaId>/
    static func memoryDir(for personaId: String) -> URL {
        personasDir().appendingPathComponent(personaId, isDirectory: true)
    }

    static func soulFileURL(for personaId: String) -> URL {
        memoryDir(for: personaId).appendingPathComponent("SOUL.md")
    }

    static func globalMemoryFileURL(for personaId: String) -> URL {
        memoryDir(for: personaId).appendingPathComponent("GLOBAL.md")
    }

    static func dailyMemoryFileURL(for personaId: String, date: Date = Date()) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        return memoryDir(for: personaId)
            .appendingPathComponent("\(fmt.string(from: date)).md")
    }

    /// Skills root: <skills>/<personaId>/. Skills are GLOBAL, shared by
    /// all personas (user decision 2026-11-20) — every caller passes
    /// defaultPersonaId, so the single live home is skills/default/.
    /// The flat skills/ dir stays as a read-only baseline of bundled
    /// skills. The 1b migration copied pre-existing user skills into
    /// skills/default/.
    static func skillsDir(for personaId: String) -> URL {
        AIChatViewModel.minisSkillsPersistentDir
            .appendingPathComponent(personaId, isDirectory: true)
    }

    /// Per-persona shared namespace — where THIS persona's new shared
    /// data lands. The flat shared/ dir is NOT a read-only mount: it is
    /// the live read/write runtime area (events.jsonl, together/,
    /// heartbeat state — crosscheck-verdict §5) and stays writable for
    /// host-side services. Isolation for shared lives in resolution
    /// (persona namespace first, flat area second) and in the
    /// cross-persona write guard below — never in a filesystem lock.
    static func sharedDir(for personaId: String) -> URL {
        AIChatViewModel.minisSharedPersistentDir
            .appendingPathComponent(personaId, isDirectory: true)
    }

    /// Cross-persona write guard for the shared area (crosscheck-verdict
    /// §5: "cross-persona writes need explicit authorization").
    /// Returns true when `url` resolves inside ANOTHER persona's shared
    /// namespace (shared/<otherPersonaId>/...). The flat shared area
    /// itself (shared/events.jsonl, shared/together/, ...) is shared
    /// runtime state and is always allowed; the caller's own namespace
    /// is always allowed. There is no authorization mechanism yet, so
    /// this is deny-by-default: callers reject when it returns true.
    /// Resolution already makes such a path unreachable through the
    /// router / resolveMinisURL (both append the CALLER's persona), so
    /// this is defence-in-depth against a resolution bug or a symlink
    /// escape — it must never be the only line of defence, and must
    /// never be removed because "resolution already handles it".
    static func isCrossPersonaSharedPath(_ url: URL, for personaId: String) -> Bool {
        let sharedRoot = AIChatViewModel.minisSharedPersistentDir
            .standardizedFileURL.resolvingSymlinksInPath().path
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard target.hasPrefix(sharedRoot + "/") else { return false }
        let rest = String(target.dropFirst(sharedRoot.count + 1))
        let first = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        guard !first.isEmpty, first != personaId else { return false }
        // A first component that is a known persona id is a namespace;
        // anything else (together/, state/, a file) is shared runtime area.
        return knownPersonaIds().contains(first)
    }

    /// Per-session bucket root: <minis>/<personaId>/<sessionId>/
    static func sessionDir(for sessionId: String, personaId: String) -> URL {
        AIChatViewModel.minisPersistentBase
            .appendingPathComponent(personaId, isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
    }

    /// One host bucket inside a session dir: <minis>/<personaId>/<sid>/<host>/
    static func sessionHostDir(for sessionId: String, personaId: String, host: String) -> URL {
        sessionDir(for: sessionId, personaId: personaId)
            .appendingPathComponent(host, isDirectory: true)
    }

    // MARK: - iSH (Linux) paths, per persona

    /// /var/minis/memory/personas/<personaId> — the iSH-visible memory dir.
    static func memoryLinuxDir(for personaId: String) -> String {
        "\(AIChatViewModel.minisMemoryLinuxDir)/personas/\(personaId)"
    }

    static func skillsLinuxDir(for personaId: String) -> String {
        "\(AIChatViewModel.minisSkillsLinuxDir)/\(personaId)"
    }

    static func sharedLinuxDir(for personaId: String) -> String {
        "\(AIChatViewModel.minisSharedLinuxDir)/\(personaId)"
    }

    static func mcpServersLinuxDir(for personaId: String) -> String {
        "\(AIChatViewModel.minisMcpServersLinuxDir)/\(personaId)"
    }

    // MARK: - One-time legacy migration

    /// Shared one-time migration task. Started at app launch (MinisApp
    /// touches it in init); session loading awaits it so no prompt is
    /// ever built against pre-migration paths. After the first run the
    /// flag short-circuit makes awaiting it a no-op.
    static let migrationTask: Task<Void, Never> = Task {
        await migrateLegacyDataIfNeeded()
    }

    /// Copies the old shared memory/SOUL files into memory/personas/default/
    /// and moves flat per-session dirs under their persona. Idempotent:
    /// guarded by a UserDefaults flag and by "target missing" checks, so a
    /// re-run is a no-op. Originals are NEVER deleted here — the flat
    /// memory/GLOBAL.md etc. stay on disk, and whether to delete them
    /// after 30 days is the user's call.
    ///
    /// Layout history this migration must absorb (crosscheck-verdict §4):
    ///   - flat memory/*.md (pre-isolation) → personas/default/
    ///   - memory/<id>/*.md (the unshipped v1 layout, memory/<personaId>/)
    ///     → personas/<id>/ — any dir directly under memory/ other than
    ///     "personas" itself is treated as a v1 persona dir.
    ///   - memory/personas/<id>/ (the runtime layout) is already correct:
    ///     SOUL.md and history logs there are left exactly in place —
    ///     nothing is moved or overwritten when the target already exists.
    ///     In particular personas/default/ history logs stay the default
    ///     persona, and personas/me/ (user profile) is never touched.
    ///
    /// Must be called once at app launch (MinisApp), before any session
    /// loads: it needs ChatStore (actor) for session→persona lookups.
    static func migrateLegacyDataIfNeeded() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: migrationFlagKey) { return }
        let fm = FileManager.default
        let legacyMemory = AIChatViewModel.minisMemoryPersistentDir

        // 1. Memory + SOUL: copy flat files into memory/personas/default/.
        //    SOUL.md at the root is copied only when personas/default/
        //    has none — a SOUL already in place is never overwritten.
        let defaultDir = memoryDir(for: defaultPersonaId)
        do {
            try fm.createDirectory(at: defaultDir, withIntermediateDirectories: true)
            if let entries = try? fm.contentsOfDirectory(
                at: legacyMemory, includingPropertiesForKeys: nil
            ) {
                for src in entries where src.pathExtension == "md" {
                    let dst = defaultDir.appendingPathComponent(src.lastPathComponent)
                    if !fm.fileExists(atPath: dst.path) {
                        try? fm.copyItem(at: src, to: dst)
                    }
                }
            }
        }

        // 1a. v1 layout: memory/<personaId>/*.md → memory/personas/<personaId>/.
        //     The "personas" container itself is skipped; every other direct
        //     subdir is a v1 persona dir. Target-missing guard: a file the
        //     runtime already placed in personas/<id>/ is never overwritten.
        if let entries = try? fm.contentsOfDirectory(
            at: legacyMemory, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for dir in entries where dir.lastPathComponent != "personas" {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let personaId = dir.lastPathComponent
                let dstDir = memoryDir(for: personaId)
                do {
                    try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
                    if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                        for src in files where src.pathExtension == "md" {
                            let dst = dstDir.appendingPathComponent(src.lastPathComponent)
                            if !fm.fileExists(atPath: dst.path) {
                                try? fm.copyItem(at: src, to: dst)
                            }
                        }
                    }
                }
            }
        }

        // 1b. Skills: copy flat user skill dirs into skills/default/ so
        // the default persona keeps them. (loadSkills only falls back to
        // the flat baseline for BUNDLED skills; user skills must live in
        // the persona dir to load.) Bundled skills stay in the baseline.
        // MCP needs no copy: MCPStore falls back to the flat baseline.
        // Shared needs no copy: flat shared/ is the live read/write
        // runtime area (events.jsonl, together/, heartbeat) — it is not
        // a baseline to copy from, and it is not locked read-only.
        let legacySkills = AIChatViewModel.minisSkillsPersistentDir
        let defaultSkills = skillsDir(for: defaultPersonaId)
        do {
            try fm.createDirectory(at: defaultSkills, withIntermediateDirectories: true)
            if let entries = try? fm.contentsOfDirectory(
                at: legacySkills, includingPropertiesForKeys: [.isDirectoryKey]
            ) {
                for src in entries {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else { continue }
                    let dst = defaultSkills.appendingPathComponent(src.lastPathComponent)
                    if !fm.fileExists(atPath: dst.path) {
                        try? fm.copyItem(at: src, to: dst)
                    }
                }
            }
        }

        // 2. Flat per-session dirs: <minis>/<sid>/ → <minis>/<pid>/<sid>/.
        //    A dir is treated as a flat session dir when ChatStore knows the
        //    session id; persona dirs themselves are session ids too, so the
        //    flag guard above is what prevents a second pass from re-moving.
        let base = AIChatViewModel.minisPersistentBase
        if let entries = try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for dir in entries {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let sid = dir.lastPathComponent
                let personaId = await ChatStore.shared.getPersonaId(sessionId: sid)
                // Unknown dir (not a session): leave it alone.
                guard await ChatStore.shared.getSession(sid) != nil else { continue }
                let target = sessionDir(for: sid, personaId: personaId)
                if !fm.fileExists(atPath: target.path) {
                    try? fm.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? fm.moveItem(at: dir, to: target)
                }
            }
        }

        defaults.set(true, forKey: migrationFlagKey)
    }
}
