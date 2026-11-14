import Foundation

private let logger = AppLogger(category: "Backup")

/// What was captured before a category was touched, so it can be undone.
///
/// §8.1 says the snapshot covers "only the categories that will be modified".
/// For file-tree categories that means copying the affected directories aside;
/// for DB-backed categories a full row-level snapshot would be prohibitive on a
/// 100k-message database, so those record no file snapshot and rely on
/// per-record LWW being idempotent (re-running a Merge import is a no-op).
struct BackupRollbackSnapshot {
    let category: BackupCategory
    /// live directory → saved copy
    var directories: [(live: URL, saved: URL)] = []
    /// live file → saved copy, for categories backed by a single file rather
    /// than a tree (provider-config.json).
    var files: [(live: URL, saved: URL)] = []

    /// True when nothing was captured, so a rollback would be a no-op and
    /// must not be reported as one having happened.
    var isEmpty: Bool { directories.isEmpty && files.isEmpty }
}

extension BackupImporter {

    // MARK: - File index

    func readFileIndex(at root: URL) -> [BackupFileIndexEntry] {
        let url = root.appendingPathComponent("files.index.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        var out: [BackupFileIndexEntry] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            // §2.2 rule 3: one bad line is skipped, never fatal.
            if let e = try? decoder.decode(BackupFileIndexEntry.self, from: Data(line)) {
                out.append(e)
            }
        }
        // A resumed export re-runs an interrupted category from scratch
        // while the index writer appends, so files indexed before the
        // interruption appear twice. Keep only the last row per
        // (category, path) — the re-run's row — so restore neither
        // writes nor counts the same file twice.
        var lastIndex: [String: Int] = [:]
        for (i, e) in out.enumerated() {
            lastIndex["\(e.category)\u{0}\(e.path)"] = i
        }
        return out.enumerated().filter { lastIndex["\($0.element.category)\u{0}\($0.element.path)"] == $0.offset }.map(\.element)
    }

    /// Fix 3 — the session ids this package carries, from
    /// `data/sessions*.jsonl` (shards included, via `readJSONL`).
    ///
    /// The preflight gate intersects these with the running sessions
    /// before any write. Sessions.jsonl is the right source here:
    /// one small record per session, unlike messages.jsonl, which can
    /// be hundreds of MB and must never be loaded just to list ids.
    /// Message / marker-only ids (a session row the package does not
    /// name) are still refused per-session inside `importChats`.
    func packageSessionIds(root: URL) -> Set<String> {
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        return Set(readJSONL(dataDir, base: "sessions",
                             as: SessionIDRecord.self).map(\.session.id))
    }

    // MARK: - Rollback

    func snapshotForRollback(category: BackupCategory, staging: URL) throws -> BackupRollbackSnapshot {
        var snap = BackupRollbackSnapshot(category: category)
        let fm = FileManager.default

        // Only directory-backed categories get a copy-aside. Chats is excluded
        // deliberately: snapshotting every session directory could mean copying
        // gigabytes to undo a merge that is itself idempotent.
        let liveDirs: [URL]
        switch category {
        case .sharedFiles: liveDirs = [AIChatViewModel.minisSharedPersistentDir]
        case .stickers: liveDirs = [AIChatViewModel.minisStickersPersistentDir]
        case .memory: liveDirs = [AIChatViewModel.minisMemoryPersistentDir]
        // [PIC-2] The appearance tree is directory-backed like shared
        // files, so it gets the same copy-aside rollback.
        case .appearance: liveDirs = [AppearanceStudio.appearanceAssetsDirectory]
        case .mcpServers: liveDirs = [MCPStore.syncFileURL.deletingLastPathComponent()]
        // iSH home directories: the rollback copy-aside covers them like
        // the other file trees. Missing when the rootfs is not installed,
        // in which case the import refuses below and there is nothing to
        // roll back.
        case .ishUserData: liveDirs = [RootfsManager.shared.dataPath.appendingPathComponent("root"),
                                       RootfsManager.shared.dataPath.appendingPathComponent("home")]
        // [review B3] Providers had NO rollback at all. It is a single JSON
        // file rather than a directory, so it is snapshotted via a dedicated
        // file-level entry instead of the directory copy-aside used above.
        case .providers: liveDirs = []
        // Environment variables merge into the live store rather than
        // replacing a file, so there is nothing to snapshot.
        // [AUD3-03] Scheduled tasks are the same shape: the import merges task
        // definitions into the live store (ids this device already has win)
        // rather than overwriting a file, so there is no directory tree to copy
        // aside. Unlike chats/memory there is no irreplaceable content here
        // either — a task is a definition the user can retype.
        case .chats, .skills, .voiceCorrections, .environmentVariables,
             .scheduledTasks:
            liveDirs = []
        }

        // File-backed categories: snapshot the single file.
        if category == .providers {
            let live = ProviderConfigStore.configFileURLForBackup
            if fm.fileExists(atPath: live.path) {
                let saved = staging.appendingPathComponent("providers-provider-config.json")
                try? fm.removeItem(at: saved)
                try fm.copyItem(at: live, to: saved)
                // [review I4] Record the live target in a sidecar. Directory
                // snapshots put a `.live-path` file INSIDE themselves, which a
                // plain file cannot do — so without this, reconcileAtLaunch
                // skipped the providers snapshot entirely and a crash mid
                // provider-restore left it unrecoverable.
                try? Data(live.path.utf8).write(
                    to: staging.appendingPathComponent(
                        "providers-provider-config.json"
                        + BackupRestoreJournal.fileSnapshotSidecarSuffix),
                    options: .atomic)
                snap.files.append((live: live, saved: saved))
            }
        }

        // [p1fix] personas.json 住在 MinisConfig，不在 memory 目录树里，
        // 上面的目录 copy-aside 覆盖不到。仿 providers 做文件级快照，
        // 否则恢复中途失败时注册表回滚不了。
        if category == .memory {
            let live = AIChatViewModel.minisConfigRoot.appendingPathComponent("personas.json")
            if fm.fileExists(atPath: live.path) {
                let saved = staging.appendingPathComponent("memory-personas.json")
                try? fm.removeItem(at: saved)
                try fm.copyItem(at: live, to: saved)
                try? Data(live.path.utf8).write(
                    to: staging.appendingPathComponent(
                        "memory-personas.json"
                        + BackupRestoreJournal.fileSnapshotSidecarSuffix),
                    options: .atomic)
                snap.files.append((live: live, saved: saved))
            }
        }

        for live in liveDirs where fm.fileExists(atPath: live.path) {
            let saved = staging.appendingPathComponent(
                "\(category.rawValue)-\(live.lastPathComponent)", isDirectory: true)
            try? fm.removeItem(at: saved)
            try fm.copyItem(at: live, to: saved)
            // Record where this came from, so a launch-time reconcile after a
            // crash can restore it without re-deriving the mapping.
            try? Data(live.path.utf8).write(
                to: saved.appendingPathComponent(".live-path"), options: .atomic)
            snap.directories.append((live: live, saved: saved))
        }
        return snap
    }

