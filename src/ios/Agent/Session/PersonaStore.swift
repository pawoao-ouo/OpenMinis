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
    /// v3: re-runs the migration on devices that ran v2, so the v2
    /// skills-step bug (bundled skills copied into skills/default/,
    /// shadowing bundled upgrades — DeepSeek item 9) gets cleaned up.
    /// Steps are idempotent (target-missing guards), so a re-run is safe.
    static let migrationFlagKey = "personaIsolation.migrationCompleted.v3"

    // MARK: - Identity

    /// In-memory persona cache, keyed by session id. Populated whenever a
    /// session is loaded or created (AIChatViewModel load/create path) and
    /// by warmCache() at launch (every DB session), so sync call sites
    /// (static resolveMinisURL, iSH routing) never need an actor hop into
    /// ChatStore. A cache miss returns NIL — never "default": resolving an
    /// unknown session to the default persona would serve the default
    /// persona's memory to a session that is not it (DeepSeek impl-review
    /// items 1–2). Callers must fail closed on nil (skip the persona dir)
    /// or resolve authoritatively via resolvePersonaId(forSessionId:).
    /// Session-bucket paths (a session's OWN workspace/offloads) are the
    /// only exception: they use personaIdForSessionDir, which mirrors the
    /// DB's own fallback (ChatStore.getPersonaId returns "default" for
    /// unknown/pre-migration rows), because a miss there can only strand
    /// that session's own files, never another persona's memory.
    private static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()
    /// Set once warmCache() has noted every DB session. Until then, a
    /// cache miss means "not loaded yet", not "default".
    private static var cacheWarm = false
    /// Persona of the session currently open in the UI, set by
    /// loadSession/createSession alongside the VM's own personaId.
    /// Nil when no session is active. This is the identity the
    /// Settings UI and minis-config edit (items 13/14).
    private static var _activePersonaId: String?

    static var activePersonaId: String? {
        get { cacheLock.lock(); defer { cacheLock.unlock() }; return _activePersonaId }
        set { cacheLock.lock(); defer { cacheLock.unlock() }; _activePersonaId = newValue }
    }

    static var isCacheWarm: Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cacheWarm
    }

    static func notePersonaId(_ personaId: String, forSessionId sid: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[sid] = personaId
    }

    /// Sync cache lookup. Returns nil on a miss — callers must fail
    /// closed (skip the persona dir) or use resolvePersonaId.
    static func cachedPersonaId(forSessionId sid: String?) -> String? {
        guard let sid else { return nil }
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[sid]
    }

    /// Back-compat name for the sync lookup (same nil-on-miss rule).
    static func personaId(forSessionId sid: String?) -> String? {
        cachedPersonaId(forSessionId: sid)
    }

    /// Session-bucket fallback: cache, else the DB's own "default" for
    /// unknown/pre-migration rows. Use ONLY for a session's own bucket
    /// dirs (workspace/offloads/attachments/browser) — never for memory,
    /// SOUL, logs, or shared.
    static func personaIdForSessionDir(forSessionId sid: String?) -> String {
        cachedPersonaId(forSessionId: sid) ?? defaultPersonaId
    }

    /// Authoritative resolution: cache, else the DB (which returns
    /// "default" for unknown/pre-migration rows — the DB's own answer,
    /// not a cache-miss guess), then note the cache.
    static func resolvePersonaId(forSessionId sid: String) async -> String {
        if let cached = cachedPersonaId(forSessionId: sid) { return cached }
        let pid = await ChatStore.shared.getPersonaId(sessionId: sid)
        notePersonaId(pid, forSessionId: sid)
        return pid
    }

    /// Note every DB session's persona into the cache. Run at launch
    /// (first step of migrateLegacyDataIfNeeded, before the flag check)
    /// so the cache is complete before any session loads or shell runs.
    static func warmCache() async {
        let sessions = await ChatStore.shared.listSessions()
        for session in sessions {
            notePersonaId(session.personaId, forSessionId: session.id)
        }
        cacheLock.lock(); defer { cacheLock.unlock() }
        cacheWarm = true
    }

    /// Active session's persona: the stored value set at load/create,
    /// else the cache lookup for the active session id. Nil when unknown.
    static func personaIdForActiveSession() -> String? {
        if let pid = activePersonaId { return pid }
        return cachedPersonaId(forSessionId: AIChatViewModel.activeSessionId)
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
        // A first component is a persona namespace when it is a known
        // persona id OR it looks like one (a session id is a UUID;
        // "default" and "me" are the two named ids). knownPersonaIds()
        // only covers personas this process has opened or that have a
        // memory dir, so it cannot be the test — a never-opened persona's
        // namespace must still be denied (DeepSeek item 5). Anything else
        // (together/, state/, a user-created subdir, a file) is shared
        // runtime area.
        if knownPersonaIds().contains(first) { return true }
        return isPersonaNamespaceComponent(first)
    }

    /// True when `component` looks like a persona namespace: "default",
    /// "me", or a UUID-shaped session id (personas ARE sessions — a new
    /// session's persona id IS its session id). Used by the
    /// cross-persona shared-write guard so an unknown persona's
    /// namespace is denied even when this process has never seen it.
    static func isPersonaNamespaceComponent(_ component: String) -> Bool {
        if component == defaultPersonaId || component == userProfilePersonaId { return true }
        // UUID: 8-4-4-4-12 hex, case-insensitive.
        guard component.count == 36 else { return false }
        let parts = component.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0].count == 8, parts[1].count == 4, parts[2].count == 4,
              parts[3].count == 4, parts[4].count == 12 else { return false }
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { hexDigits.contains($0) }
        }
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
        // Warm the persona cache first, on every launch — even when the
        // migration already ran — so sync resolvers never see a
        // "not loaded yet" cache (items 1–2). loadSession also awaits
        // this task, so the cache is complete before any prompt builds.
        await warmCache()
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: migrationFlagKey) { return }
        let fm = FileManager.default
        let legacyMemory = AIChatViewModel.minisMemoryPersistentDir
        // Item 7: the flag is set ONLY when every step below succeeded.
        // A failed step leaves the flag clear so the next launch retries
        // it instead of permanently abandoning the data. Steps are
        // idempotent (target-missing guards), so a retry is safe.
        var allStepsOK = true
        func fail(_ step: String, _ error: Error) {
            allStepsOK = false
            AppLogger(category: "PersonaMigration").error("[PersonaMigration] step \(step) FAILED: \(error.localizedDescription) — will retry on next launch")
        }

        // 1. Memory + SOUL: copy flat files into memory/personas/default/.
        //    SOUL.md at the root is copied only when personas/default/
        //    has none — a SOUL already in place is never overwritten.
        let defaultDir = memoryDir(for: defaultPersonaId)
        do {
            try fm.createDirectory(at: defaultDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: legacyMemory.path) {
                let entries = try fm.contentsOfDirectory(
                    at: legacyMemory, includingPropertiesForKeys: nil
                )
                for src in entries where src.pathExtension == "md" {
                    let dst = defaultDir.appendingPathComponent(src.lastPathComponent)
                    if !fm.fileExists(atPath: dst.path) {
                        do { try fm.copyItem(at: src, to: dst) } catch { fail("1-memory", error) }
                    }
                }
            }
        } catch { fail("1-memory", error) }

        // 1a. v1 layout: memory/<personaId>/*.md → memory/personas/<personaId>/.
        //     The "personas" container itself is skipped; every other direct
        //     subdir is a v1 persona dir. Target-missing guard: a file the
        //     runtime already placed in personas/<id>/ is never overwritten.
        if fm.fileExists(atPath: legacyMemory.path) {
            do {
                let entries = try fm.contentsOfDirectory(
                    at: legacyMemory, includingPropertiesForKeys: [.isDirectoryKey]
                )
                for dir in entries where dir.lastPathComponent != "personas" {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                    let personaId = dir.lastPathComponent
                    let dstDir = memoryDir(for: personaId)
                    do {
                        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
                        let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                        for src in files where src.pathExtension == "md" {
                            let dst = dstDir.appendingPathComponent(src.lastPathComponent)
                            if !fm.fileExists(atPath: dst.path) {
                                do { try fm.copyItem(at: src, to: dst) } catch { fail("1a-v1", error) }
                            }
                        }
                    } catch { fail("1a-v1", error) }
                }
            } catch { fail("1a-v1", error) }
        }

        // 1b. Skills: copy flat USER skill dirs into skills/default/ so
        // the default persona keeps them. Bundled skills are NEVER copied
        // (item 9): they live in the flat baseline and installBundledSkills
        // upgrades them there; a copy in skills/default/ would shadow the
        // upgrade forever (dirForSkill prefers the user dir when its
        // SKILL.md exists). Bundled ids come from the skills DB
        // (importSource == .bundled). A stale bundled copy left by the v2
        // migration is removed ONLY when it is byte-identical to the flat
        // baseline copy — a user edit (any difference) is kept.
        // MCP needs no copy: MCPStore falls back to the flat baseline.
        // Shared needs no copy: flat shared/ is the live read/write
        // runtime area (events.jsonl, together/, heartbeat) — it is not
        // a baseline to copy from, and it is not locked read-only.
        let legacySkills = AIChatViewModel.minisSkillsPersistentDir
        let defaultSkills = skillsDir(for: defaultPersonaId)
        let bundledIds: Set<String> = await MainActor.run {
            Set(SkillStore.shared.skills
                .filter { $0.importSource == .bundled }
                .map { $0.id })
        }
        do {
            try fm.createDirectory(at: defaultSkills, withIntermediateDirectories: true)
            if fm.fileExists(atPath: legacySkills.path) {
                let entries = try fm.contentsOfDirectory(
                    at: legacySkills, includingPropertiesForKeys: [.isDirectoryKey]
                )
                for src in entries {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else { continue }
                    let name = src.lastPathComponent
                    let dst = defaultSkills.appendingPathComponent(name)
                    if bundledIds.contains(name) {
                        if fm.fileExists(atPath: dst.path), dirsAreIdentical(src, dst) {
                            do { try fm.removeItem(at: dst) } catch { fail("1b-skills", error) }
                        }
                        continue
                    }
                    if !fm.fileExists(atPath: dst.path) {
                        do { try fm.copyItem(at: src, to: dst) } catch { fail("1b-skills", error) }
                    }
                }
            }
        } catch { fail("1b-skills", error) }

        // 2. Flat per-session dirs: <minis>/<sid>/ → <minis>/<pid>/<sid>/.
        //    A dir is treated as a flat session dir when ChatStore knows the
        //    session id; persona dirs themselves are session ids too, so the
        //    flag guard above is what prevents a second pass from re-moving.
        let base = AIChatViewModel.minisPersistentBase
        if fm.fileExists(atPath: base.path) {
            do {
                let entries = try fm.contentsOfDirectory(
                    at: base, includingPropertiesForKeys: [.isDirectoryKey]
                )
                for dir in entries {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                    let sid = dir.lastPathComponent
                    // Unknown dir (not a session): leave it alone.
                    guard await ChatStore.shared.getSession(sid) != nil else { continue }
                    let personaId = await ChatStore.shared.getPersonaId(sessionId: sid)
                    let target = sessionDir(for: sid, personaId: personaId)
                    if !fm.fileExists(atPath: target.path) {
                        do {
                            try fm.createDirectory(
                                at: target.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try fm.moveItem(at: dir, to: target)
                        } catch { fail("2-session-dirs", error) }
                    }
                }
            } catch { fail("2-session-dirs", error) }
        }

        // Item 7: only mark the migration done when every step succeeded.
        // A failure leaves the flag clear so the next launch retries.
        if allStepsOK {
            defaults.set(true, forKey: migrationFlagKey)
        }
    }

    /// Byte-identical directory comparison (recursive, name set + file
    /// bytes). Used by step 1b to tell the v2 migration's own stale
    /// bundled-skill copy apart from a user's edit of that skill.
    private static func dirsAreIdentical(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let aFiles = try? fm.contentsOfDirectory(atPath: a.path),
              let bFiles = try? fm.contentsOfDirectory(atPath: b.path),
              Set(aFiles) == Set(bFiles) else { return false }
        for name in aFiles {
            let aURL = a.appendingPathComponent(name)
            let bURL = b.appendingPathComponent(name)
            var aIsDir: ObjCBool = false, bIsDir: ObjCBool = false
            guard fm.fileExists(atPath: aURL.path, isDirectory: &aIsDir),
                  fm.fileExists(atPath: bURL.path, isDirectory: &bIsDir),
                  aIsDir.boolValue == bIsDir.boolValue else { return false }
            if aIsDir.boolValue {
                guard dirsAreIdentical(aURL, bURL) else { return false }
            } else {
                // An unreadable file is NOT identical — never remove a
                // copy we could not verify byte-for-byte.
                guard let aData = try? Data(contentsOf: aURL),
                      let bData = try? Data(contentsOf: bURL),
                      aData == bData else { return false }
            }
        }
        return true
    }
}
