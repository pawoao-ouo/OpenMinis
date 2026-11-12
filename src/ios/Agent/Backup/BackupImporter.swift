import Foundation

private let logger = AppLogger(category: "Backup")

/// Restores a `.minisbak` package (docs/backup-restore-design.md §8).
///
/// Stage 2 scope: **Merge mode only**, unencrypted packages, with integrity
/// verification, preflight, and a staging rollback point. Replace / Skip
/// existing are stage 5; credential restore is stage 3.
///
/// Flow (§8.1):
///   read manifest → integrity check → preflight → staging snapshot →
///   per-category import → store reloads → report
/// A failure inside a category rolls that category back from the snapshot; the
/// categories that already succeeded are kept (§8.3's transaction boundary).
actor BackupImporter {

    struct Options {
        /// nil = every category present in the package.
        var categories: Set<BackupCategory>?
        /// Fix 2 — Merge (default) or Overwrite. Overwrite deletes local
        /// items in the selected categories that the package does not carry,
        /// after a mandatory safety snapshot; merge never deletes anything.
        var mode: RestoreMode = .merge
        /// Skip the integrity pass. Only for diagnostics — normal restores must
        /// verify, since a truncated package would otherwise be applied
        /// half-way before anything noticed.
        var skipIntegrityCheck = false
        /// §8.2's "keep both" option for session id collisions.
        var duplicateSessionsInsteadOfMerging = false
        /// Required when the package declares `encryption`; ignored otherwise.
        var passphrase: String?
    }

    struct CategoryReport {
        var category: String
        var imported = 0
        var updated = 0
        var skipped = 0
        var unreadable = 0
        var filesWritten = 0
        var bytesWritten: Int64 = 0
        /// §3.4 tombstones found in the package: the export excluded these, so
        /// the restore surfaces them rather than pretending the files exist.
        var sizeSkippedInPackage = 0
        /// [review S9] Tombstones for files that were in iCloud and not on the
        /// exporting device. Distinct from the size cap because the remedy is
        /// different: download the files and back up again.
        var notDownloadedInPackage = 0
        /// [review S7] Index entries whose content blob is MISSING from the
        /// package — the export was not a snapshot, so a file added between the
        /// index write and the blob copy can be referenced but absent.
        ///
        /// Previously a silent `continue`: the file just didn't appear and the
        /// restore still reported success. Counted and surfaced now, because
        /// "your backup was incomplete" is something the user must be told
        /// while they still have the source device.
        var missingBlobs = 0
        /// Providers whose Keychain credentials were written back (§5.4).
        var credentialsRestored = 0
        /// Credentials left alone because a local one already exists — an old
        /// backup must not clobber a key the user has since rotated.
        var credentialsKept = 0
        /// Credentials present in the package that could not be decoded and
        /// were NOT restored. Kept distinct from `credentialsKept`: reporting
        /// these as "kept" claims a credential survived that never arrived.
        var credentialsUndecodable = 0
        /// Fix 2 — local items an overwrite wipe deleted in this category
        /// (0 in merge mode, where nothing is ever deleted).
        var deleted = 0
        var failed: String?
    }

    struct Report {
        var backupId: String
        var createdAt: Date?
        var sourcePlatform: String?
        var categories: [CategoryReport] = []
        var integrityChecked = 0
        var integrityFailed: [String] = []
        var rolledBack: [String] = []
        var wasEncrypted = false
        var warnings: [String] = []
        var duration: TimeInterval = 0
        /// Fix 2 — the safety copy taken before an overwrite wipe, if any.
        /// Lives in `BackupDelivery.backupsDirectory` as
        /// `pre-overwrite-<timestamp>.minisbak`; nil in merge mode.
        var safetySnapshotURL: URL?

        var totalImported: Int { categories.reduce(0) { $0 + $1.imported } }
        var totalUpdated: Int { categories.reduce(0) { $0 + $1.updated } }
        var totalSkipped: Int { categories.reduce(0) { $0 + $1.skipped } }
        var totalUnreadable: Int { categories.reduce(0) { $0 + $1.unreadable } }
    }

    enum ImportError: LocalizedError {
        case unreadablePackage(String)
        case missingManifest
        case incompatibleFormat(found: String, supported: String)
        case integrityFailed([String])
        case insufficientDiskSpace(needed: Int64, available: Int64)
        case sessionsRunning([String])
        case passphraseRequired
        /// Fix 2 — the mandatory safety snapshot could not be taken, so an
        /// overwrite restore is refused outright. Nothing was deleted: the
        /// snapshot runs before any wipe.
        case safetySnapshotFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadablePackage(let m): return "Cannot read backup package: \(m)"
            case .missingManifest: return "Package has no manifest.json"
            case .incompatibleFormat(let f, let s):
                // §2.2 rule 1: refuse rather than best-effort parse.
                return "This backup was written in format \(f); this app supports \(s). Please update the app."
            case .integrityFailed(let paths):
                return "Integrity check failed for \(paths.count) file(s): \(paths.prefix(3).joined(separator: ", "))"
            case .insufficientDiskSpace(let need, let have):
                return "Not enough free space: needs ~\(need / 1_000_000)MB, \(have / 1_000_000)MB available"
            case .sessionsRunning(let ids):
                return "\(ids.count) session(s) are currently running. Stop them before restoring."
            case .safetySnapshotFailed(let m):
                return "Could not take a safety copy of your current data (\(m)). Overwrite restore refused — nothing was deleted."
            case .passphraseRequired:
                return "This backup is encrypted. Enter its passphrase to restore."
            }
        }
    }

    private let fm = FileManager.default

    // MARK: - Entry point

    /// [review I3] Serialised process-wide. Two concurrent restores share
    /// mutable destinations (the same session directories, the same provider
    /// config), so overlapping them corrupts state no rollback can describe.
    func `import`(from packageURL: URL,
                  options: Options = Options(),
                  progress: (@Sendable (String) -> Void)? = nil) async throws -> Report {
        try await BackupActivityLock.shared.withLock(.restore) {
            try await importBody(from: packageURL, options: options, progress: progress)
        }
    }

    private func importBody(from packageURL: URL,
                            options: Options,
                            progress: (@Sendable (String) -> Void)?) async throws -> Report {
        let started = Date()

        // Unpack to a working directory. The package must be expanded before
        // anything is applied — a half-applied restore from a corrupt archive
        // is the worst possible outcome.
        progress?("Opening package…")
        let work = fm.temporaryDirectory
            .appendingPathComponent("minisbak-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let root = try unpack(packageURL, to: work)

        progress?("Reading manifest…")
        let manifest = try readManifest(at: root)
        try checkFormat(manifest)

        var report = Report(backupId: manifest.backupId,
                            createdAt: manifest.createdAt,
                            sourcePlatform: manifest.app.platform)

        // Order matters and follows §8.1 exactly:
        //   integrity (no passphrase needed — hashes are of the ciphertext)
        //   → verifier (is the passphrase right? instant, touches no payload)
        //   → manifest MAC → decrypt.
        // Checking integrity first means a truncated package is rejected before
        // the user is even asked for a passphrase.
        if !options.skipIntegrityCheck {
            progress?("Verifying integrity…")
            let (checked, failed) = verifyIntegrity(manifest: manifest, root: root)
            report.integrityChecked = checked
            report.integrityFailed = failed
            guard failed.isEmpty else { throw ImportError.integrityFailed(failed) }
        }

        if let encryption = manifest.encryption {
            progress?("Decrypting…")
            guard encryption.scheme == BackupCrypto.scheme else {
                throw BackupCrypto.CryptoError.unsupportedScheme(encryption.scheme)
            }
            guard let passphrase = options.passphrase, !passphrase.isEmpty else {
                throw ImportError.passphraseRequired
            }
            let keys = try BackupCrypto.deriveKeys(passphrase: passphrase, kdf: encryption.kdf)
            guard BackupCrypto.verifierMatches(encryption.verifier, keys: keys) else {
                throw BackupCrypto.CryptoError.wrongPassphrase
            }
            // Only meaningful once the passphrase is known good — otherwise a
            // MAC mismatch would just be the wrong key and the error would
            // misdirect the user toward "tampered" instead of "wrong password".
            //
            // Prefer the raw-bytes sidecar (`manifest.mac`): it authenticates
            // manifest.json exactly as written, so a manifest with fields this
            // build doesn't know about still verifies. The struct-based MAC is
            // the fallback for packages that predate the sidecar.
            let sidecarURL = root.appendingPathComponent("manifest.mac")
            if let expected = try? String(contentsOf: sidecarURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !expected.isEmpty,
               let raw = try? Data(contentsOf: root.appendingPathComponent("manifest.json")) {
                try BackupCrypto.verifyManifestMAC(rawBytes: raw, expected: expected,
                                                   key: keys.macKey)
            } else {
                try BackupCrypto.verifyManifestMAC(manifest, key: keys.macKey)
            }
            try decryptStagedMembers(in: root, keys: keys)
            report.wasEncrypted = true
        }

        // [review S4] Downgrade guard. Stripping the `encryption` block from the
        // plaintext manifest used to make the importer skip decryption
        // entirely; the members stayed `.enc`, readJSONL matched nothing, and
        // every category reported 0 imported with NO error — a silent empty
        // restore the user would read as success. If encrypted members are
        // present, the manifest must say so.
        if manifest.encryption == nil, hasEncryptedMembers(in: root) {
            throw ImportError.unreadablePackage(
                "This package contains encrypted content but its manifest declares none — it may have been modified.")
        }

        // `wanted` is resolved before preflight: the overwrite running-session
        // check needs to know whether chats is selected.
        let wanted = options.categories
            ?? Set(manifest.categories.keys.compactMap(BackupCategory.init(rawValue:)))

        progress?("Preflight…")
        try await preflight(manifest: manifest, options: options, wanted: wanted)

        // Index the package's file tree once; every file-carrying category
        // filters this rather than re-reading the index per category.
        let fileIndex = readFileIndex(at: root)

        // Fix 2 — MANDATORY pre-step for overwrite, before ANY wipe: a full
        // current-state export (same shape as
        // `BackupSnapshotService.takeSnapshot` — every backupable category,
        // no credentials, unencrypted) into the delivered-packages folder as
        // `pre-overwrite-<timestamp>.minisbak`, keeping the last 1. If it
        // fails, the restore is refused outright — nothing is deleted.
        //
        // The snapshot is deliberately NOT registered in the snapshot ledger:
        // it is a safety copy, not an automatic snapshot, so snapshot
        // retention must never prune it and it must never be offered as a
        // snapshot. Its name does not carry the `snapshot-` prefix either.
        if options.mode == .overwrite {
            progress?("Taking a safety copy…")
            report.safetySnapshotURL = try await takeSafetySnapshot()
        }

        // [T-ios-backup-rollback-persistence] The rollback snapshot must NOT
        // live under `work`, which the `defer` above deletes: on the one
        // failure it exists for — the app being killed or jetsammed mid-restore
        // (this copies GB on a device with a documented jetsam history) — the
        // snapshot would be either deleted or orphaned in a purgeable tmp,
        // while the live directories sit half-overwritten with no recovery
        // path. Application Support is persistent and not purged.
        // [review I3] Per-run staging id, so two overlapping restores cannot
        // delete each other's rollback snapshots.
        let runId = UUID().uuidString.prefix(8).lowercased()
        let staging = BackupRestoreJournal.stagingRoot(runId: String(runId))
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        BackupRestoreJournal.begin(backupId: manifest.backupId,
                                   categories: orderedCategories(wanted).map(\.rawValue),
                                   mode: options.mode.rawValue,
                                   safetySnapshotURL: report.safetySnapshotURL)
        // Cleared only on a clean finish; if the process dies first the marker
        // survives and the next launch reconciles.
        defer { BackupRestoreJournal.finish(runId: String(runId)) }

        // Order matters: sessions must exist before messages/markers reference
        // them, so chats runs as one unit internally.
        for category in orderedCategories(wanted) {
            progress?("Restoring \(category.rawValue)…")
            var snapshot: BackupRollbackSnapshot?
            // Fix 2 — the wipe runs AFTER the rollback snapshot for this
            // category (so a file-backed category can still roll back) and
            // BEFORE that category's import. Only the selected categories are
            // ever wiped, and only inside their containment roots.
            var deleted = 0
            do {
                snapshot = try snapshotForRollback(category: category, staging: staging)
                if options.mode == .overwrite {
                    deleted = try await wipeCategoryForOverwrite(category, root: root,
                                                                 fileIndex: fileIndex)
                }
                var cat = try await importCategory(category, root: root, fileIndex: fileIndex,
                                                   options: options)
                cat.deleted = deleted
                cat.sizeSkippedInPackage = fileIndex
                    .filter { $0.category == category.rawValue && $0.skipped == "size" }.count
                // [review S9] Same treatment for iCloud placeholders the export
                // could not materialise — the content is missing either way, and
                // the user needs to know which files before they wipe the old
                // device.
                cat.notDownloadedInPackage = fileIndex
                    .filter { $0.category == category.rawValue && $0.skipped == "not_downloaded" }.count
                report.categories.append(cat)
            } catch {
                logger.error("[Restore] category \(category.rawValue) failed: \(error.localizedDescription)")
                var cat = CategoryReport(category: category.rawValue)
                cat.failed = error.localizedDescription
                // The wipe (if it ran) already deleted local items before the
                // import failed — report that rather than hiding it.
                cat.deleted = deleted
                report.categories.append(cat)
                // Only claim a rollback when the snapshot actually held
                // something to restore. Categories without a snapshot
                // (chats, skills, environment variables, …) fail before or
                // without writing, and reporting "Rolled back" for the
                // no-op would tell the user an undo happened that didn't.
                if let snapshot, !snapshot.isEmpty, (try? rollback(snapshot)) != nil {
                    report.rolledBack.append(category.rawValue)
                }
                // §8.3: a failed category does not abort the ones already done.
                continue
            }
        }

        progress?("Reloading stores…")
        await reloadStores(for: wanted)

        report.duration = Date().timeIntervalSince(started)
        logger.info("[Restore] done id=\(manifest.backupId) imported=\(report.totalImported) updated=\(report.totalUpdated) skipped=\(report.totalSkipped)")
        return report
    }

    /// Read a package's manifest without importing — powers the "show the user
    /// what's in here before they commit" step of §8.1.
    func inspect(packageURL: URL) throws -> BackupManifest {
        let work = fm.temporaryDirectory
            .appendingPathComponent("minisbak-peek-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let root = try unpack(packageURL, to: work)
        return try readManifest(at: root)
    }

    // MARK: - Package opening

    /// Expand the ZIP. Uses the same NSFileCoordinator trick as the exporter in
    /// reverse; the archive nests everything under `minisbak-<uuid>/`, so the
    /// real root is that single child directory.
    private func unpack(_ packageURL: URL, to work: URL) throws -> URL {
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let dest = work.appendingPathComponent("unpacked", isDirectory: true)

        do {
            try BackupZipExtractor.extract(packageURL, to: dest)
        } catch {
            throw ImportError.unreadablePackage(error.localizedDescription)
        }

        // Descend through the single wrapper directory if present.
        let children = (try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: [.isDirectoryKey]))
            ?? []
        if children.count == 1,
           (try? children[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
           fm.fileExists(atPath: children[0].appendingPathComponent("manifest.json").path) {
            return children[0]
        }
        return dest
    }

    /// Decrypt every `.enc` member in place, restoring its original name, so
    /// the rest of the importer works on plaintext exactly as it does for an
    /// unencrypted package (§5.3).
    private func decryptStagedMembers(in root: URL, keys: BackupCrypto.Keys) throws {
        var members: [URL] = []
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in e where url.pathExtension == "enc" {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                members.append(url)
            }
        }
        for url in members {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            let plain = url.deletingPathExtension()
            let isSecrets = plain.lastPathComponent == "secrets.json"
            // The AAD the exporter used is the shipped name (with `.enc`), so
            // it must be reproduced exactly or every segment fails to open.
            try BackupCrypto.decryptFile(at: url, to: plain,
                                         key: isSecrets ? keys.secretsKey : keys.dataKey,
                                         path: rel)
            try fm.removeItem(at: url)
        }
        logger.info("[Restore] decrypted \(members.count) member(s)")
    }

    /// True when any `.enc` member is present on disk.
    private func hasEncryptedMembers(in root: URL) -> Bool {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return false }
        for case let url as URL in e where url.pathExtension == "enc" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                return true
            }
        }
        return false
    }

    private func readManifest(at root: URL) throws -> BackupManifest {
        let url = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { throw ImportError.missingManifest }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(BackupManifest.self, from: data)
        } catch {
            throw ImportError.unreadablePackage("manifest.json is not valid: \(error.localizedDescription)")
        }
    }

    /// §2.2 rule 1 — major version mismatch is a hard refusal.
    ///
    /// [review S3] The previous implementation took everything after the "/",
    /// which is not the major version and got both directions wrong: it
    /// ACCEPTED `otherformat/1` and a bare `1` (no prefix check at all), and
    /// REFUSED `minisbak/1.1` even though §2.2 rule 2 says same-major must
    /// import. Verified both by execution.
    private func checkFormat(_ manifest: BackupManifest) throws {
        guard Self.isFormatSupported(manifest.format) else {
            throw ImportError.incompatibleFormat(found: manifest.format,
                                                 supported: BackupFormat.current)
        }
    }

    /// The pure decision behind `checkFormat`, factored out so it can be tested
    /// directly (the actor method needs a whole package to reach). Callers get
    /// exactly the logic the importer runs — not a re-implementation that could
    /// drift away from it and stop catching regressions.
    static func isFormatSupported(_ format: String) -> Bool {
        func parse(_ s: String) -> (prefix: String, major: Int)? {
            let parts = s.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let majorText = parts[1].split(separator: ".").first.map(String.init) ?? ""
            guard let major = Int(majorText) else { return nil }
            return (String(parts[0]), major)
        }
        guard let found = parse(format), let supported = parse(BackupFormat.current),
              found.prefix == supported.prefix, found.major == supported.major else {
            return false
        }
        return true
    }

    // MARK: - Integrity (§8.1)

    /// Streaming SHA-256 of every packaged file against `manifest.integrity`.
    ///
    /// Runs BEFORE any write, so a truncated or tampered package is rejected
    /// while the device is still untouched.
    private func verifyIntegrity(manifest: BackupManifest, root: URL) -> (Int, [String]) {
        var checked = 0
        var failed: [String] = []
        for (rel, expected) in manifest.integrity {
            let url = root.appendingPathComponent(rel)
            guard fm.fileExists(atPath: url.path) else {
                failed.append(rel)
                continue
            }
            guard let actual = try? BackupBlobStore.sha256OfFile(at: url) else {
                failed.append(rel)
                continue
            }
            checked += 1
            if actual != expected { failed.append(rel) }
        }
        return (checked, failed)
    }

    // MARK: - Preflight (§8.1)

    private func preflight(manifest: BackupManifest, options: Options,
                           wanted: Set<BackupCategory>) async throws {
        // Disk space: the design calls this out because Chats and Shared Files
        // can be GB-scale. Require the package's declared size plus 20% for the
        // unpack + staging copies.
        let needed = Int64(Double(manifest.categories.values.reduce(0) { $0 + $1.bytes }) * 1.2)
        if needed > 0 {
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let free = (try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? Int64.max
            if free < needed {
                throw ImportError.insufficientDiskSpace(needed: needed, available: free)
            }
        }

        // Fix 2 — overwrite refuses while any selected session is running. A
        // running agent loop owns its message list and its timers; wiping its
        // session out from under it would scramble sort order and strand the
        // run. Checked here (before the safety snapshot, so a doomed run does
        // not pay for a full export first) and re-checked in the chats wipe
        // itself, in case a run starts between the two.
        if options.mode == .overwrite, wanted.contains(.chats) {
            let store = ChatStore.shared
            let running = await store.allSessionIds()
                .filter { store.isSessionRunning($0) }
            guard running.isEmpty else { throw ImportError.sessionsRunning(running) }
        }
    }

    // MARK: - Safety snapshot (Fix 2)

    /// Full current-state export, same shape as
    /// `BackupSnapshotService.takeSnapshot`: every backupable category, no
    /// credentials, unencrypted. Runs through the exporter under the restore
    /// lock (see `BackupExporter.exportUnderRestoreLock` — the public entry
    /// would refuse, because this restore already holds the lock).
    ///
    /// Delivered into `BackupDelivery.backupsDirectory` as
    /// `pre-overwrite-<timestamp>.minisbak`, keeping the last 1. Throws
    /// `ImportError.safetySnapshotFailed` on any failure — the caller refuses
    /// the overwrite rather than proceeding without a safety copy.
    private func takeSafetySnapshot() async throws -> URL {
        let options = BackupExporter.Options(
            categories: Set(BackupCategory.backupable),
            maxFileBytes: nil,
            includeCredentials: false,
            passphrase: nil,
            allowResume: false)
        let summary: BackupExporter.Summary
        do {
            summary = try await BackupExporter().exportUnderRestoreLock(options: options)
        } catch {
            throw ImportError.safetySnapshotFailed(error.localizedDescription)
        }
        let dir = BackupDelivery.backupsDirectory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(
                "pre-overwrite-\(Self.safetySnapshotTimestamp(Date())).\(BackupFormat.fileExtension)")
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: summary.packageURL, to: dest)
            // Keep last 1: older safety copies go. Only names with our exact
            // prefix are ever touched — a hand-made backup is never deleted,
            // even if it happens to sit in the same folder.
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names
            where name.hasPrefix("pre-overwrite-")
               && name.hasSuffix(".\(BackupFormat.fileExtension)")
               && name != dest.lastPathComponent {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
            logger.info("[Restore] safety snapshot written: \(dest.lastPathComponent)")
            return dest
        } catch {
            throw ImportError.safetySnapshotFailed(error.localizedDescription)
        }
    }

    private static func safetySnapshotTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    // MARK: - Overwrite preview (Fix 2)

    /// Counts, per category, how many local items an overwrite restore of
    /// this package would delete. Read-only: it shares the wipe's
    /// "local-but-not-in-the-package" sets without deleting anything, so the
    /// numbers the mode picker shows are the numbers the wipe will act on.
    ///
    /// Categories that cannot be counted (or are never wiped, like Voice
    /// Corrections, which is merge-only) return no entry.
    func overwritePreview(packageURL: URL,
                          categories: Set<BackupCategory>) async -> [BackupCategory: Int] {
        let work = fm.temporaryDirectory
            .appendingPathComponent("minisbak-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        guard let root = try? unpack(packageURL, to: work) else { return [:] }
        let fileIndex = readFileIndex(at: root)
        var out: [BackupCategory: Int] = [:]
        for category in orderedCategories(categories) {
            if let n = await overwriteDeletionCount(category, root: root, fileIndex: fileIndex) {
                out[category] = n
            }
        }
        return out
    }

    private func orderedCategories(_ wanted: Set<BackupCategory>) -> [BackupCategory] {
        // Deterministic order; chats first so its (larger) work fails fast if
        // it is going to fail at all.
        // Environment variables come AFTER providers on purpose: providers is
        // where secrets.json is applied, and that is what puts env-var values
        // into the Keychain. Running it first would create every entry with an
        // empty value even though the package carried one.
        //
        // A category missing from this list is silently skipped, which is how
        // this one would have failed had it simply been appended to the enum.
        let order: [BackupCategory] = [.chats, .sharedFiles, .skills, .memory,
                                       .providers, .environmentVariables,
                                       .mcpServers, .voiceCorrections, .appearance,
                                       .stickers, .scheduledTasks]
        return order.filter { wanted.contains($0) }
    }
}