    func rollback(_ snapshot: BackupRollbackSnapshot) throws {
        let fm = FileManager.default
        for pair in snapshot.directories {
            try fm.createDirectory(at: pair.live.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // Atomic swap rather than remove-then-copy: the old pair left the
            // user's directory deleted and not yet replaced if the process died
            // between the two steps — for shared files that is the entire
            // directory.
            try BackupRestoreJournal.atomicReplace(directory: pair.saved, onto: pair.live)
        }
        for pair in snapshot.files {
            _ = try? FileManager.default.replaceItemAt(pair.live, withItemAt: pair.saved)
        }
        // A file-level provider rollback only rewrites the JSON on disk; the
        // in-memory store still holds the merged config, so it must be reloaded
        // or the UI would keep showing state that is no longer persisted.
        // [p1fix] personas.json 同理：回滚后重载 PersonaStore。
        if !snapshot.files.isEmpty {
            let rolledBackPersonas = snapshot.files.contains {
                $0.live.lastPathComponent == "personas.json"
            }
            Task { @MainActor in
                await ProviderConfigStore.shared.reloadFromDisk()
                if rolledBackPersonas { PersonaStore.shared.reloadFromDisk() }
            }
        }
        logger.info("[Restore] rolled back \(snapshot.category.rawValue) (\(snapshot.directories.count) dir(s))")
    }

    // MARK: - Dispatch

    func importCategory(_ category: BackupCategory,
                        root: URL,
                        fileIndex: [BackupFileIndexEntry],
                        snapshotAt: Date?,
                        options: Options) async throws -> CategoryReport {
        switch category {
        case .chats: return try await importChats(root: root, fileIndex: fileIndex, options: options)
        case .sharedFiles: return try importSharedFiles(root: root, fileIndex: fileIndex)
        case .stickers: return try importStickers(root: root, fileIndex: fileIndex)
        case .skills: return try await importSkills(root: root, fileIndex: fileIndex)
        case .memory:
            return try await importMemory(root: root, snapshotAt: snapshotAt, options: options)
        case .providers: return try await importProviders(root: root, options: options)
        case .mcpServers:
            return try await importMCPServers(root: root, options: options)
        case .voiceCorrections: return try await importVoiceCorrections(root: root)
        case .environmentVariables:
            return try await importEnvironmentVariables(root: root)
        case .appearance:
            return try await importAppearance(root: root, fileIndex: fileIndex, options: options)
        case .scheduledTasks: return try await importScheduledTasks(root: root)
        case .ishUserData: return try await importISHUserData(root: root, fileIndex: fileIndex)
        }
    }

    // MARK: - Scheduled tasks

    /// [AUD3-03] The scheduled-task definitions a package carries, back into
    /// the store the registry reads at launch — and armed immediately, so the
    /// tasks are visible without a relaunch.
    ///
    /// The file is one JSON array written by `exportScheduledTasks` with
    /// ISO-8601 dates (the package convention). `adoptRestoredScheduledTasks`
    /// takes it from there: it normalizes the other device's due times away,
    /// stores the snapshot under the registry's own key and re-runs the launch
    /// restore so the timers exist now.
    ///
    /// Merge by id, local version winning — which is what falls out of the
    /// mechanics rather than a rule this file implements: `restorePersistedJobs`
    /// skips ids the registry already holds, and its closing
    /// `persistScheduledJobs()` writes every live job back. So a task created on
    /// this device since the backup survives, and only ids this device does not
    /// currently have are taken from the package. (The one wrinkle: a task the
    /// user deleted here but that the package still carries does come back —
    /// that is the price of accepting the package as the source of truth for
    /// unknown ids.)
    private func importScheduledTasks(root: URL) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.scheduledTasks.rawValue)
        let url = root.appendingPathComponent("data/scheduled_tasks.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return report }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let jobs = try? decoder.decode([PersistedJob].self, from: data) else {
            report.unreadable += 1
            logger.warning("[Restore] scheduled_tasks.json (\(data.count) bytes) did not decode — no tasks restored")
            return report
        }
        let adopted = await MainActor.run {
            AgentJobRegistry.shared.adoptRestoredScheduledTasks(jobs)
        }
        report.imported += adopted
        return report
    }

    // MARK: - iSH user data

    /// Guest `/root` and `/home` back to the rootfs they came from.
    ///
    /// Refuses outright when the rootfs is not installed: restoring into
    /// a bare `Documents/alpine-rootfs/` would create `data/root` without
    /// the `.arch` tag, and the next `installIfNeeded` would treat the
    /// tree as a broken install and DELETE it — including the files just
    /// restored. Install the rootfs first (it installs at launch), then
    /// restore again.
    ///
    /// Restored files are registered in fakefs `meta.db` afterwards, or
    /// the running kernel cannot see them: the host copy alone is not
    /// enough (`RootfsManager.registerSubtreeInMetaDB` exists for
    /// exactly this).
    private func importISHUserData(root: URL, fileIndex: [BackupFileIndexEntry]) async throws
        -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.ishUserData.rawValue)
        guard RootfsManager.shared.isInstalled else {
            report.failed = "iSH is not installed on this device — install it first, then restore again to bring back /root and /home."
            return report
        }
        let dataPath = RootfsManager.shared.dataPath
        let files = try restoreFileTree(
            root: root, fileIndex: fileIndex, category: .ishUserData,
            destinationFor: { path in
                // "ish/root/<rel…>" → Documents/alpine-rootfs/data/root/<rel…>
                // "ish/home/<rel…>" → Documents/alpine-rootfs/data/home/<rel…>
                // Anything else is not an ish path and is never written.
                let parts = path.split(separator: "/", maxSplits: 2).map(String.init)
                guard parts.count >= 2, parts[0] == "ish",
                      parts[1] == "root" || parts[1] == "home" else { return nil }
                let tail = parts.count == 3 ? parts[2] : ""
                let base = dataPath.appendingPathComponent(parts[1], isDirectory: true)
                return tail.isEmpty ? base : base.appendingPathComponent(tail)
            })
        report.filesWritten = files.written
        report.bytesWritten = files.bytes
        report.missingBlobs = files.missingBlobs
        // The kernel reads through meta.db, not the host directory: without
        // this the restored files exist on disk but are invisible in-guest.
        for name in ["root", "home"] {
            RootfsManager.shared.registerSubtreeInMetaDB(
                hostRoot: dataPath.appendingPathComponent(name))
        }
        return report
    }

    // MARK: - Chats

    private func importChats(root: URL, fileIndex: [BackupFileIndexEntry],
                             options: Options) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.chats.rawValue)
        let store = ChatStore.shared
        let dataDir = root.appendingPathComponent("data", isDirectory: true)

        // Folders first: sessions carry a folderId, and applying the folder
        // beforehand means the reference resolves immediately.
        for env in readJSONL(dataDir, base: "folders", as: ChatFolder.self) {
            await store.applyRemoteFolder(env)
        }

        // Sessions before messages — restoreMessage requires the parent row.
        var runningSessionIds: Set<String> = []
        var packageSessionIds: Set<String> = []
        // Fix 2 — in overwrite mode the package's copy stands even when the
        // local copy is newer (the wipe already deleted every session the
        // package does not carry).
        let overwrite = options.mode == .overwrite
        struct SessionRecord: Codable {
            let session: ChatSession
            let memoryEnabled: Bool
            let modelBinding: String?
        }
        for rec in readJSONL(dataDir, base: "sessions", as: SessionRecord.self) {
            let sid = rec.session.id
            packageSessionIds.insert(sid)
            // Refuse rather than silently skip: a running agent loop owns its
            // message list, and writing under it would scramble sort_order.
            // The id is remembered so the message / marker / file-tree passes
            // below refuse to write into the same session — guarding only the
            // session row would still let its contents be overwritten, and
            // the report would count the session skipped but its messages
            // imported.
            if await store.isSessionRunning(sid) {
                runningSessionIds.insert(sid)
                report.skipped += 1
                continue
            }
            let outcome = await store.restoreSession(rec.session,
                                                     memoryEnabled: rec.memoryEnabled,
                                                     modelBinding: rec.modelBinding,
                                                     overwrite: overwrite)
            switch outcome {
            case .inserted: report.imported += 1
            case .updated: report.updated += 1
            case .skippedLocalNewer: report.skipped += 1
            case .skippedNoParent: report.skipped += 1
            }
        }

        let messageRecords = readJSONL(dataDir, base: "messages", as: RawMessage.self)
        let markerRecords = readJSONL(dataDir, base: "compact_markers", as: CompactMarker.self)
        // A session can also be running locally without its row being in
        // this package (its messages/markers still resolve to the local
        // parent row). Extend the same refusal to those ids before any
        // content pass writes into them.
        let contentOnlyIds = Set(messageRecords.map(\.sessionId))
            .union(markerRecords.map(\.sessionId))
            .subtracting(packageSessionIds)
            .subtracting(runningSessionIds)
        for sid in contentOnlyIds {
            if await store.isSessionRunning(sid) {
                runningSessionIds.insert(sid)
            }
        }

        for msg in messageRecords {
            if runningSessionIds.contains(msg.sessionId) {
                report.skipped += 1
                continue
            }
            guard let partsJson = encodeParts(msg.parts) else {
                report.unreadable += 1
                continue
            }
            let outcome = await store.restoreMessage(
                id: msg.id, sessionId: msg.sessionId, role: msg.role.rawValue,
                partsJson: partsJson, createdAt: msg.createdAt,
                tokenUsageJson: encodeTokenUsage(msg.tokenUsage), sortOrder: msg.sortOrder,
                reasoningContent: msg.reasoningContent,
                streamInterruptCount: msg.streamInterruptCount,
                updatedAt: msg.createdAt,
                // [T-token-attribution-snapshot] RawMessage decodes these
                // straight from the package; nil for older packages.
                modelId: msg.modelId, modelDisplayName: msg.modelDisplayName,
                providerType: msg.providerType,
                providerInstanceId: msg.providerInstanceId,
                errorInfo: msg.errorInfo,
                overwrite: overwrite)
            switch outcome {
            case .inserted: report.imported += 1
            case .updated: report.updated += 1
            case .skippedLocalNewer, .skippedNoParent: report.skipped += 1
            }
        }

        for marker in markerRecords {
            if runningSessionIds.contains(marker.sessionId) {
                report.skipped += 1
                continue
            }
            switch await store.restoreCompactMarker(marker) {
            case .inserted: report.imported += 1
            case .updated: report.updated += 1
            case .skippedLocalNewer, .skippedNoParent: report.skipped += 1
            }
        }

        // Session file trees: rebuild <sid>/ wholesale (§8.3).
        let files = try restoreFileTree(
            root: root, fileIndex: fileIndex, category: .chats,
            destinationFor: { path in
                // "chats/<sid>/<rel…>" → Library/MinisChat/minis/<sid>/<rel…>
                // Running sessions are refused here too (nil = do not write),
                // same as the row/message/marker passes above.
                let parts = path.split(separator: "/", maxSplits: 2).map(String.init)
                guard parts.count >= 3, parts[0] == "chats",
                      !runningSessionIds.contains(parts[1]) else { return nil }
                return AIChatViewModel.minisPersistentBase
                    .appendingPathComponent(parts[1], isDirectory: true)
                    .appendingPathComponent(parts[2])
            })
        report.filesWritten = files.written
        report.bytesWritten = files.bytes
        report.missingBlobs = files.missingBlobs

        return report
    }

    // MARK: - Shared files

    private func importSharedFiles(root: URL, fileIndex: [BackupFileIndexEntry]) throws
        -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.sharedFiles.rawValue)
        let base = AIChatViewModel.minisSharedPersistentDir
        let files = try restoreFileTree(
            root: root, fileIndex: fileIndex, category: .sharedFiles,
            destinationFor: { path in
                guard path.hasPrefix("shared/") else { return nil }
                return base.appendingPathComponent(String(path.dropFirst("shared/".count)))
            })
        report.filesWritten = files.written
        report.bytesWritten = files.bytes
        report.missingBlobs = files.missingBlobs
        // Per §3.2 no meta.db write is needed: every mount re-walks this
        // directory and re-registers rows, so the guest sees the files after the
        // next boot.
        return report
    }

    // MARK: - Stickers

    private func importStickers(root: URL, fileIndex: [BackupFileIndexEntry]) throws
        -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.stickers.rawValue)
        let base = AIChatViewModel.minisStickersPersistentDir
        let files = try restoreFileTree(
            root: root, fileIndex: fileIndex, category: .stickers,
            destinationFor: { path in
                guard path.hasPrefix("stickers/") else { return nil }
                return base.appendingPathComponent(String(path.dropFirst("stickers/".count)))
            })
        report.filesWritten = files.written
        report.bytesWritten = files.bytes
        report.missingBlobs = files.missingBlobs
        Task { @MainActor in
            // 通知表情包数据已恢复，重新从磁盘载入
            StickerStore.shared.reloadFromDisk()
        }
        return report
    }

    // MARK: - Appearance

    /// [PIC-2] The AppearanceStudio tree back to its original location
    /// (same merge semantics as Shared Files: package files overwrite,
    /// files the package doesn't mention are left alone), plus the
    /// UserDefaults half from `data/appearance_settings.json`.
    /// `applyBackupDefaults` whitelists the keys it writes and reloads
    /// the live AppearanceStudio, so the restored look applies without
    /// a relaunch.
    private func importAppearance(root: URL, fileIndex: [BackupFileIndexEntry],
                                  options: Options) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.appearance.rawValue)
        let base = AppearanceStudio.appearanceAssetsDirectory
        let files = try restoreFileTree(
            root: root, fileIndex: fileIndex, category: .appearance,
            destinationFor: { path in
                guard path.hasPrefix("appearance/") else { return nil }
                return base.appendingPathComponent(String(path.dropFirst("appearance/".count)))
            })
        // [A2] Avatar PNGs are carried by this category under an `avatars/`
        // prefix but live in `Application Support/avatars/`, BESIDE
        // AppearanceStudio rather than inside it — so they get their own
        // restore pass, checked against the avatars root's containment rather
        // than AppearanceStudio's.
        let avatarDir = SoulIconImage.avatarsDirectory()
        let avatars = try restoreFileTree(
            root: root, fileIndex: fileIndex, category: .appearance,
            containmentRootOverride: avatarDir,
            destinationFor: { path in
                guard path.hasPrefix("avatars/") else { return nil }
                return avatarDir.appendingPathComponent(String(path.dropFirst("avatars/".count)))
            })
        report.filesWritten = files.written + avatars.written
        report.bytesWritten = files.bytes + avatars.bytes
        report.missingBlobs = files.missingBlobs + avatars.missingBlobs

        let settingsURL = root.appendingPathComponent("data/appearance_settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let values = try? JSONDecoder().decode([String: BackupDefaultsValue].self, from: data) {
            await MainActor.run {
                AppearanceStudio.shared.applyBackupDefaults(values)
                // [batch7 用户-P2-11] 清除标记与文件 merge 语义对齐：以清除
                // 标记为准——包里没带某页壁纸文件、但标记说该页已清除时，
                // 本机残留的该页壁纸文件删掉，不让标记变死标记。
                //
                // [A6] But this DELETES local wallpaper files, so it belongs to
                // OVERWRITE only. In merge mode the promise is "nothing is
                // deleted": a local wallpaper the package does not carry stays
                // put instead of being reconciled away by the package's markers.
                if options.mode == .overwrite {
                    AppearanceStudio.shared.reconcileClearedWallpapersAfterRestore(
                        packagedScopes: Self.packagedWallpaperScopes(in: fileIndex))
                }
            }
            report.imported += 1
        }
        // [P3-16] Reconcile the theme library with its list: the file tree
        // above merges, but the list was just replaced by the backup's, so
        // pack files with no list entry are orphans (invisible in the UI,
        // undeletable) — remove them. Runs even when the package carried
        // no settings: then the local list stands, and only pre-existing
        // local orphans go.
        //
        // [A6] OVERWRITE only: removing orphaned packs deletes files the
        // package does not carry, which merge must never do.
        if options.mode == .overwrite {
            let orphansRemoved = await MainActor.run {
                AppearanceStudio.shared.removeOrphanedLibraryPacks()
            }
            if orphansRemoved > 0 {
                logger.info("[Restore] appearance: removed \(orphansRemoved) orphaned theme pack(s) with no library entry")
            }
        }
        return report
    }

    /// 包里实际带了壁纸文件的 scope（文件名 appearance/wallpaper-<scope>.jpg）。
    private static func packagedWallpaperScopes(in fileIndex: [BackupFileIndexEntry])
        -> Set<AppearanceScope> {
        var out = Set<AppearanceScope>()
        for entry in fileIndex {
            guard entry.category == BackupCategory.appearance.rawValue,
                  entry.skipped == nil,
                  entry.path.hasPrefix("appearance/wallpaper-"),
                  entry.path.hasSuffix(".jpg") else { continue }
            let raw = entry.path
                .dropFirst("appearance/wallpaper-".count)
                .dropLast(".jpg".count)
            if let scope = AppearanceScope(rawValue: String(raw)) {
                out.insert(scope)
            }
        }
        return out
    }

    // MARK: - Skills

    private func importSkills(root: URL, fileIndex: [BackupFileIndexEntry]) async throws
        -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.skills.rawValue)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)

        struct SkillRecord: Codable {
            let id: String, name: String, description: String, version: String
            let isEnabled: Bool, installedAt: Date, updatedAt: Date, body: String
            let sourceURL: String?
        }
        var lwwSkippedIds: Set<String> = []
        for rec in readJSONL(dataDir, base: "skills", as: SkillRecord.self) {
            // importSkillRecord preserves the id and applies its own LWW,
            // which is exactly Merge semantics; the rescan below stages
            // the changes instead.
            let applied = await MainActor.run {
                SkillStore.shared.importSkillRecord(
                    skillId: rec.id, content: rec.body,
                    source: rec.sourceURL.map { .url($0) } ?? .file,
                    isEnabled: rec.isEnabled, installedAt: rec.installedAt,
                    updatedAt: rec.updatedAt, version: rec.version,
                    name: rec.name, description: rec.description)
            }
            if applied { report.imported += 1 } else {
                report.skipped += 1
                lwwSkippedIds.insert(rec.id)
            }
        }

        let files = try restoreFileTree(
            root: root, fileIndex: fileIndex, category: .skills,
            destinationFor: { path in
                let parts = path.split(separator: "/", maxSplits: 2).map(String.init)
                guard parts.count >= 3, parts[0] == "skills" else { return nil }
                // A false from importSkillRecord means the LOCAL skill is
                // newer than the package's record — its contract says the
                // caller MUST then stop file processing for that skill.
                // Restoring its files anyway would silently roll the skill
                // (SKILL.md and sidecars alike) back to the older backup.
                guard !lwwSkippedIds.contains(parts[1]) else { return nil }
                return AIChatViewModel.minisSkillsPersistentDir
                    .appendingPathComponent(parts[1], isDirectory: true)
                    .appendingPathComponent(parts[2])
            })
        report.filesWritten = files.written
        report.bytesWritten = files.bytes
        report.missingBlobs = files.missingBlobs
        return report
    }

    // MARK: - Memory & Soul

    private func importMemory(root: URL, snapshotAt: Date?,
                              options: Options) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.memory.rawValue)
        let fm = FileManager.default
        let src = root.appendingPathComponent("data/memory", isDirectory: true)
        guard fm.fileExists(atPath: src.path) else { return report }
        let dst = AIChatViewModel.minisMemoryPersistentDir
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where name.hasSuffix(".md") {
            let from = src.appendingPathComponent(name)
            let to = dst.appendingPathComponent(name)

            // Identical content is a skip, not an import.
            //
            // mtime cannot decide this: ZIP timestamps have 2-second
            // resolution and extraction does not preserve the original mtime
            // at all, so the package copy's date is meaningless. Restoring a
            // package onto the device that produced it was reporting all five
            // memory files as freshly "imported" — a report the user would
            // read as "5 files changed" when nothing did. These files are
            // small (a few KB), so hashing them is cheap and exact.
            if let localData = try? Data(contentsOf: to),
               let pkgData = try? Data(contentsOf: from),
               localData == pkgData {
                report.skipped += 1
                continue
            }
            // [A6] Merge must not let an OLDER package overwrite newer local
            // memory. A local file modified after the backup's cut-off is
            // newer than anything the package can hold, so keep it; overwrite
            // mode deliberately replaces regardless (its wipe already treats
            // the package as the source of truth).
            if options.mode == .merge, localIsNewerThanBackup(to, snapshotAt: snapshotAt) {
                report.skipped += 1
                continue
            }
            // Stage next to the destination and swap, rather than
            // removeItem-then-copyItem (the pattern restoreFileTree's
            // comment documents): deleting first meant a failed copy —
            // disk full, IO error — left the user's file simply GONE.
            // A failure here now throws, so the category fails and the
            // rollback snapshot taken for .memory is actually used;
            // counting it as "unreadable" and carrying on bypassed both
            // protections.
            let staged = dst.appendingPathComponent(".restore-\(UUID().uuidString).tmp")
            do {
                try fm.copyItem(at: from, to: staged)
                if fm.fileExists(atPath: to.path) {
                    _ = try fm.replaceItemAt(to, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: to)
                }
                report.imported += 1
            } catch {
                try? fm.removeItem(at: staged)
                throw error
            }
        }

        // P1-2：人设记忆目录 data/memory/personas/<id>/*.md 原样写回。
        // 旧包没有它时照常跳过；单文件走与顶层同样的 hash 比对 + staged swap。
        var registryRestored = false
        // [10-19 醒醒] 全局正则文件是否被换过，决定要不要刷内存。
        var regexRestored = false
        let personasSrc = src.appendingPathComponent("personas", isDirectory: true)
        if fm.fileExists(atPath: personasSrc.path) {
            let personasDst = dst.appendingPathComponent("personas", isDirectory: true)
            try fm.createDirectory(at: personasDst, withIntermediateDirectories: true)
            if let enumerator = fm.enumerator(at: personasSrc, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    guard fileURL.pathExtension == "md",
                          (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                    else { continue }
                    let rel = String(fileURL.path.dropFirst(personasSrc.path.count + 1))
                    let to = personasDst.appendingPathComponent(rel)
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let localData = try? Data(contentsOf: to),
                       let pkgData = try? Data(contentsOf: fileURL),
                       localData == pkgData {
                        report.skipped += 1
                        continue
                    }
                    // [A6] Same merge guard as the top-level files.
                    if options.mode == .merge, localIsNewerThanBackup(to, snapshotAt: snapshotAt) {
                        report.skipped += 1
                        continue
                    }
                    let staged = dst.appendingPathComponent(".restore-\(UUID().uuidString).tmp")
                    do {
                        try fm.copyItem(at: fileURL, to: staged)
                        if fm.fileExists(atPath: to.path) {
                            _ = try fm.replaceItemAt(to, withItemAt: staged)
                        } else {
                            try fm.moveItem(at: staged, to: to)
                        }
                        report.imported += 1
                    } catch {
                        try? fm.removeItem(at: staged)
                        throw error
                    }
                }
            }
        }

        // P1-2：人设注册表 data/memory/personas.json → MinisConfig/personas.json。
        // 旧包没有它时照常跳过。
        let registrySrc = src.appendingPathComponent("personas.json")
        if fm.fileExists(atPath: registrySrc.path) {
            let registryDst = AIChatViewModel.minisConfigRoot.appendingPathComponent("personas.json")
            try fm.createDirectory(at: registryDst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let localData = try? Data(contentsOf: registryDst),
               let pkgData = try? Data(contentsOf: registrySrc),
               localData == pkgData {
                report.skipped += 1
            } else if options.mode == .merge,
                      localIsNewerThanBackup(registryDst, snapshotAt: snapshotAt) {
                // [A6] An older package must not roll back a newer local
                // persona registry in merge mode.
                report.skipped += 1
            } else {
                let staged = registryDst.deletingLastPathComponent()
                    .appendingPathComponent(".restore-\(UUID().uuidString).tmp")
                do {
                    try fm.copyItem(at: registrySrc, to: staged)
                    if fm.fileExists(atPath: registryDst.path) {
                        _ = try fm.replaceItemAt(registryDst, withItemAt: staged)
                    } else {
                        try fm.moveItem(at: staged, to: registryDst)
                    }
                    report.imported += 1
                    registryRestored = true
                } catch {
                    try? fm.removeItem(at: staged)
                    throw error
                }
            }
        }

        // [10-19 醒醒] 全局正则规则一起恢复。
        let regexSrc = src.appendingPathComponent("regex-rules.json")
        if fm.fileExists(atPath: regexSrc.path) {
            let regexDst = AIChatViewModel.minisConfigRoot.appendingPathComponent("regex-rules.json")
            try fm.createDirectory(at: regexDst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let localData = try? Data(contentsOf: regexDst),
               let pkgData = try? Data(contentsOf: regexSrc),
               localData == pkgData {
                report.skipped += 1
            } else if options.mode == .merge,
                      localIsNewerThanBackup(regexDst, snapshotAt: snapshotAt) {
                // [A6] Same guard for the global regex rules.
                report.skipped += 1
            } else {
                let staged = regexDst.deletingLastPathComponent()
                    .appendingPathComponent(".restore-\(UUID().uuidString).tmp")
                do {
                    try fm.copyItem(at: regexSrc, to: staged)
                    if fm.fileExists(atPath: regexDst.path) {
                        _ = try fm.replaceItemAt(regexDst, withItemAt: staged)
                    } else {
                        try fm.moveItem(at: staged, to: regexDst)
                    }
                    report.imported += 1
                    regexRestored = true
                } catch {
                    try? fm.removeItem(at: staged)
                    throw error
                }
            }
        }

        // SOUL.md is cached in memory; a raw file write leaves that cache stale
        // until something else refreshes it.
        await MainActor.run { SoulStore.refreshCache() }
        // 注册表落盘后内存里的 PersonaStore 还是旧表，重载一次，
        // 否则恢复完人设列表不变——看起来像"恢复后人设全丢"没修好。
        if registryRestored {
            await MainActor.run { PersonaStore.shared.reloadFromDisk() }
        }
        // 正则同理：文件换了，内存里的规则还是旧的。
        if regexRestored {
            await MainActor.run { GlobalRegexStore.shared.reloadFromDisk() }
        }
        return report
    }

    /// [A6] Merge-only "is the LOCAL file newer than this backup?" test.
    ///
    /// The package's own files lose their mtime in the ZIP round-trip (the
    /// writer stamps 0 and the extractor does not restore it), so the only
    /// trustworthy backup instant is the manifest's snapshot cut-off. A local
    /// file modified strictly after that instant is newer than anything the
    /// package can hold, so merge keeps it; a file modified at or before it
    /// is not newer, so the package's copy wins. Nil snapshot = no recorded
    /// cut-off = cannot prove the local copy is newer.
    private func localIsNewerThanBackup(_ url: URL, snapshotAt: Date?) -> Bool {
        guard let snapshotAt else { return false }
        guard let mtime = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
        return mtime > snapshotAt
    }

    // MARK: - Providers

    private func importProviders(root: URL, options: Options) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.providers.rawValue)
        let url = root.appendingPathComponent("data/provider_config.json")
        guard let data = try? Data(contentsOf: url) else { return report }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let config = try? decoder.decode(ProviderConfig.self, from: data) else {
            report.unreadable += 1
            return report
        }
        // [T-ios-backup-provider-merge] MUST NOT be applyConfig: that replaces
        // the entire config, so any provider / model group / session binding
        // that exists locally but not in the backup was silently deleted —
        // while the restore confirmation promised "Nothing is deleted".
        // mergeProviderConfigForRestore (below) is the union-by-id merger,
        // which keeps local-only items and leaves the per-device pointer
        // fields (voice/vision groups, session bindings, defaults) untouched.
        // Restoring must never fall back to the destructive whole-config
        // replace.
        // Fix 2 — overwrite: the wipe step already replaced the whole config
        // with the package's via `applyConfig` (local per-device pointers
        // preserved, no "(from backup)" suffix — there is nothing left to
        // collide with, because the local groups are gone) and cleared the
        // local thinking rules, so the rule upserts below land on an empty
        // set. No merge runs here at all: merging would resurrect the very
        // providers the wipe just removed.
        //
        // Merge keeps the existing path below: union-by-id, the package wins
        // for same-id items, and the per-device pointers are never touched.
        if options.mode == .overwrite {
            // Every instance in the package is now live (the config was
            // replaced wholesale); nothing was "skipped" — a package instance
            // cannot be skipped when the local side was wiped first.
            report.imported = config.instances.count
            report.skipped = 0
        } else {
            // Disambiguate model groups whose NAME collides with one already on
            // this device. The merge is by id, so a restored group is correctly a
            // separate entity — but on screen the user then sees two rows both
            // called "Default Models" with no way to tell which is which. Seen for
            // real: a restore produced three duplicate pairs in the model picker.
            //
            // Only collisions are touched. A group whose name is unique keeps it
            // exactly, so the common case (restoring onto a clean device) reads
            // the same as the source.
            let merged = await MainActor.run { Self.disambiguateGroupNames(config) }

            let before = await MainActor.run { ProviderConfigStore.shared.config.instances.count }
            await Self.mergeProviderConfigForRestore(merged)
            let after = await MainActor.run { ProviderConfigStore.shared.config.instances.count }

            // Report what the merge actually did, not the package's instance count:
            // an instance already present locally is not a new arrival.
            //
            // [T-backup-provider-false-updated] `updated` used to be
            // `config.instances.count - imported`, i.e. "every instance in the
            // package that wasn't newly inserted" — with no content comparison at
            // all. The merge above is union-by-id and only grows the list for
            // genuinely new ids, so an instance already present locally is not
            // a new arrival even when the merge refreshed its content from the
            // package. Restoring a package onto the device that produced it
            // therefore reported "Updated 9" while adding nothing, which is
            // the reported symptom. Count them as `skipped`, which is what
            // actually happened and what every other category (chats via LWW,
            // memory via content hash) already reports for an unchanged item.
            report.imported = max(0, after - before)
            report.skipped = max(0, config.instances.count - report.imported)
        }

        // [T-backup-thinking-rules] AFTER the instance merge, never before: a
        // rule's `instance_id` points at a ProviderInstance, so importing rules
        // first would attach them to instances that do not exist yet and they
        // would resolve to nothing, silently.
        //
        // Absent in packages written by older builds — that is not an error,
        // the file simply isn't there and `readJSONL` returns [].
        let rules = readJSONL(root.appendingPathComponent("data", isDirectory: true),
                              base: "thinking_rules", as: BackupThinkingRuleRecord.self)
        if !rules.isEmpty {
            let outcome = await Self.importThinkingRules(rules)
            report.imported += outcome.written
            report.skipped += outcome.skipped
        }

        // §3.3: credentials belong to this category and restore with it.
        // Absent for a "share copy" package, which is why nil is not an error.
        if let creds = await MainActor.run(body: { BackupSecretsImporter.restore(from: root) }) {
            // All three credential kinds count as restored: env vars and
            // MCP OAuth written back here were previously dropped from the
            // report, which under-counted "API keys restored" and could
            // drop the restore footer into its "created without API keys"
            // branch even though credentials had just been written.
            report.credentialsRestored = creds.total
            report.credentialsKept = creds.providersSkippedExisting
                + creds.envVarsSkippedExisting + creds.mcpOAuthSkippedExisting
            report.credentialsUndecodable = creds.credentialsUndecodable
                + creds.mcpOAuthUndecodable
        }
        return report
    }

    /// [T-backup-thinking-rules] Merge restored thinking rules into the
    /// provider DB.
    ///
    /// Deliberately delegates to `upsertThinkingRuleFromInbound`, the same call
    /// inbound merges use, rather than writing a second merge:
    ///   * conflict is resolved by id (`ON CONFLICT(id) DO UPDATE`);
    ///   * a LOCAL row with an equal-or-newer `updated_at` wins, so restoring
    ///     an older package cannot roll back a rule edited since;
    ///   * it hard-codes `is_builtin = 0`, so nothing arriving from a package
    ///     can ever masquerade as a built-in rule.
    ///
    /// Returns (written, skipped) so the caller reports what actually changed
    /// rather than counting every record in the file as an import — the same
    /// distinction [T-backup-provider-false-updated] restored for instances.
    @MainActor
    private static func importThinkingRules(
        _ rules: [BackupThinkingRuleRecord]
    ) async -> (written: Int, skipped: Int) {
        guard let db = ProviderConfigStore.shared.db else { return (0, 0) }
        var written = 0
        var skipped = 0
        for r in rules {
            let applied = await db.upsertThinkingRuleFromInbound(
                id: r.id,
                instanceId: r.instanceId,
                sortOrder: r.sortOrder,
                scopeKind: r.scopeKind,
                scopePattern: r.scopePattern,
                wireFormatJson: r.wireFormatJson,
                echoField: r.echoField,
                echoTiming: r.echoTiming,
                label: r.label,
                createdAt: r.createdAt.timeIntervalSince1970,
                updatedAt: r.updatedAt.timeIntervalSince1970
            )
            if applied { written += 1 } else { skipped += 1 }
        }
        // The resolver reads rules through a process-wide cache, so a restore
        // that only touched SQLite would not affect the next request until the
        // app restarted.
        await ProviderConfigStore.shared.reloadThinkingRuleCache()
        logger.info("[Restore] thinking rules: \(written) applied, \(skipped) skipped (local newer or unchanged)")
        return (written, skipped)
    }

    /// Suffix restored model groups whose name is already taken locally.
    ///
    /// Returns the config unchanged when there is no collision — the suffix is
    /// a disambiguator, not a label for "this came from a backup", so a group
    /// that lands on a device without a same-named one keeps its original
    /// name. A group already present BY ID is skipped too: that is the same
    /// group coming home, not a duplicate.
    @MainActor
    static func disambiguateGroupNames(_ remote: ProviderConfig) -> ProviderConfig {
        let local = ProviderConfigStore.shared.config
        let localIds = Set(local.modelGroups.map(\.id))
        var takenNames = Set(local.modelGroups.map(\.name))
        guard !takenNames.isEmpty else { return remote }

        var copy = remote
        var renamed = 0
        for i in copy.modelGroups.indices {
            let group = copy.modelGroups[i]
            // Same id => the very same group, which merge will skip entirely.
            guard !localIds.contains(group.id) else { continue }
            guard takenNames.contains(group.name) else {
                takenNames.insert(group.name)
                continue
            }
            let base = AppLocalized("\(group.name) (from backup)")
            var candidate = base
            var n = 2
            while takenNames.contains(candidate) {
                candidate = "\(base) \(n)"
                n += 1
            }
            copy.modelGroups[i].name = candidate
            takenNames.insert(candidate)
            renamed += 1
        }
        if renamed > 0 {
            logger.info("[Restore] renamed \(renamed) model group(s) whose names collided with local ones")
        }
        return copy
    }

    /// Restore-only provider merge, relocated from the deleted sync engine
    /// (restore variant of its provider-config merge). Union-by-id: the
    /// package wins for same-id items, local-only items are kept, tombstones
    /// suppress resurrections, and the package's order leads. Per-device
    /// pointers (defaults, voice/vision groups, session bindings) are never
    /// touched — the merge starts from the local config.
    @MainActor
    static func mergeProviderConfigForRestore(_ remote: ProviderConfig) async {
        // Read the authoritative current state from the store's in-memory config,
        // NOT from disk. Reading from disk would lose any changes still in-flight
        // between a UI edit and the debounced disk write (tiny but real window),
        // and would silently overwrite per-device-only fields (sessionBindings,
        // sessionInferenceConfigs, default pointers) if the disk was stale.
        let store = ProviderConfigStore.shared
        var local = store.config

        let localInstanceIds = Set(local.instances.map { $0.id })
        let localGroupIds = Set(local.modelGroups.map { $0.id })

        // Merge strategy: the package wins for same-ID items (propagates edits,
        // renames, member changes). Local-only items (not in the package) are kept.
        //
        // Tombstones drive deletion semantics. Union by id of local + remote
        // tombstones survives the merge (so the next device that sees this
        // record also sees the delete intent). An item whose id is in the
        // tombstone union with `deletedAt > the would-be-resurrected entry's
        // updatedAt-ish stamp` is suppressed. ProviderInstance has no per-row
        // updatedAt, so we apply tombstones unconditionally to instances —
        // a same-id "re-add" would have to happen on the device that holds
        // the tombstone (where removeInstance has already wiped it).
        let mergedInstanceTombstones = mergeTombstones(local.deletedInstances, remote.deletedInstances)
        let mergedEntryTombstones    = mergeTombstones(local.deletedModelEntries, remote.deletedModelEntries)
        let mergedGroupTombstones    = mergeTombstones(local.deletedModelGroups, remote.deletedModelGroups)
        let tombstonedInstanceIds = Set(mergedInstanceTombstones.map(\.id))
        let tombstonedEntryIds    = Set(mergedEntryTombstones.map(\.id))
        let tombstonedGroupIds    = Set(mergedGroupTombstones.map(\.id))

        // 1. Merge instances — remote wins for same-id, keep local-only,
        //    suppress anything in the tombstone union.
        var instanceMap = Dictionary(local.instances.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for ri in remote.instances where !tombstonedInstanceIds.contains(ri.id) {
            instanceMap[ri.id] = ri  // remote wins for existing; adds new
        }
        for tid in tombstonedInstanceIds {
            instanceMap.removeValue(forKey: tid)
        }
        // [T-backup-restore-order] Ordering is USER DATA here: the provider
        // list is drag-reorderable, and `config.instances`'s array order is
        // what carries it (ProviderConfigDB writes the array index into
        // `sort_order` and reads back `ORDER BY sort_order`).
        //
        // The package records the order the user arranged, and rebuilding by
        // creation date discards it, which is the reported "恢复会把服务商、分组的排序全部打乱".
        //
        // On restore: take the backup's order first, then append local-only
        // instances (which the backup could not know about) after it, keeping
        // their relative order. That makes the restored device match the
        // backup for everything the backup contained, and leaves anything
        // added since at the end rather than interleaved by date.
        var ordered: [ProviderInstance] = []
        var placed = Set<String>()
        for ri in remote.instances {
            if let merged = instanceMap[ri.id] {
                ordered.append(merged)
                placed.insert(ri.id)
            }
        }
        for li in local.instances where !placed.contains(li.id) {
            if let merged = instanceMap[li.id] {
                ordered.append(merged)
                placed.insert(li.id)
            }
        }
        // Anything only reachable through the map (defensive; should be
        // covered above) keeps the previous deterministic ordering.
        for inst in instanceMap.values where !placed.contains(inst.id) {
            ordered.append(inst)
        }
        local.instances = ordered
        // Drop modelEntries whose providerInstanceId was tombstoned. The
        // remote snapshot may still carry orphaned entries pointing at the
        // tombstoned instance; the local snapshot was already pruned by
        // removeInstance. Either way, after this merge no instance =>
        // no entries that belong to it.
        local.modelEntries.removeAll { tombstonedInstanceIds.contains($0.providerInstanceId) }

        // 2. Merge modelEntries — consume only user-modified remote entries.
        //
        // A restore must NOT propagate API-truth model metadata from another device: each
        // device can fetch its own models.dev/provider response, and copying one
        // device's fetched list on top of another's produces ghost entries when
        // the two fetches disagree (different UUIDs for the same model id, stale
        // contextWindow, etc.). This is what caused model lists to update
        // "spontaneously" with results that differed from a manual Refresh.
        //
        // New semantics: remote entries are only applied when they carry a user
        // intent — custom additions, overrides (displayName / maxOutputTokens),
        // or an explicit isHidden. Everything else is API truth and is dropped.
        // Pure API-truth entries are never touched; the local list stays exactly
        // as the last Refresh left it.
        //
        // Remote user-modified entries are aligned to local by (providerInstanceId,
        // baseModel.id), NOT by UUID — that way a model the user renamed on
        // device A ends up mapped onto device B's same-id local entry even if
        // the two devices generated different UUIDs during independent refreshes.
        let localEntriesSnapshot = local.modelEntries

        // Index local entries for lookup by (instanceId, baseModelId).
        struct EntryKey: Hashable { let instanceId: String; let modelId: String }
        var localIndex: [EntryKey: Int] = [:]
        for (idx, e) in local.modelEntries.enumerated() {
            localIndex[EntryKey(instanceId: e.providerInstanceId, modelId: e.baseModel.id)] = idx
        }

        var accepted = 0
        var skipped = 0
        var appliedOverrides = 0
        var appliedHidden = 0
        var insertedCustom = 0
        var skippedLegacyOverlay = 0   // remote had no userModifiedAt → overrides/isHidden not applied
        var skippedOlderRemote = 0     // remote userModifiedAt <= local userModifiedAt

        // Drop locally-known entries the union of tombstones marks as deleted.
        // Done before the remote loop so localIndex (built above) stays
        // consistent with the post-merge state. modelEntries that belong
        // to a tombstoned instance were already removed above.
        if !tombstonedEntryIds.isEmpty {
            local.modelEntries.removeAll { tombstonedEntryIds.contains($0.id) }
            // Rebuild localIndex so the per-key lookup below still works.
            localIndex.removeAll(keepingCapacity: true)
            for (idx, e) in local.modelEntries.enumerated() {
                localIndex[EntryKey(instanceId: e.providerInstanceId, modelId: e.baseModel.id)] = idx
            }
        }

        for re in remote.modelEntries {
            // Suppress entries the union of tombstones marks as deleted,
            // including any entries that hung off an instance the user
            // deleted on this device.
            if tombstonedEntryIds.contains(re.id) { continue }
            if tombstonedInstanceIds.contains(re.providerInstanceId) { continue }
            guard re.isUserModified else {
                skipped += 1
                continue
            }
            accepted += 1

            let key = EntryKey(instanceId: re.providerInstanceId, modelId: re.baseModel.id)
            if let idx = localIndex[key] {
                // Local already has this model id under this instance.
                //
                // Timestamp-based conflict resolution for overlay (overrides + isHidden):
                //   - Remote has no userModifiedAt → LEGACY data (pre-upgrade or not
                //     stamped by the uploader). Skip the overlay entirely to prevent
                //     stale override names from quietly re-appearing on newer devices.
                //   - Local has userModifiedAt but remote is older-or-equal → local wins.
                //   - Otherwise → remote wins, apply.
                //
                // We never touch baseModel (API truth) or isCustom (local Refresh owns it).
                let localEntry = local.modelEntries[idx]

                let remoteIsApplicable: Bool
                if re.userModifiedAt == nil {
                    remoteIsApplicable = false
                    skippedLegacyOverlay += 1
                } else if let localStamp = localEntry.userModifiedAt,
                          let remoteStamp = re.userModifiedAt,
                          remoteStamp <= localStamp {
                    remoteIsApplicable = false
                    skippedOlderRemote += 1
                } else {
                    remoteIsApplicable = true
                }

                guard remoteIsApplicable else { continue }

                var updated = localEntry
                var didChange = false
                if updated.overrides != re.overrides {
                    updated.overrides = re.overrides
                    appliedOverrides += 1
                    didChange = true
                }
                if updated.isHidden != re.isHidden {
                    updated.isHidden = re.isHidden
                    appliedHidden += 1
                    didChange = true
                }
                if didChange {
                    // Carry remote's userModifiedAt forward so subsequent merges on
                    // this device compare against the winning timestamp.
                    updated.userModifiedAt = re.userModifiedAt
                    local.modelEntries[idx] = updated
                }
            } else if re.isCustom {
                // Remote has a custom model that local doesn't know about — insert
                // it, preserving the remote UUID so modelGroups.memberEntryIds
                // references (which live in the same ProviderConfig blob and were
                // recorded against the remote UUID) stay valid.
                //
                // Legacy custom entries (no userModifiedAt) are still inserted:
                // refusing them would silently lose a user-authored model across the
                // upgrade boundary, which is strictly worse than the legacy-overlay
                // problem (adding a ghost is recoverable; deleting user data isn't).
                local.modelEntries.append(re)
                localIndex[key] = local.modelEntries.count - 1
                insertedCustom += 1
            }
            // else: remote has a non-custom entry for a model id local doesn't have.
            // That means the other device's API fetch returned a model this device's
            // fetch didn't — treat it as phantom and drop. Local Refresh is the only
            // authority for which non-custom models exist on this device.
        }

        // Per-instance before/after diff (unchanged structure — but now should be
        // mostly empty in the steady state, which is the whole point of the rewrite).
        let beforeByInstance = Dictionary(grouping: localEntriesSnapshot, by: { $0.providerInstanceId })
        let afterByInstance = Dictionary(grouping: local.modelEntries, by: { $0.providerInstanceId })
        let allInstanceIds = Set(beforeByInstance.keys).union(afterByInstance.keys)
        for iid in allInstanceIds {
            let beforeIds = Set((beforeByInstance[iid] ?? []).map { $0.baseModel.id })
            let afterIds = Set((afterByInstance[iid] ?? []).map { $0.baseModel.id })
            guard beforeIds != afterIds else { continue }
            let added = afterIds.subtracting(beforeIds).sorted()
            let removed = beforeIds.subtracting(afterIds).sorted()
            let instanceLabel = local.instances.first(where: { $0.id == iid })?.label ?? "?"
            logger.info("[ModelList] mergeProviderConfig: instance=\(instanceLabel)(\(iid.prefix(8))) before=\(beforeIds.count) after=\(afterIds.count) added=\(added.count)[\(added.prefix(10).joined(separator: ","))] removed=\(removed.count)[\(removed.prefix(10).joined(separator: ","))]")
        }
        logger.info("[ModelList] mergeProviderConfig: remoteEntries=\(remote.modelEntries.count) accepted=\(accepted) skipped=\(skipped) appliedOverrides=\(appliedOverrides) appliedHidden=\(appliedHidden) insertedCustom=\(insertedCustom) skippedLegacyOverlay=\(skippedLegacyOverlay) skippedOlderRemote=\(skippedOlderRemote) totalAfter=\(local.modelEntries.count)")

        // 3. Merge modelGroups — same-id: remote wins. Same-name different-id:
        // collapse (both devices independently created a group with the same
        // name; converge them onto a single id — prefer the smaller id string
        // as the stable winner so both devices deterministically agree).
        //
        // This replaces the old "(device name) suffix on name collision" logic
        // that produced permanent forks: two devices with a "Coding" group ended
        // up showing BOTH "Coding" and "Coding (iPhone...)" on both sides forever.
        // Pre-filter locally-known groups by the tombstone union (the local
        // side already pruned them in removeGroup; this guard handles
        // an incoming remote that still has them, plus same-id resurrection).
        if !tombstonedGroupIds.isEmpty {
            // [T-subagent-dangling-group] Groups pruned here never pass through
            // removeGroup(), so sub-agents pointing at them would keep a
            // dangling modelGroupId. Clear those pointers the same way
            // removeGroup() does. Only ids this device actually had can
            // dangle — intersect with the pre-prune local list, not the whole
            // tombstone union. This covers backup restores: the restore
            // path runs through this function.
            let removedGroupIds = local.modelGroups.map(\.id).filter { tombstonedGroupIds.contains($0) }
            local.modelGroups.removeAll { tombstonedGroupIds.contains($0.id) }
            for groupId in removedGroupIds {
                SubAgentStore.shared.clearModelGroup(groupId)
            }
        }
        var groupMap = Dictionary(local.modelGroups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var groupIdRewrites: [String: String] = [:]  // oldRemoteId -> canonicalLocalId
        // Build a local name index for collision detection.
        var localGroupByName: [String: String] = [:]  // name -> id
        for g in local.modelGroups { localGroupByName[g.name] = g.id }
        for rg in remote.modelGroups {
            if tombstonedGroupIds.contains(rg.id) { continue }
            // Strip out member references to tombstoned entries so a stale
            // remote member list doesn't carry deleted ids forward.
            var rg = rg
            if !tombstonedEntryIds.isEmpty {
                rg.memberEntryIds.removeAll { tombstonedEntryIds.contains($0) }
            }
            if let localGroup = groupMap[rg.id] {
                // Same id — use the package's member order as primary: it
                // represents the source device's latest edit whose order should
                // be respected. Local-only members (added after the backup was
                // taken) are appended at the end so no member is lost.
                var merged = rg  // start from remote for scalar fields + order
                var order = rg.memberEntryIds
                let remoteSet = Set(order)
                for mid in localGroup.memberEntryIds where !remoteSet.contains(mid) {
                    order.append(mid)
                }
                merged.memberEntryIds = order
                groupMap[rg.id] = merged
            } else if let collidingLocalId = localGroupByName[rg.name], collidingLocalId != rg.id {
                // Same name, different id → collapse onto the lexicographically
                // smaller id so both devices deterministically pick the same winner.
                let canonicalId = min(collidingLocalId, rg.id)
                let otherId = max(collidingLocalId, rg.id)
                groupIdRewrites[otherId] = canonicalId

                if canonicalId == collidingLocalId {
                    // Local id wins: merge remote's memberEntryIds union into local, prefer local's other fields.
                    if var winner = groupMap[canonicalId] {
                        var seen = Set(winner.memberEntryIds)
                        for mid in rg.memberEntryIds where !seen.contains(mid) {
                            winner.memberEntryIds.append(mid)
                            seen.insert(mid)
                        }
                        groupMap[canonicalId] = winner
                    }
                } else {
                    // Remote id wins: install remote, but merge in the old local memberEntryIds
                    // so nothing is lost. Drop the old local entry under collidingLocalId.
                    var winner = rg
                    if let oldLocal = groupMap[collidingLocalId] {
                        var seen = Set(winner.memberEntryIds)
                        for mid in oldLocal.memberEntryIds where !seen.contains(mid) {
                            winner.memberEntryIds.append(mid)
                            seen.insert(mid)
                        }
                    }
                    groupMap.removeValue(forKey: collidingLocalId)
                    groupMap[canonicalId] = winner
                    localGroupByName[winner.name] = canonicalId
                }
                logger.info("[ModelList] mergeProviderConfig: group name collision '\(rg.name)' collapsed: \(otherId.prefix(8)) -> \(canonicalId.prefix(8))")
            } else {
                // Brand new group — no id clash, no name clash. Just add it.
                groupMap[rg.id] = rg
                localGroupByName[rg.name] = rg.id
            }
        }
        // [T-backup-restore-order] `Dictionary.values` has NO defined order, so
        // this line alone could reshuffle the group list on every merge —
        // worse than the instances case, which at least sorted by date.
        // Rebuild deterministically: the backup's order first, then whatever
        // is local-only, so a restore does not rearrange a list the user
        // dragged into place.
        var orderedGroups: [ModelGroup] = []
        var placedGroups = Set<String>()
        for rg in remote.modelGroups {
            // The id may have been rewritten by the name-collision pass
            // above, so resolve through the map rather than trusting `rg`.
            if let merged = groupMap[rg.id] {
                orderedGroups.append(merged)
                placedGroups.insert(merged.id)
            }
        }
        for lg in local.modelGroups where !placedGroups.contains(lg.id) {
            if let merged = groupMap[lg.id] {
                orderedGroups.append(merged)
                placedGroups.insert(merged.id)
            }
        }
        for g in groupMap.values where !placedGroups.contains(g.id) {
            orderedGroups.append(g)
            placedGroups.insert(g.id)
        }
        local.modelGroups = orderedGroups

        // Fix up dangling references to group ids we rewrote. Defaults / agent
        // loop lists live outside the group array itself but point at group ids.
        if !groupIdRewrites.isEmpty {
            if let def = local.defaultPrimaryGroupId, let replacement = groupIdRewrites[def] {
                local.defaultPrimaryGroupId = replacement
            }
            if let def = local.defaultSubGroupId, let replacement = groupIdRewrites[def] {
                local.defaultSubGroupId = replacement
            }
            local.agentLoopGroupIds = local.agentLoopGroupIds.map { groupIdRewrites[$0] ?? $0 }
            // The voice / vision selectors and per-session group bindings
            // point at the same groups and were NOT fixed up: leaving them
            // aimed at the removed id silently disabled voice input/output
            // and vision (their resolvers return nil for an unknown group)
            // and stranded each binding's group fallback. The VALUES stay
            // local — only the id is translated to the surviving group.
            if let v = local.voiceInputGroupId, let replacement = groupIdRewrites[v] {
                local.voiceInputGroupId = replacement
            }
            if let v = local.voiceOutputGroupId, let replacement = groupIdRewrites[v] {
                local.voiceOutputGroupId = replacement
            }
            if let v = local.visionGroupId, let replacement = groupIdRewrites[v] {
                local.visionGroupId = replacement
            }
            // [问题3 / G2] 新增的五个用途槽位指向同一批组，必须一起改写。
            // 漏掉它们的话，组被合并后这几个槽位会指向一个已经不存在的 id，
            // 表现为"明明配了却永远取不到模型"。
            if let v = local.imageOutputGroupId, let replacement = groupIdRewrites[v] {
                local.imageOutputGroupId = replacement
            }
            if let v = local.videoOutputGroupId, let replacement = groupIdRewrites[v] {
                local.videoOutputGroupId = replacement
            }
            if let v = local.realtimeVoiceGroupId, let replacement = groupIdRewrites[v] {
                local.realtimeVoiceGroupId = replacement
            }
            if let v = local.embeddingGroupId, let replacement = groupIdRewrites[v] {
                local.embeddingGroupId = replacement
            }
            if let v = local.judgeGroupId, let replacement = groupIdRewrites[v] {
                local.judgeGroupId = replacement
            }
            // [T-model-groups-slots] 定时小帮手指针指向同一批组，一起改写。
            if let v = local.scheduledHelperGroupId, let replacement = groupIdRewrites[v] {
                local.scheduledHelperGroupId = replacement
            }
            for (sid, var binding) in local.sessionBindings {
                func rewrite(_ source: SessionModelSource) -> SessionModelSource {
                    if case .group(let gid, let resolved) = source,
                       let replacement = groupIdRewrites[gid] {
                        return .group(groupId: replacement, resolvedEntryId: resolved)
                    }
                    return source
                }
                binding.primarySource = rewrite(binding.primarySource)
                binding.subModelSource = binding.subModelSource.map(rewrite)
                local.sessionBindings[sid] = binding
            }
            // Sub-agents point at groups too, but their store is not part of
            // ProviderConfig, so the fix-up above cannot reach them. A pointer
            // at a rewritten id must FOLLOW the rewrite to the surviving
            // group — clearing it would drop an assignment that still has a
            // valid target. The local-loser case is the live one: this
            // device's own agent can point at the local id that just lost the
            // name collision. Rewritten via the existing upsertSubAgent (it
            // persists and marks the record dirty); no SubAgentStore change.
            let roster = SubAgentStore.shared.subAgents
            for (oldId, canonicalId) in groupIdRewrites {
                // A rewrite can CHAIN: a later collision can drop the very id
                // an earlier rewrite pointed at (z -> m, then m -> a when a
                // beats m). Follow the map to its end before writing back,
                // or the agent lands on an id that no longer exists. The map
                // cannot cycle by construction — each collision rewrites the
                // lexicographically larger id onto the smaller one — but guard
                // anyway so a malformed map can never hang the loop.
                var target = canonicalId
                var seen: Set<String> = [canonicalId]
                while let next = groupIdRewrites[target] {
                    guard seen.insert(next).inserted else { break }
                    target = next
                }
                for agent in roster where agent.modelGroupId == oldId {
                    var rewritten = agent
                    rewritten.modelGroupId = target
                    SubAgentStore.shared.upsertSubAgent(rewritten)
                }
            }
        }

        // 4. Don't touch: agentLoopModelEntryIds, sessionInferenceConfigs, and
        //    the sessionBindings' contents. These stay per-device independent
        //    (reading from store.config above ensures we're preserving the
        //    latest in-memory values, not stale disk) — the fix-up above only
        //    translates group ids inside bindings/selectors to the surviving
        //    group when a name collision removed the id they pointed at.


        // Write back the union of tombstones so a later restore still
        // suppresses the same deleted ids. Without this the delete intent
        // would only live on the device that issued it.
        local.deletedInstances    = mergedInstanceTombstones
        local.deletedModelEntries = mergedEntryTombstones
        local.deletedModelGroups  = mergedGroupTombstones

        // Commit: dedupe cross-device duplicate entries, then publish the
        // merged config (in-memory + JSON + SQLite) via applyConfig. The
        // tombstone union above is written back with the config so a later
        // restore still suppresses the same deleted ids.
        let priorInstanceIds = Set(store.config.instances.map(\.id))
        let priorEntryInstanceIds = Set(store.config.modelEntries.map(\.providerInstanceId))
        let (deduped, prunedEntryIds) = ProviderConfigStore.dedupeEntriesByModel(local)
        if deduped == store.config, prunedEntryIds.isEmpty {
            return
        }
        store.applyConfig(deduped)
        logger.info("[Restore] mergeProviderConfigForRestore: merged \(instanceMap.count) instances, \(deduped.modelEntries.count) entries, \(deduped.modelGroups.count) groups")
        if !prunedEntryIds.isEmpty {
            logger.info("[Restore] mergeProviderConfigForRestore: collapsed \(prunedEntryIds.count) duplicate model entries")
        }
        // Fire-and-forget model refreshes for instances left with an empty
        // model list (the package can lack model rows when the source device
        // hadn't refreshed yet). refreshModels handles errors internally.
        let instancesNeedingRefresh: [ProviderInstance] = deduped.instances.filter { inst in
            let entriesAfter = deduped.modelEntries.filter { $0.providerInstanceId == inst.id }
            return entriesAfter.isEmpty && (!priorInstanceIds.contains(inst.id) ||
                                            !priorEntryInstanceIds.contains(inst.id))
        }
        for inst in instancesNeedingRefresh {
            Task { await ProviderConfigStore.shared.refreshModels(for: inst) }
        }
    }

    private static func mergeTombstones(_ a: [ProviderConfigTombstone],
                                        _ b: [ProviderConfigTombstone]) -> [ProviderConfigTombstone] {
        var byId: [String: ProviderConfigTombstone] = [:]
        for t in a { byId[t.id] = t }
        for t in b {
            if let existing = byId[t.id] {
                if t.deletedAt > existing.deletedAt { byId[t.id] = t }
            } else {
                byId[t.id] = t
            }
        }
        return Array(byId.values)
    }


    // MARK: - MCP servers

    private func importMCPServers(root: URL, options: Options) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.mcpServers.rawValue)
        let src = root.appendingPathComponent("data/mcp_servers.json")
        guard FileManager.default.fileExists(atPath: src.path) else { return report }
        let dst = MCPStore.syncFileURL
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if options.mode == .merge {
            // [A5] Merge must never delete a local-only MCP server. The old
            // code ignored `mode` entirely and did removeItem + copyItem, so
            // every server that existed only on this device vanished — the
            // exact opposite of the merge footer's "Nothing is deleted".
            // Match by id and only replace when the package's copy is newer;
            // the local file is the base, so local-only entries survive and
            // unknown top-level keys are preserved.
            let outcome = try Self.mergeMCPServersFile(package: src, live: dst)
            report.imported = outcome.written
            report.skipped = outcome.kept
        } else {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
            // Count the servers in the file, not the file itself — reporting
            // 1 for any number of servers under-states the restore total.
            // Same lenient count the exporter uses for its manifest stat.
            // Fallback differs from the exporter's, deliberately: nil means
            // the file cannot be read as a servers file at all, and MCPStore
            // loads exactly 0 servers from such a file — reporting 1 here
            // would claim a restore that never happened.
            report.imported = BackupExporter.mcpServerCount(at: src) ?? 0
        }
        // The store caches servers in memory; scanExternalChanges reloads from
        // disk, stamps updatedAt and marks each changed server dirty.
        await MainActor.run { MCPStore.shared.scanExternalChanges() }
        return report
    }

    /// [A5] Merge the package's `mcpServers` map into the LIVE file by id.
    ///
    /// The live file is the base, so a server this device has and the package
    /// does not is left completely untouched (merge never deletes). A server
    /// both sides carry is overwritten only when the package's `updatedAt` is
    /// STRICTLY newer — a package entry with no timestamp cannot prove it is
    /// newer, so the local copy wins, matching the "only replaced when the
    /// backup's copy is newer" promise.
    ///
    /// Raw JSONSerialization rather than the typed model: it round-trips
    /// unknown fields an externally-authored config may carry, exactly as
    /// MCPStore and the exporter's redaction do.
    ///
    /// Returns `(written, kept)`: servers added + replaced, and package
    /// servers whose local copy was left alone.
    private static func mergeMCPServersFile(package: URL, live: URL)
        throws -> (written: Int, kept: Int) {
        let fm = FileManager.default
        guard let pkgData = try? Data(contentsOf: package),
              let pkgRoot = (try? JSONSerialization.jsonObject(with: pkgData)) as? [String: Any],
              let pkgServers = pkgRoot["mcpServers"] as? [String: Any] else {
            return (0, 0)
        }
        var root: [String: Any] = pkgRoot
        var localServers: [String: Any] = [:]
        if let liveData = try? Data(contentsOf: live),
           let liveRoot = (try? JSONSerialization.jsonObject(with: liveData)) as? [String: Any],
           let existing = liveRoot["mcpServers"] as? [String: Any] {
            root = liveRoot
            localServers = existing
        }
        var written = 0
        var kept = 0
        var merged = localServers
        for (id, pkgEntry) in pkgServers {
            guard let localEntry = localServers[id] else {
                // Not present locally: a genuine addition.
                merged[id] = pkgEntry
                written += 1
                continue
            }
            if let pkgAt = serverUpdatedAt(pkgEntry),
               let localAt = serverUpdatedAt(localEntry),
               pkgAt > localAt {
                merged[id] = pkgEntry
                written += 1
            } else {
                kept += 1
            }
        }
        root["mcpServers"] = merged
        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys])
        try fm.createDirectory(at: live.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try out.write(to: live, options: .atomic)
        return (written, kept)
    }

    /// Epoch-seconds `updatedAt` from a raw server entry, if present/numeric.
    private static func serverUpdatedAt(_ raw: Any) -> Double? {
        (raw as? [String: Any])?["updatedAt"] as? Double
    }

    // MARK: - Environment variables

    /// MERGE, never replace.
    ///
    /// Restoring must not cost the user variables this device already has —
    /// including ones created after the backup was taken. So an existing key is
    /// left exactly as it is (entry AND value), and only genuinely new keys are
    /// added. That also makes restoring the same package twice a no-op.
    ///
    /// Values arrive separately, via secrets.json under the credential policy,
    /// and only in an encrypted package. A variable restored without its value
    /// is created with an empty one: visible in the list, flagged by its own
    /// empty state, and waiting to be filled in — which is far better than the
    /// variable not existing at all and the user not knowing it is missing.
    private func importEnvironmentVariables(root: URL) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.environmentVariables.rawValue)
        let src = root.appendingPathComponent("data/env_vars.json")
        guard FileManager.default.fileExists(atPath: src.path) else { return report }

        let data = try Data(contentsOf: src)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incoming = try decoder.decode([EnvVarEntry].self, from: data)

        await MainActor.run {
            let store = EnvVarStore.shared
            let existing = Set(store.entries.map(\.key))
            for entry in incoming {
                guard !existing.contains(entry.key) else {
                    report.skipped += 1
                    continue
                }
                // The secrets importer may already have written this key's
                // value into the Keychain; keep it rather than blanking it.
                let value = EnvVarStore.loadValueSync(forKey: entry.key) ?? ""
                store.add(key: entry.key, value: value, note: entry.note)
                report.imported += 1
            }
        }
        return report
    }

    // MARK: - Voice corrections

    private func importVoiceCorrections(root: URL) async throws -> CategoryReport {
        var report = CategoryReport(category: BackupCategory.voiceCorrections.rawValue)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        guard let db = VoiceCorrectionDB.shared else {
            report.failed = "voice-correction DB unavailable"
            return report
        }

        struct ConfusionRecord: Codable {
            let id: String, phoneticKey: String, variants: [String], correctedTerm: String
            let locale: String, frequency: Int, negativeFeedbackCount: Int
            let confidence: Double, lastSeen: Double, source: String
        }
        struct VocabularyRecord: Codable {
            let id: String, term: String, phoneticKey: String, locale: String
            let posTag: String?, frequency: Int, distinctDays: Int
            let backgroundRank: Int?, lastSeen: Double, source: String
        }

        // NOTE: the DB exposes only aggregate upserts (they BUMP frequency
        // rather than setting it), so counters are not restored verbatim —
        // a restored dictionary keeps its terms but its frequencies re-converge
        // through use. Faithful counter restore needs a set-exact API; recorded
        // as a known limitation rather than silently pretending otherwise.
        for rec in readJSONL(dataDir, base: "voice_correction", as: ConfusionRecord.self)
        where !rec.correctedTerm.isEmpty {
            await db.upsertConfusion(
                phoneticKey: rec.phoneticKey,
                originalVariant: rec.variants.first ?? rec.correctedTerm,
                correctedTerm: rec.correctedTerm, locale: rec.locale,
                contextSample: nil, asrProvider: "restore", source: rec.source)
            report.imported += 1
        }
        for rec in readJSONL(dataDir, base: "voice_correction", as: VocabularyRecord.self)
        where !rec.term.isEmpty {
            await db.upsertVocabulary(
                term: rec.term, phoneticKey: rec.phoneticKey, locale: rec.locale,
                posTag: rec.posTag, backgroundRank: rec.backgroundRank,
                occurrences: max(rec.frequency, 1),
                day: Self.dayKey(from: rec.lastSeen))
            report.imported += 1
        }
        return report
    }

    private static func dayKey(from epoch: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }

    // MARK: - Overwrite wipe (Fix 2)
    //
    // Merge never deletes anything. Overwrite deletes, per selected category,
    // exactly the local items the package does NOT carry — after integrity +
    // passphrase + preflight have passed, after the mandatory safety snapshot,
    // and after that category's rollback snapshot. The rules that bound every
    // wipe:
    //   * only selected categories, only inside their containment roots
    //     (`isContained`, resolved both sides);
    //   * never the device ID, never Keychain items outside the one key being
    //     deleted, never the safety snapshot (it lives in Backups/, under no
    //     category root);
    //   * a package side that cannot be read means NO wipe for that category
    //     (fail closed — an unreadable sessions file must never read as "the
    //     package carries zero sessions, delete them all");
    //   * Voice Corrections is never wiped: its DB exposes only aggregate
    //     upserts (frequencies bump rather than set), so a wipe + re-import
    //     would destroy local learning data without faithfully reproducing
    //     the package — destructive with an unfaithful restore. It stays
    //     merge-only, and the UI disables its row in overwrite mode.
    //
    // The preview (`overwriteDeletionCount`) shares the same "local but not
    // in the package" target sets as the wipe, so the numbers the mode
    // picker shows are the numbers the wipe will act on. Target computers
    // return nil when the package side is unreadable, so the preview shows
    // nothing rather than a 0 that would be a lie.

    /// Minimal shape of a `sessions.jsonl` record — only the id is needed to
    /// decide what survives the wipe. Unknown keys are ignored by Codable.
    private struct SessionIDRecord: Codable {
        struct SessionStub: Codable { let id: String }
        let session: SessionStub
    }

    /// Minimal shape of a `skills.jsonl` record.
    private struct SkillIDRecord: Codable { let id: String }

    /// True when a sharded JSONL stream (`<base>.jsonl` or `<base>-*.jsonl`)
    /// exists in `dir`. Used to tell "the package carries zero records" from
    /// "the package has no such file at all" — only the first may wipe.
    private func jsonlExists(dir: URL, base: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .contains { $0 == "\(base).jsonl"
                || ($0.hasPrefix("\(base)-") && $0.hasSuffix(".jsonl")) }
    }

    /// Delete one selected category's local-but-not-in-package items, before
    /// that category's import. Returns how many items were deleted.
    func wipeCategoryForOverwrite(_ category: BackupCategory,
                                  root: URL,
                                  fileIndex: [BackupFileIndexEntry]) async throws -> Int {
        switch category {
        case .chats:
            return try await wipeChatsForOverwrite(root: root)
        case .sharedFiles, .stickers, .appearance:
            // A missing file index is fail-closed: with no index every live
            // file would read as "not in the package".
            guard FileManager.default.fileExists(
                atPath: root.appendingPathComponent("files.index.jsonl").path) else { return 0 }
            return deleteWipeTargets(fileWipeTargets(category: category, fileIndex: fileIndex),
                                     within: containmentRoot(for: category))
        case .skills:
            return await wipeSkillsForOverwrite(root: root, fileIndex: fileIndex)
        case .memory:
            return deleteWipeTargets(memoryWipeTargets(root: root),
                                     within: containmentRoot(for: .memory))
        case .providers:
            return await wipeProvidersForOverwrite(root: root)
        case .mcpServers:
            // Whole-file replace in the import; the count is what the replace
            // will drop, computed here so the report can state it.
            return await mcpDeletionCount(root: root) ?? 0
        case .environmentVariables:
            return await wipeEnvVarsForOverwrite(root: root)
        case .scheduledTasks:
            return await wipeScheduledTasksForOverwrite(root: root)
        case .ishUserData:
            // A missing file index is fail-closed: with no index every live
            // file would read as "not in the package". (Same guard as the
            // file-tree categories above.)
            guard FileManager.default.fileExists(
                atPath: root.appendingPathComponent("files.index.jsonl").path) else { return 0 }
            return deleteWipeTargets(ishWipeTargets(fileIndex: fileIndex),
                                     within: RootfsManager.shared.dataPath)
        case .voiceCorrections:
            // Merge only (see the section header). Never wiped, never faked.
            return 0
        }
    }

    /// Preview counterpart of `wipeCategoryForOverwrite`: how many local
    /// items this category's wipe would delete, or nil when that cannot be
    /// computed (package side unreadable, or the category is never wiped).
    func overwriteDeletionCount(_ category: BackupCategory,
                                root: URL,
                                fileIndex: [BackupFileIndexEntry]) async -> Int? {
        switch category {
        case .chats:
            return await chatWipeTargets(root: root)?.count
        case .sharedFiles, .stickers, .appearance:
            guard FileManager.default.fileExists(
                atPath: root.appendingPathComponent("files.index.jsonl").path) else { return nil }
            return fileWipeTargets(category: category, fileIndex: fileIndex).count
        case .skills:
            guard let records = await skillWipeTargetIDs(root: root) else { return nil }
            guard FileManager.default.fileExists(
                atPath: root.appendingPathComponent("files.index.jsonl").path) else { return records.count }
            return records.count
                + fileWipeTargets(category: .skills, fileIndex: fileIndex).count
        case .memory:
            return memoryWipeTargets(root: root).count
        case .providers:
            return await providerDeletionCount(root: root)
        case .mcpServers:
            return await mcpDeletionCount(root: root)
        case .environmentVariables:
            return await envWipeTargetIDs(root: root)?.count
        case .scheduledTasks:
            return await scheduledWipeTargetIDs(root: root)?.count
        case .ishUserData:
            guard FileManager.default.fileExists(
                atPath: root.appendingPathComponent("files.index.jsonl").path) else { return nil }
            return ishWipeTargets(fileIndex: fileIndex).count
        case .voiceCorrections:
            return nil
        }
    }

    // MARK: Chats wipe

    /// Local session ids an overwrite would delete: everything not in the
    /// package, minus children of a package session (deleting their parent
    /// would cascade into them via `deleteSessionLocalOnly`, and the import
    /// would then have to resurrect them). Nil when the package carries no
    /// sessions file at all — fail closed, never "zero sessions".
    private func chatWipeTargets(root: URL) async -> [String]? {
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        guard jsonlExists(dir: dataDir, base: "sessions") else { return nil }
        let packageIds = Set(readJSONL(dataDir, base: "sessions",
                                       as: SessionIDRecord.self).map(\.session.id))
        let store = ChatStore.shared
        var keep = packageIds
        for pid in packageIds {
            keep.formUnion(await store.childSessionIds(of: pid))
        }
        return await store.allSessionIds().filter { !keep.contains($0) }
    }

    private func wipeChatsForOverwrite(root: URL) async throws -> Int {
        guard let targets = await chatWipeTargets(root: root), !targets.isEmpty else { return 0 }
        let store = ChatStore.shared
        // Re-checked immediately before deleting: a run that started after
        // preflight must not have its session wiped out from under it.
        let running = targets.filter { store.isSessionRunning($0) }
        guard running.isEmpty else { throw ImportError.sessionsRunning(running) }
        var deleted = 0
        // `deleteSessionLocalOnly` cascades into child sessions, so track
        // what is already gone instead of counting a child twice.
        var gone: Set<String> = []
        for id in targets where !gone.contains(id) {
            let children = await store.childSessionIds(of: id)
            // Runtime teardown first (VM cache, browser pool, timers, files),
            // then the rows — the same order the manual delete path uses.
            await MainActor.run {
                SessionTeardown.tearDownRuntime(sessionId: id, reason: "overwrite restore")
            }
            await store.deleteSessionLocalOnly(id)
            gone.insert(id)
            gone.formUnion(children)
            deleted += 1
        }
        return deleted
    }

    // MARK: File-tree wipe

    /// Live files under a category root whose index path the package does not
    /// carry. The index path is the package's own form ("shared/<rel>"), so
    /// the comparison is against what the export actually recorded.
    private func fileWipeTargets(category: BackupCategory,
                                 fileIndex: [BackupFileIndexEntry]) -> [URL] {
        let fm = FileManager.default
        let liveRoot = containmentRoot(for: category)
        let indexed = Set(fileIndex
            .filter { $0.category == category.rawValue && $0.skipped == nil }
            .map(\.path))
        guard let enumerator = fm.enumerator(
            at: liveRoot, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            // A staged temp from an interrupted restore is not user data.
            guard !url.lastPathComponent.hasPrefix(".restore-") else { continue }
            let rel = String(url.path.dropFirst(liveRoot.path.count + 1))
            let indexPath: String
            switch category {
            case .sharedFiles: indexPath = "shared/" + rel
            case .stickers: indexPath = "stickers/" + rel
            case .appearance: indexPath = "appearance/" + rel
            case .skills: indexPath = "skills/" + rel
            default: continue
            }
            guard !indexed.contains(indexPath), isContained(url, within: liveRoot) else { continue }
            out.append(url)
        }
        return out
    }

    /// Live files under the guest's home directories that the package does
    /// not carry. Walks ONLY data/root and data/home — never the whole
    /// data/ tree, which holds the entire Alpine OS: enumerating that
    /// would list every system file as "not in the package" and delete
    /// the OS out from under the user.
    ///
    /// Symlinks are skipped (never descended into, never deleted): a link
    /// inside /root can point at the OS trees, and deleting through it
    /// would remove system files the index never mentioned.
    private func ishWipeTargets(fileIndex: [BackupFileIndexEntry]) -> [URL] {
        let fm = FileManager.default
        let dataPath = RootfsManager.shared.dataPath
        let indexed = Set(fileIndex
            .filter { $0.category == BackupCategory.ishUserData.rawValue && $0.skipped == nil }
            .map(\.path))
        var out: [URL] = []
        for home in ["root", "home"] {
            let liveRoot = dataPath.appendingPathComponent(home)
            guard let enumerator = fm.enumerator(
                at: liveRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            else { continue }
            for case let url as URL in enumerator {
                guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]) else { continue }
                // Never follow a link out of the home directory — see above.
                if vals.isSymbolicLink == true {
                    if vals.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                guard vals.isRegularFile == true else { continue }
                // A staged temp from an interrupted restore is not user data.
                guard !url.lastPathComponent.hasPrefix(".restore-") else { continue }
                let rel = String(url.path.dropFirst(liveRoot.path.count + 1))
                let indexPath = "ish/\(home)/\(rel)"
                guard !indexed.contains(indexPath),
                      isContained(url, within: dataPath) else { continue }
                out.append(url)
            }
        }
        return out
    }

    /// Delete the targets (each re-checked for containment) and drop
    /// directories left empty, deepest first, never the root itself.
    private func deleteWipeTargets(_ urls: [URL], within root: URL) -> Int {
        let fm = FileManager.default
        var deleted = 0
        var parents: [URL] = []
        for url in urls {
            guard isContained(url, within: root) else { continue }
            if (try? fm.removeItem(at: url)) != nil {
                deleted += 1
                parents.append(url.deletingLastPathComponent())
            }
        }
        for dir in Set(parents).sorted(by: { $0.path.count > $1.path.count }) {
            guard dir != root, isContained(dir, within: root),
                  ((try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? false)
            else { continue }
            try? fm.removeItem(at: dir)
        }
        return deleted
    }

    // MARK: Memory wipe

    /// Live `.md` files the package does not carry: top-level files plus
    /// `personas/**/*.md`, exactly the two shapes the memory import writes.
    /// `personas.json` / `regex-rules.json` are not `.md` — they are replaced
    /// wholesale by the import when the package carries them, and left alone
    /// when it does not.
    private func memoryWipeTargets(root: URL) -> [URL] {
        let fm = FileManager.default
        let src = root.appendingPathComponent("data/memory", isDirectory: true)
        guard fm.fileExists(atPath: src.path) else { return [] }
        var packageRel = Set<String>()
        for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? []
        where name.hasSuffix(".md") {
            packageRel.insert(name)
        }
        let personasSrc = src.appendingPathComponent("personas", isDirectory: true)
        if fm.fileExists(atPath: personasSrc.path),
           let e = fm.enumerator(at: personasSrc, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let u as URL in e where u.pathExtension == "md" {
                packageRel.insert("personas/"
                    + String(u.path.dropFirst(personasSrc.path.count + 1)))
            }
        }
        let dst = AIChatViewModel.minisMemoryPersistentDir
        var out: [URL] = []
        for name in (try? fm.contentsOfDirectory(atPath: dst.path)) ?? []
        where name.hasSuffix(".md") {
            if !packageRel.contains(name) { out.append(dst.appendingPathComponent(name)) }
        }
        let personasDst = dst.appendingPathComponent("personas", isDirectory: true)
        if fm.fileExists(atPath: personasDst.path),
           let e = fm.enumerator(at: personasDst, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let u as URL in e {
                guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      u.pathExtension == "md" else { continue }
                let rel = "personas/" + String(u.path.dropFirst(personasDst.path.count + 1))
                if !packageRel.contains(rel) { out.append(u) }
            }
        }
        return out
    }

    // MARK: Skills wipe

    /// Local skill ids the package does not carry, excluding bundled skills
    /// (they ship with the app — deleting one would remove shipped content
    /// and queue a cloud delete for it). Nil when the package carries no
    /// skills file.
    private func skillWipeTargetIDs(root: URL) async -> [String]? {
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        guard jsonlExists(dir: dataDir, base: "skills") else { return nil }
        let packageIds = Set(readJSONL(dataDir, base: "skills",
                                       as: SkillIDRecord.self).map(\.id))
        return await MainActor.run {
            SkillStore.shared.skills
                .filter { !packageIds.contains($0.id) && $0.importSource != .bundled }
                .map(\.id)
        }
    }

    private func wipeSkillsForOverwrite(root: URL,
                                        fileIndex: [BackupFileIndexEntry]) async -> Int {
        guard let ids = await skillWipeTargetIDs(root: root) else { return 0 }
        // Records first (deleteSkill removes the skill's directories too),
        // then the file-tree difference for the skills that survive.
        let deletedRecords = await MainActor.run {
            let store = SkillStore.shared
            for id in ids { store.deleteSkill(id) }
            return ids.count
        }
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent("files.index.jsonl").path) else {
            return deletedRecords
        }
        let deletedFiles = deleteWipeTargets(
            fileWipeTargets(category: .skills, fileIndex: fileIndex),
            within: containmentRoot(for: .skills))
        return deletedRecords + deletedFiles
    }

    // MARK: Providers wipe

    private func packageProviderConfig(root: URL) -> ProviderConfig? {
        let url = root.appendingPathComponent("data/provider_config.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProviderConfig.self, from: data)
    }

    /// A per-device group pointer, kept only when its target survives the
    /// replace — a pointer at a group the package never carried is dropped
    /// rather than left dangling.
    private static func preservedGroupPointer(_ id: String?, in groups: Set<String>) -> String? {
        guard let id, groups.contains(id) else { return nil }
        return id
    }

    /// Replace the whole provider config with the package's, preserving the
    /// local per-device pointers, and clear every local thinking rule (the
    /// package's rules are imported onto an empty set by `importProviders`).
    /// Returns config objects + rules removed.
    private func wipeProvidersForOverwrite(root: URL) async -> Int {
        guard let config = packageProviderConfig(root: root) else { return 0 }
        // Session bindings / inference configs are keyed by session id, so
        // they are pruned against the sessions that exist NOW — chats, which
        // runs first, has already wiped its own.
        let localSessionIds = Set(await ChatStore.shared.allSessionIds())
        let (removed, localInstances) = await MainActor.run {
            let local = ProviderConfigStore.shared.config
            var next = config
            let groupIds = Set(next.modelGroups.map(\.id))
            let entryIds = Set(next.modelEntries.map(\.id))
            // Per-device pointers stay exactly as this device has them.
            // Defaults are pointers too (the merge path leaves them alone).
            next.defaultPrimaryGroupId = Self.preservedGroupPointer(
                local.defaultPrimaryGroupId, in: groupIds)
            next.defaultSubGroupId = Self.preservedGroupPointer(
                local.defaultSubGroupId, in: groupIds)
            next.voiceInputGroupId = Self.preservedGroupPointer(
                local.voiceInputGroupId, in: groupIds)
            next.voiceOutputGroupId = Self.preservedGroupPointer(
                local.voiceOutputGroupId, in: groupIds)
            next.visionGroupId = Self.preservedGroupPointer(
                local.visionGroupId, in: groupIds)
            next.imageOutputGroupId = Self.preservedGroupPointer(
                local.imageOutputGroupId, in: groupIds)
            next.videoOutputGroupId = Self.preservedGroupPointer(
                local.videoOutputGroupId, in: groupIds)
            next.realtimeVoiceGroupId = Self.preservedGroupPointer(
                local.realtimeVoiceGroupId, in: groupIds)
            next.embeddingGroupId = Self.preservedGroupPointer(
                local.embeddingGroupId, in: groupIds)
            next.judgeGroupId = Self.preservedGroupPointer(
                local.judgeGroupId, in: groupIds)
            next.scheduledHelperGroupId = Self.preservedGroupPointer(
                local.scheduledHelperGroupId, in: groupIds)
            next.agentLoopModelEntryIds = local.agentLoopModelEntryIds
                .filter { entryIds.contains($0) }
            next.agentLoopGroupIds = local.agentLoopGroupIds
                .filter { groupIds.contains($0) }
            next.sessionBindings = local.sessionBindings
                .filter { localSessionIds.contains($0.key) }
            next.sessionInferenceConfigs = local.sessionInferenceConfigs
                .filter { localSessionIds.contains($0.key) }
            // Tombstones come from the package verbatim: the package is the
            // source of truth for what was deleted on the source device.
            // No "(from backup)" suffix anywhere: local groups are gone, so
            // a package name cannot collide with one.
            let packageInstanceIds = Set(config.instances.map(\.id))
            let packageEntryIds = Set(config.modelEntries.map(\.id))
            let packageGroupIds = Set(config.modelGroups.map(\.id))
            let removed = local.instances.filter { !packageInstanceIds.contains($0.id) }.count
                + local.modelEntries.filter { !packageEntryIds.contains($0.id) }.count
                + local.modelGroups.filter { !packageGroupIds.contains($0.id) }.count
            ProviderConfigStore.shared.applyConfig(next)
            return (removed, local.instances)
        }
        // Thinking rules go through the store (not raw SQL) so the cloud
        // delete is queued and peers converge instead of resurrecting them.
        // Credentials are NOT touched here: the secrets importer keeps
        // existing keys by policy, and a removed provider's Keychain items
        // are not in the package's secrets.json, so deleting them would
        // break the "never delete Keychain items not in secrets.json" rule.
        // ProviderConfigStore is @MainActor and thinkingRules/deleteThinkingRule
        // are async, so await them directly — MainActor.run takes a synchronous
        // closure and cannot hold awaits (CI: "cannot pass @Sendable () async
        // -> Int to parameter expecting synchronous function type").
        var rulesRemoved = 0
        for inst in localInstances {
            for rule in await ProviderConfigStore.shared.thinkingRules(for: inst.id) {
                if await ProviderConfigStore.shared.deleteThinkingRule(
                    id: rule.id, instanceId: inst.id) {
                    rulesRemoved += 1
                }
            }
        }
        return removed + rulesRemoved
    }

    /// Read-only counterpart of `wipeProvidersForOverwrite` for the preview.
    private func providerDeletionCount(root: URL) async -> Int? {
        guard let config = packageProviderConfig(root: root) else { return nil }
        let local = await MainActor.run { ProviderConfigStore.shared.config }
        let packageInstanceIds = Set(config.instances.map(\.id))
        let packageEntryIds = Set(config.modelEntries.map(\.id))
        let packageGroupIds = Set(config.modelGroups.map(\.id))
        var removed = local.instances.filter { !packageInstanceIds.contains($0.id) }.count
            + local.modelEntries.filter { !packageEntryIds.contains($0.id) }.count
            + local.modelGroups.filter { !packageGroupIds.contains($0.id) }.count
        // Same as above: await the @MainActor async method directly, no
        // MainActor.run wrapper (CI compile error, see wipeProvidersForOverwrite).
        for inst in local.instances {
            removed += await ProviderConfigStore.shared.thinkingRules(for: inst.id).count
        }
        return removed
    }

    // MARK: MCP wipe (count only — the import replaces the whole file)

    /// Local servers the whole-file replace will drop. The file is
    /// `{"mcpServers": {<id>: {...}}}` (see `BackupExporter.mcpServerCount`),
    /// so the ids are the map's keys. Nil when the package carries no
    /// servers file — then the import replaces nothing.
    private func mcpDeletionCount(root: URL) async -> Int? {
        let src = root.appendingPathComponent("data/mcp_servers.json")
        guard FileManager.default.fileExists(atPath: src.path),
              let data = try? Data(contentsOf: src),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return nil }
        let packageIds = Set(servers.keys)
        return await MainActor.run {
            MCPStore.shared.servers.filter { !packageIds.contains($0.id) }.count
        }
    }

    // MARK: Environment variables wipe

    private func packageEnvEntries(root: URL) -> [EnvVarEntry]? {
        let src = root.appendingPathComponent("data/env_vars.json")
        guard let data = try? Data(contentsOf: src) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([EnvVarEntry].self, from: data)
    }

    /// Local entry ids whose key the package does not carry. Nil when the
    /// package carries no env file.
    private func envWipeTargetIDs(root: URL) async -> [String]? {
        guard let incoming = packageEnvEntries(root: root) else { return nil }
        let packageKeys = Set(incoming.map(\.key))
        return await MainActor.run {
            EnvVarStore.shared.entries
                .filter { !packageKeys.contains($0.key) }.map(\.id)
        }
    }

    private func wipeEnvVarsForOverwrite(root: URL) async -> Int {
        guard let ids = await envWipeTargetIDs(root: root), !ids.isEmpty else { return 0 }
        // `EnvVarStore.delete` is the scoped delete: it removes the entry and
        // its Keychain value only when no other entry references that key —
        // never a sweep, never anything outside this key.
        await MainActor.run {
            let store = EnvVarStore.shared
            for id in ids { store.delete(id: id) }
        }
        return ids.count
    }

    // MARK: Scheduled tasks wipe

    private func packageScheduledJobIDs(root: URL) -> Set<String>? {
        let url = root.appendingPathComponent("data/scheduled_tasks.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let jobs = try? decoder.decode([PersistedJob].self, from: data) else { return nil }
        return Set(jobs.map(\.id))
    }

    /// Local job ids the package does not carry. Nil when the package
    /// carries no tasks file.
    private func scheduledWipeTargetIDs(root: URL) async -> [String]? {
        guard let packageIds = packageScheduledJobIDs(root: root) else { return nil }
        return await MainActor.run {
            Array(AgentJobRegistry.shared.jobs.keys.filter { !packageIds.contains($0) })
        }
    }

    private func wipeScheduledTasksForOverwrite(root: URL) async -> Int {
        guard let ids = await scheduledWipeTargetIDs(root: root), !ids.isEmpty else { return 0 }
        // `remove` cancels first (a running job's child run is not left
        // orphaned) and persists, so the deletion sticks across launch.
        // The import then adopts the package's jobs onto the empty registry.
        await MainActor.run {
            let registry = AgentJobRegistry.shared
            for id in ids { registry.remove(jobId: id) }
        }
        return ids.count
    }

    // MARK: - Shared helpers

    /// The directory a category's restored files must stay inside.
    ///
    /// Single source of truth for the containment check below, kept next to it
    /// so a new category cannot be added with a destination mapping but no
    /// bound.
    func containmentRoot(for category: BackupCategory) -> URL {
        switch category {
        case .chats: return AIChatViewModel.minisPersistentBase
        case .sharedFiles: return AIChatViewModel.minisSharedPersistentDir
        case .stickers: return AIChatViewModel.minisStickersPersistentDir
        case .skills: return AIChatViewModel.minisSkillsPersistentDir
        case .memory: return AIChatViewModel.minisMemoryPersistentDir
        case .appearance: return AppearanceStudio.appearanceAssetsDirectory
        case .ishUserData: return RootfsManager.shared.dataPath
        case .providers, .mcpServers, .voiceCorrections, .environmentVariables,
             .scheduledTasks:
            // These write single known files, not index-driven trees; give them
            // the app-group root so the check is still meaningful if one ever
            // starts using restoreFileTree.
            return AIChatViewModel.minisAppGroupRoot
        }
    }

    /// True when `url` really resolves inside `root`.
    ///
    /// Compares STANDARDIZED, SYMLINK-RESOLVED paths and requires a trailing
    /// separator on the prefix, so `/a/b-evil` is not accepted as being inside
    /// `/a/b`.
    ///
    /// The two steps are complementary and both are needed:
    ///   - `standardizedFileURL` is purely lexical — it collapses `.`, `..` and
    ///     redundant separators without touching the filesystem, and explicitly
    ///     does NOT resolve symlinks.
    ///   - `resolvingSymlinksInPath()` is the filesystem half. Without it a
    ///     symlink anywhere in the path (a parent component inside the root, or
    ///     the leaf itself) could point outside `root` while the lexical form
    ///     still looked contained. `minisAppGroupRoot`'s shared/skills/memory
    ///     are exposed to iOS Files via the FileProvider extension, so their
    ///     contents are not solely under this app's control.
    ///
    /// [T-ios-restore-symlink-containment] BOTH sides must be resolved, and
    /// resolving only one is worse than resolving neither. On iOS `/var` is a
    /// symlink to `/private/var`, and the container APIs
    /// (`containerURL(forSecurityApplicationGroupIdentifier:)`,
    /// `urls(for:.documentDirectory)`) hand back the UNRESOLVED `/var/…` form.
    /// Resolve just the target and it becomes `/private/var/…` while the base
    /// stays `/var/…`; the prefix test is then always false and every file in
    /// every category is rejected — i.e. restore silently stops working
    /// entirely. Resolving both keeps them in the same form.
    ///
    /// Note `resolvingSymlinksInPath()` leaves a non-existent trailing
    /// component untouched (it only resolves the portion that exists), so the
    /// normal case — writing a file that is not there yet — is unaffected.
    func isContained(_ url: URL, within root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Write a category's files back out of `blobs/` using the index.
    /// - Parameter containmentRootOverride: the root that destinations must
    ///   stay inside. Defaults to `containmentRoot(for:)`, i.e. the real
    ///   category directory. Two callers pass an explicit root, both
    ///   legitimate: tests exercise the blob-accounting logic against a temp
    ///   directory without weakening the [B1] path-traversal guard, and the
    ///   Appearance category restores avatars into `Application Support/avatars/`
    ///   ([A2]), which is the real category root for that subtree — they live
    ///   beside AppearanceStudio, not inside it, so the default root would
    ///   wrongly reject them. The guard still runs; only the root it enforces
    ///   is injectable, never the check itself.
    func restoreFileTree(root: URL,
                         fileIndex: [BackupFileIndexEntry],
                         category: BackupCategory,
                         containmentRootOverride: URL? = nil,
                         destinationFor: (String) -> URL?,
                         didWrite: ((String) -> Void)? = nil)
        throws -> (written: Int, bytes: Int64, missingBlobs: Int) {
        let fm = FileManager.default
        var written = 0
        var bytes: Int64 = 0
        var rejectedPaths = 0
        var missingBlobs = 0

        for entry in fileIndex where entry.category == category.rawValue {
            // §3.4 tombstones carry no content by design — counted, not written.
            if entry.skipped != nil { continue }
            guard let dest = destinationFor(entry.path) else { continue }

            // [T-ios-backup-restore-path-traversal] `entry.path` comes from
            // files.index.jsonl INSIDE the package, which is attacker-controlled
            // whenever a user restores a file someone sent them — and this
            // feature exists to accept packages from AirDrop / Files / share
            // links. `URL.appendingPathComponent` does not standardize, and
            // `copyItem` lets the kernel resolve `..`, so a path like
            // "chats/<sid>/../../../evil" resolved to <sandbox>/Library/evil
            // and wrote attacker bytes outside the intended directory.
            //
            // Note the ZIP extractor's own traversal guard does NOT cover this:
            // the archive's entry names are all benign (`blobs/<xx>/<sha>`) and
            // the malicious path lives in the index CONTENT.
            //
            // Containment is checked on the standardized path, which is what
            // the filesystem will actually use.
            guard isContained(dest, within: containmentRootOverride ?? containmentRoot(for: category)) else {
                logger.error("[Restore] REJECTED path escaping its category root: \(entry.path)")
                rejectedPaths += 1
                continue
            }

            if entry.isDirectory == true {
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            guard let sha = entry.sha256 else { continue }
            let blob = root.appendingPathComponent("blobs")
                .appendingPathComponent(String(sha.prefix(2)))
                .appendingPathComponent(sha)
            // [review S7] The index says this file is in the package, but its
            // content blob isn't there. The export is not a snapshot: a file
            // written between the index pass and the blob copy can be recorded
            // and then not stored. This used to `continue` silently — the file
            // simply never appeared and the restore still reported success,
            // which is the one outcome a backup tool must never produce.
            // Counted here and surfaced in the report instead.
            guard fm.fileExists(atPath: blob.path) else {
                logger.warning("[Restore] index references a blob that is not in the package: \(entry.path) sha=\(sha.prefix(12))")
                missingBlobs += 1
                continue
            }

            try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            // Declared before the do block so its catch can clean the staged
            // temp up on failure (same shape as importMemory above); a
            // declaration inside do is invisible to the catch clause.
            let staged = dest.deletingLastPathComponent()
                .appendingPathComponent(".restore-\(UUID().uuidString).tmp")
            do {
                // [review I2] Stage next to the destination and swap, rather
                // than removeItem-then-copyItem. That pair left the user's file
                // NON-EXISTENT for the whole duration of the copy, so a jetsam
                // kill or crash in that window deleted it permanently with
                // nothing written back. The window was entered once per file,
                // and `.chats` / `.skills` / `.voiceCorrections` take no
                // rollback snapshot (snapshotForRollback excludes them so a
                // merge doesn't have to copy gigabytes aside), so for those
                // categories launch reconcile had nothing to restore and the
                // deletion was simply final. Merge idempotency does not help a
                // file that was deleted and never rewritten.
                try? fm.removeItem(at: staged)
                try fm.copyItem(at: blob, to: staged)
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: dest)
                }
                written += 1
                bytes += entry.size
                // [AUD3-01] Let the caller know a file actually landed. The
                // chats caller turns each one into a SessionFile dirty record —
                // without it a restored media file looks "never changed" to
                // iCloud and is not pushed to the user's other devices.
                didWrite?(entry.path)
            } catch {
                // Remove the staged temp: nothing else ever sweeps
                // `.restore-*.tmp`, so a failed copy/swap orphaned it next
                // to the destination and repeated failures accumulated
                // dead copies in the user's data directories. (importMemory's
                // identical staging above already cleans up in its catch.)
                try? fm.removeItem(at: staged)
                logger.warning("[Restore] write failed \(entry.path): \(error.localizedDescription)")
            }
        }
        if rejectedPaths > 0 {
            logger.error("[Restore] \(rejectedPaths) path(s) in \(category.rawValue) were rejected for escaping their root")
        }
        if missingBlobs > 0 {
            logger.error("[Restore] \(category.rawValue): \(missingBlobs) file(s) referenced by the index are MISSING from the package")
        }
        return (written, bytes, missingBlobs)
    }

    /// Read every shard of a JSONL stream, unwrapping the `t`/`v`/`d` envelope.
    func readJSONL<T: Codable>(_ dir: URL, base: String, as type: T.Type) -> [T] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0 == "\(base).jsonl" || ($0.hasPrefix("\(base)-") && $0.hasSuffix(".jsonl")) }
            .sorted()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [T] = []
        for name in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                // Per-line tolerance (§2.2 rule 3): a record this build cannot
                // parse is skipped, and the rest of the file still imports.
                if let env = try? decoder.decode(BackupRecordEnvelope<T>.self, from: Data(line)) {
                    out.append(env.d)
                }
            }
        }
        return out
    }

    private func encodeParts(_ parts: [ContentPart]) -> String? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let d = try? e.encode(parts) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func encodeTokenUsage(_ usage: StoredTokenUsage?) -> String? {
        guard let usage else { return nil }
        let e = JSONEncoder()
        guard let d = try? e.encode(usage) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    // MARK: - Store reloads (§8.1)

    func reloadStores(for categories: Set<BackupCategory>) async {
        if categories.contains(.skills) {
            await MainActor.run { SkillStore.shared.reload() }
        }
        if categories.contains(.appearance) {
            // Covers packages whose appearance half is files only (no
            // settings file): the live studio must still drop its cached
            // wallpapers and re-read the icons the restore just wrote.
            await MainActor.run { AppearanceStudio.shared.reloadAfterRestore() }
        }
        if categories.contains(.chats) {
            // One batch signal is enough to refresh everything chat-related.
            await MainActor.run {
                NotificationCenter.default.post(name: .localStoresDidChange, object: nil)
            }
        }
    }
}
