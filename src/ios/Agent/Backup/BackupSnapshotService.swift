import Foundation

/// [第20条 · 快照半边] Automatic on-device snapshots — REMOVED
/// 2026-11-13, user decision: NO automatic backups, manual backup only.
/// The app used to take a snapshot by itself shortly after launch and on
/// returning to the foreground, keeping up to 9 full packages in the
/// Backups folder; on a multi-GB install that is what grew the app to
/// 10+ GB. The triggers are gone (see `scheduleLaunchCheck` /
/// `scheduleForegroundCheck` below) and the default is OFF, so no new
/// automatic snapshot is ever taken.
///
/// What stays: this service still LISTS the snapshots already on disk
/// (`listSnapshots`, used by the restore view and the settings footprint),
/// and existing snapshot files are NEVER deleted by turning this off —
/// the user deletes them herself, from Files or from the restore screen.
/// The Fix 2 overwrite safety copy (`pre-overwrite-*.minisbak`, taken by
/// `BackupImporter.takeSafetySnapshot`) is NOT an automatic snapshot: it
/// is a one-off copy made only when the user explicitly chooses an
/// overwrite restore, and it is untouched by this change.
@MainActor
final class BackupSnapshotService {
    static let shared = BackupSnapshotService()

    /// Package-name prefix marking a delivered package as a snapshot.
    /// Cosmetic only — retention never trusts the name alone (a hand-made
    /// backup can be named `snapshot-…` by its device name or by renaming),
    /// it only ever touches names recorded in the snapshot manifest below.
    static let filePrefix = "snapshot-"

    /// Name of the snapshot ledger kept next to the packages.
    /// `listSnapshots` only recognises files whose names are in here AND
    /// exist on disk; retention only deletes ledger entries. A hand-made
    /// backup is never in the ledger, so it can never be pruned — even when
    /// its filename starts with `snapshot-`.
    private static let manifestFileName = "snapshot-manifest.json"

    /// [2026-11-13] User decision: no automatic backups, manual only.
    /// Default OFF (was ON). The settings toggle is gone, so nothing in
    /// the app can turn this back on; the key is kept so an explicit
    /// `true` written by an older build is still honoured by the guard
    /// in `scheduleCheck`, but no trigger ever reaches it.
    nonisolated static let automaticSnapshotsEnabledKey = "backup.automaticSnapshots"

    /// Whether the launch / foreground freshness checks may take
    /// snapshots. `nonisolated`: UserDefaults is thread-safe, and the
    /// settings UI reads this outside the service's actor.
    nonisolated static var isAutomaticSnapshotEnabled: Bool {
        get { UserDefaults.standard.object(forKey: automaticSnapshotsEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: automaticSnapshotsEnabledKey) }
    }

    private init() {}

    // MARK: - Triggers (removed 2026-11-13)

    /// Called once the app has launched and settled.
    ///
    /// No-op since 2026-11-13 (user decision: no automatic backups).
    /// Kept as API so no call site needs a matching edit; the launch
    /// call in MinisApp is removed, and this does nothing even if called.
    func scheduleLaunchCheck() {}

    /// Called when the app returns to the foreground.
    ///
    /// No-op since 2026-11-13, same as `scheduleLaunchCheck`.
    func scheduleForegroundCheck() {}

    // MARK: - Decision (pure, so the shape can be reviewed without a device)

    struct SnapshotFile {
        let url: URL
        let date: Date
        let bytes: Int64
    }

