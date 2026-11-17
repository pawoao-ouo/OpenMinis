import Foundation

private let logger = AppLogger(category: "Backup")

/// Backup delivery to configured rclone remotes (SMB / WebDAV / S3 / …).
///
/// Mount External Folders was removed, so the mounted-folder destination
/// type is gone: delivery goes to rclone remotes only. The local copy in
/// Minis ▸ Backups is written before this runs and is never affected by
/// what happens here.
@MainActor
enum BackupDestinations {

    /// Outcome of delivering one package to one destination.
    struct DeliveryResult: Identifiable {
        let id: UUID
        let folderName: String
        let destination: URL?
        let error: String?
        /// [T-backup-destination-detail] Backend tag (`smb`, `webdav`, …) and
        /// the remote folder, carried through so the history row can show
        /// WHERE the package landed.
        var kind: String? = nil
        var remotePath: String? = nil
        /// [A18] Whether the delivered copy's CONTENTS were verified, not
        /// just its arrival. Rclone uploads are only known not to have
        /// thrown, so they stay false. The local copy is removed only when
        /// every destination is content-verified.
        var contentVerified: Bool = false
        var succeeded: Bool { destination != nil }
    }

    /// Deliver `packageURL` to every configured rclone remote.
    ///
    /// Each remote is independent: a failure is recorded and the loop
    /// continues. A backup that reached 2 of 3 places is a meaningfully
    /// different outcome from one that reached none, and the user has to be
    /// able to tell them apart — an unreachable SMB share is the expected
    /// steady state for a laptop that is asleep, not an error worth aborting
    /// the whole delivery over.
    static func deliver(packageURL: URL, backupId: String = "") async -> [DeliveryResult] {
        await deliverToRemotes(packageURL: packageURL, backupId: backupId)
    }

    /// Upload to every configured rclone remote, chunked and resumable.
    private static func deliverToRemotes(packageURL: URL,
                                         backupId: String) async -> [DeliveryResult] {
        // Disabled remotes stay configured but are skipped.
        let remotes = RcloneRemoteStore.enabledRemotes
        guard !remotes.isEmpty else { return [] }
        // [A19] A remote whose config could not be created has no rclone
        // config to upload against. Report it as a failed destination with
        // the real reason instead of attempting the upload and failing with
        // an opaque error.
        let configFailed = Set(RcloneRemoteStore.syncToRclone())

        return await Task.detached(priority: .utility) { () -> [DeliveryResult] in
            var out: [DeliveryResult] = []
            for r in remotes {
                if configFailed.contains(r.name) {
                    let message = AppLocalized("This server could not be set up — check its address and credentials, then try again.")
                    await MainActor.run {
                        BackupTransferStatus.shared.finish(
                            id: BackupTransferStatus.remoteKey(r.name),
                            name: r.name, error: message)
                    }
                    out.append(.init(id: UUID(), folderName: r.name,
                                     destination: nil, error: message,
                                     kind: r.backend, remotePath: r.path))
                    continue
                }
                do {
                    // Report bytes as they go. RcloneTransfer already polls
                    // core/stats for this; nothing was listening, so the UI sat
                    // on "Copying to destinations…" for the whole upload — the
                    // longest phase of a backup and the one most likely to
                    // stall.
                    try RcloneTransfer.upload(packageURL: packageURL,
                                              remote: r, backupId: backupId,
                                              progress: { p in
                        Task { @MainActor in
                            BackupTransferStatus.shared.update(
                                id: BackupTransferStatus.remoteKey(r.name),
                                name: r.name, bytesSent: p.bytesSent)
                        }
                    })
                    logger.info("[Backup] uploaded to remote '\(r.name)'")
                    await MainActor.run {
                        BackupTransferStatus.shared.finish(
                            id: BackupTransferStatus.remoteKey(r.name),
                            name: r.name, error: nil)
                    }
                    out.append(.init(id: UUID(), folderName: r.name,
                                     destination: URL(fileURLWithPath: "\(r.name):\(r.path)"),
                                     error: nil,
                                     kind: r.backend, remotePath: r.path,
                                     // [A18] The upload did not throw, but
                                     // nothing read the remote copy back, so
                                     // this is "accepted", not "verified".
                                     contentVerified: false))
                } catch {
                    logger.error("[Backup] upload to '\(r.name)' failed: \(error.localizedDescription)")
                    await MainActor.run {
                        BackupTransferStatus.shared.finish(
                            id: BackupTransferStatus.remoteKey(r.name),
                            name: r.name,
                            error: error.localizedDescription)
                    }
                    out.append(.init(id: UUID(), folderName: r.name,
                                     destination: nil, error: error.localizedDescription,
                                     kind: r.backend, remotePath: r.path))
                }
            }
            return out
        }.value
    }
}
