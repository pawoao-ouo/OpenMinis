import Foundation

/// Multi-persona isolation: persona identity + per-persona directory layout.
///
/// A persona IS a session: `sessions.persona_id` holds the persona id.
/// A new session is its own persona (persona_id == session id) and starts
/// with empty memory/SOUL dirs — it inherits nothing from any other
/// persona. Rows predating the column read back "default" and share the
/// one-time migrated copy of the old shared data at memory/default/.
/// Fork/duplicate inherit the source session's persona id (same persona,
/// new conversation thread). There is no separate Persona type and no
/// persona picker UI — that is a product decision, not an omission here.
///
/// Layout (decisions.md §3):
///   memory/<personaId>/GLOBAL.md, memory/<personaId>/YYYY-MM-DD.md,
///   memory/<personaId>/SOUL.md
///   skills/<personaId>/, mcp-servers/<personaId>/ (global baseline read-only)
///   shared/<personaId>/ for writes (global shared/ read-only)
///   minisPersistentBase/<personaId>/<sessionId>/<host>/ for session buckets
///
/// The old flat locations (memory/GLOBAL.md, skills/, shared/,
/// mcp-servers/servers.json, minisPersistentBase/<sessionId>/) are kept
/// as a read-only legacy baseline and are NEVER written again after the
/// one-time migration. The original shared data is never deleted —
//  deletion is the user's call, not this code's.
enum PersonaStore {

    static let defaultPersonaId = "default"
    static let migrationFlagKey = "personaIsolation.migrationCompleted.v1"

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

    /// Per-persona memory root: <memory>/  <personaId>/
    static func memoryDir(for personaId: String) -> URL {
        AIChatViewModel.minisMemoryPersistentDir
            .appendingPathComponent(personaId, isDirectory: true)
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

    /// Per-persona skills root: <skills>/<personaId>/
    /// The flat skills/ dir stays as a read-only global baseline.
    static func skillsDir(for personaId: String) -> URL {
        AIChatViewModel.minisSkillsPersistentDir
            .appendingPathComponent(personaId, isDirectory: true)
    }

    /// Per-persona shared dir — writes land here. The flat shared/ dir is
    /// a read-only mount; nothing writes there anymore.
    static func sharedDir(for personaId: String) -> URL {
        AIChatViewModel.minisSharedPersistentDir
            .appendingPathComponent(personaId, isDirectory: true)
    }

    /// Per-persona MCP config root: <MinisConfig>/mcp-servers/<personaId>/
    /// The flat mcp-servers/servers.json stays as a read-only global baseline.
    static func mcpServersDir(for personaId: String) -> URL {
        AIChatViewModel.minisMcpServersPersistentDir
            .appendingPathComponent(personaId, isDirectory: true)
    }

    static func mcpServersFileURL(for personaId: String) -> URL {
        mcpServersDir(for: personaId).appendingPathComponent("servers.json")
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

    /// /var/minis/memory/<personaId> — the iSH-visible memory dir.
    static func memoryLinuxDir(for personaId: String) -> String {
        "\(AIChatViewModel.minisMemoryLinuxDir)/\(personaId)"
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

    /// Copies the old shared memory/SOUL files into memory/default/ and
    /// moves flat per-session dirs under their persona. Idempotent:
    /// guarded by a UserDefaults flag and by "target missing" checks, so a
    /// re-run is a no-op. Originals are NEVER deleted here — the flat
    /// memory/GLOBAL.md etc. stay on disk read-only, and whether to delete
    /// them after 30 days is the user's call.
    ///
    /// Must be called once at app launch (MinisApp), before any session
    /// loads: it needs ChatStore (actor) for session→persona lookups.
    static func migrateLegacyDataIfNeeded() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: migrationFlagKey) { return }
        let fm = FileManager.default
        let legacyMemory = AIChatViewModel.minisMemoryPersistentDir

        // 1. Memory + SOUL: copy flat files into memory/default/.
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