    /// Snapshots in `dir`, newest first. A file counts as a snapshot only if
    /// its name is recorded in the snapshot manifest (written when the
    /// service itself creates the package) AND the file still exists — the
    /// filename prefix alone is forgeable and is never trusted on the
    /// normal path.
    ///
    /// [P3-10] A missing or unreadable manifest used to mean zero
    /// recognised snapshots: old snapshot files silently stopped being
    /// listed AND pruned, so they piled up forever with no way for the
    /// user to see or delete them. That case now falls back to the
    /// `snapshot-` filename prefix (snapshot packages are `.minisbak`
    /// files renamed with that prefix at creation time, so the scan finds
    /// exactly the files this service made), and anything found is
    /// re-registered into a rebuilt manifest — back on the trusted ledger
    /// path from here on. A manifest that EXISTS but is empty still means
    /// "no snapshots": an explicit empty ledger is not a lost one.
    static func listSnapshots(in dir: URL) -> [SnapshotFile] {
        let fm = FileManager.default
        let names: Set<String>
        if let ledger = manifestNamesIfPresent(in: dir) {
            names = Set(ledger)
        } else {
            let recovered = snapshotNamesByPrefix(in: dir)
            if !recovered.isEmpty {
                writeManifest(recovered, in: dir)
            }
            names = Set(recovered)
        }
        guard !names.isEmpty else { return [] }
        var out: [SnapshotFile] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let date = attrs?[.modificationDate] as? Date
                ?? attrs?[.creationDate] as? Date ?? .distantPast
            let bytes = attrs?[.size] as? Int64 ?? 0
            out.append(SnapshotFile(url: url, date: date, bytes: bytes))
        }
        return out.sorted { $0.date > $1.date }
    }

    // MARK: - Snapshot ledger

    private static func manifestURL(in dir: URL) -> URL {
        dir.appendingPathComponent(manifestFileName)
    }

    private static func manifestNames(in dir: URL) -> [String] {
        guard let data = try? Data(contentsOf: manifestURL(in: dir)),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }

    /// [P3-10] The ledger, or nil when it is missing / unreadable / corrupt —
    /// deliberately distinct from "present but empty", which is a valid
    /// state meaning no snapshots are tracked. Only the nil case takes the
    /// filename-prefix fallback in `listSnapshots`.
    private static func manifestNamesIfPresent(in dir: URL) -> [String]? {
        let url = manifestURL(in: dir)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return names
    }

    /// [P3-10] Filename-prefix fallback, used ONLY when the manifest is
    /// gone: snapshot packages are `.minisbak` files renamed with the
    /// `snapshot-` prefix at creation time, so this scan finds exactly the
    /// files this service made. (A hand-made backup deliberately renamed
    /// to `snapshot-….minisbak` would also match — acceptable: the user
    /// chose that name, retention only ever deletes per policy, and the
    /// alternative is invisible, undeletable piles.)
    private static func snapshotNamesByPrefix(in dir: URL) -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return urls.map(\.lastPathComponent)
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".minisbak") }
    }

    private static func writeManifest(_ names: [String], in dir: URL) {
        guard let data = try? JSONEncoder().encode(names.sorted()) else { return }
        try? data.write(to: manifestURL(in: dir), options: .atomic)
    }

    /// Record a freshly created snapshot. Called exactly once per package,
    /// after the move into `dir` succeeded.
    static func registerSnapshot(named name: String, in dir: URL) {
        var names = Set(manifestNames(in: dir))
        names.insert(name)
        writeManifest(Array(names), in: dir)
    }

    /// Drop ledger entries for packages retention deleted (or that are gone
    /// for any other reason), so the manifest never references dead files.
    static func unregisterSnapshots(named names: Set<String>, in dir: URL) {
        let remaining = Set(manifestNames(in: dir)).subtracting(names)
        writeManifest(Array(remaining), in: dir)
    }

    /// How old the newest snapshot may get before another is due, scaled
    /// by how big the last one was.
    static func minimumInterval(forSnapshotBytes bytes: Int64) -> TimeInterval {
        let mb: Int64 = 1024 * 1024
        switch bytes {
        case ..<(200 * mb): return 24 * 3600
        case ..<(1024 * mb): return 48 * 3600
        default: return 72 * 3600
        }
    }

    static func isDue(now: Date, snapshots: [SnapshotFile]) -> Bool {
        guard let newest = snapshots.first else { return true }
        return now.timeIntervalSince(newest.date)
            >= minimumInterval(forSnapshotBytes: newest.bytes)
    }

    /// Retention: the newest 7 snapshots stay. Beyond that batch, one
    /// weekly keeper (the newest remaining snapshot at least 7 days old)
    /// and one monthly keeper (the newest remaining at least 30 days
    /// old) survive; every other snapshot is deleted. The keepers are
    /// picked from OUTSIDE the batch — if the batch itself already
    /// reaches back 7 days, the weekly slot still goes to the next one
    /// out, so the long tail doesn't thin out. At most 9 packages ever
    /// accumulate.
    ///
    /// Kept for reference / tests: nothing in the app takes automatic
    /// snapshots anymore (2026-11-13), so nothing calls this.
    static func retentionDeletions(_ snapshots: [SnapshotFile], now: Date) -> [URL] {
        var keep = Set<URL>()
        for s in snapshots.prefix(7) { keep.insert(s.url) }
        let day: TimeInterval = 24 * 3600
        if let weekly = snapshots.first(where: {
            !keep.contains($0.url) && now.timeIntervalSince($0.date) >= 7 * day
        }) {
            keep.insert(weekly.url)
        }
        if let monthly = snapshots.first(where: {
            !keep.contains($0.url) && now.timeIntervalSince($0.date) >= 30 * day
        }) {
            keep.insert(monthly.url)
        }
        return snapshots.filter { !keep.contains($0.url) }.map(\.url)
    }
}
