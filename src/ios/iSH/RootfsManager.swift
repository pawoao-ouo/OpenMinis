//
//  RootfsManager.swift
//  MinisApp
//
//  Manages Alpine Linux rootfs installation and paths
//

import Foundation
import Compression
import SQLite3

class RootfsManager {
    static let shared = RootfsManager()
    private let logger = AppLogger(category: "RootfsManager")

    /// [T-mcp-cli-help-and-readonly-ios] Guest path of the bundled minis-mcp-cli
    /// Python lib. Its files are mounted read-only (see applyDefaultMountOverlay).
    private static let mcpCliLibDir = "/usr/local/lib/minis-mcp-cli"
    private static let mcpCliLibPrefix = "/usr/local/lib/minis-mcp-cli/"

    /// [T-rootfs-reset-terminal-crash] Set once `reset()` deletes the rootfs
    /// directory from disk. The `ISHKernel` singleton boots exactly once per
    /// process and irreversibly becomes PID 1 via `become_first_process()`, so
    /// after a reset it is still `isBooted == true` but its fakefs is mounted
    /// against a `data/`/`meta.db` tree that no longer exists on disk. Reusing
    /// that stale mount (skipping install+boot because `isBooted` is true)
    /// crashes on the next `executeCommand`. Once this flag is set, the terminal
    /// must refuse to start a shell until the app is relaunched — there is no
    /// in-process way to un-boot or re-mount the kernel. Never cleared within a
    /// process lifetime; it is reset naturally on the next cold launch.
    private(set) var didResetWhileBooted = false

    private init() {}

    var rootfsPath: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("alpine-rootfs")
    }

    var dataPath: URL {
        return rootfsPath.appendingPathComponent("data")
    }

    /// Current rootfs architecture tag — change this when switching guest arch
    private let currentArch = "aarch64"

    private var archTagPath: URL {
        return rootfsPath.appendingPathComponent(".arch")
    }

    var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: dataPath.path) else { return false }
        // Check architecture matches
        guard let tag = try? String(contentsOf: archTagPath, encoding: .utf8) else { return false }
        return tag.trimmingCharacters(in: .whitespacesAndNewlines) == currentArch
    }

    /// Why `isInstalled` came back false, as a short loggable string.
    ///
    /// [T-rootfs-arch-tag-observability] `isInstalled` collapses several very
    /// different situations into one `false`, and the caller that acts on it
    /// (`installIfNeeded`) then deletes the whole rootfs. When that happened on
    /// a test device on 2026-08-21, the logs could not say WHICH condition had
    /// tripped — the rootfs had booted fine hours earlier, so the arch tag went
    /// missing at some point in between and nothing recorded it. This
    /// distinguishes the cases so the next occurrence is diagnosable rather
    /// than another forensic reconstruction.
    private func archTagDiagnostic() -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dataPath.path) { return "data-dir-missing" }
        if !fm.fileExists(atPath: archTagPath.path) { return "arch-file-missing" }
        do {
            let raw = try String(contentsOf: archTagPath, encoding: .utf8)
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.isEmpty { return "arch-file-empty" }
            return tag == currentArch ? "ok(\(tag))" : "arch-mismatch(found=\(tag) want=\(currentArch))"
        } catch {
            // Exists but unreadable — permissions, or a partially written file.
            return "arch-file-unreadable(\(error.localizedDescription))"
        }
    }

    /// Get the existing rootfs directory out of the way so a fresh copy can be
    /// installed at `rootfsPath`.
    ///
    /// [T-rootfs-undeletable-blocks-install] Tries a plain recursive delete
    /// first, and if that fails, MOVES the tree aside instead of giving up.
    ///
    /// Why the fallback is necessary: a recursive delete has to traverse every
    /// entry, so one unreachable entry anywhere in the tree fails the whole
    /// operation. Observed on a device on 2026-08-21 — a leftover test tree
    /// under `data/root/` nested ~10 levels of 80-character directory names
    /// deep pushed absolute paths past PATH_MAX (1024), and `removeItem` failed
    /// with POSIX 63 ENAMETOOLONG ("File name too long"), surfaced by
    /// Foundation as the thoroughly misleading "the file name
    /// \"alpine-rootfs\" is invalid". Because the old code let that error
    /// propagate, `installIfNeeded()` aborted BEFORE unzipping, so the rootfs
    /// could never be reinstalled: every launch retried the same delete, hit
    /// the same error, and iSH stayed permanently unbootable. Reinstalling from
    /// the UI did not help either — that button calls this very function.
    ///
    /// `rename(2)` only touches the directory ENTRY, never the contents, so it
    /// is unaffected by anything pathological inside — depth, name length, or
    /// permissions. Moving the tree aside therefore succeeds where deleting it
    /// cannot, and the install can proceed. We then attempt a best-effort
    /// cleanup of the moved-aside tree; if that also fails the tree is left in
    /// place (leaking disk) rather than blocking the user, and is logged so it
    /// can be reclaimed later.
    private func discardOldRootfs() throws {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: rootfsPath)
            return
        } catch {
            let ns = error as NSError
            logger.warning(
                "[Rootfs] delete failed for \(rootfsPath.path) — "
                + "domain=\(ns.domain) code=\(ns.code) "
                + "underlying=\(String(describing: ns.userInfo[NSUnderlyingErrorKey])) "
                + "desc=\(error.localizedDescription). Falling back to move-aside."
            )
        }

        // Same parent directory: rename(2) cannot cross filesystems, and a
        // Documents -> tmp move would risk EXDEV on some configurations.
        let parent = rootfsPath.deletingLastPathComponent()
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = parent.appendingPathComponent(".alpine-rootfs-broken-\(stamp)")
        do {
            try fm.moveItem(at: rootfsPath, to: aside)
            logger.warning("[Rootfs] moved undeletable rootfs aside to \(aside.lastPathComponent); install will continue")
        } catch {
            // Nothing left to try: we can neither delete nor move the old tree,
            // so installing on top of it would produce a mixed-version rootfs.
            // Fail loudly rather than silently corrupting it.
            logger.error("[Rootfs] move-aside ALSO failed for \(rootfsPath.path): \(error.localizedDescription)")
            throw error
        }

        // Best-effort reclaim. Expected to fail for exactly the reason the
        // original delete did; that is acceptable — correctness (a working
        // rootfs) matters more than the disk this leaks.
        //
        // [review] Also retry EVERY previously stranded tree, not just the one
        // we just created. The name is timestamped, so each occurrence makes a
        // new directory; without this sweep a device that hits this repeatedly
        // accumulates one full rootfs copy per occurrence with nothing ever
        // reclaiming them. A retry is worth attempting because the usual reason
        // the delete failed is a path that is too long *from this container's
        // prefix* — after an app container migration the prefix changes, and a
        // tree that was undeletable before can become deletable.
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        where name.hasPrefix(".alpine-rootfs-broken-") {
            let stranded = parent.appendingPathComponent(name)
            if (try? fm.removeItem(at: stranded)) != nil {
                logger.info("[Rootfs] reclaimed stranded \(name)")
                continue
            }
            let bytes = (try? stranded.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0
            logger.warning(
                "[Rootfs] could not reclaim \(name) (~\(bytes) bytes); "
                + "left on disk. Delete it from the guest shell (paths are short there) "
                + "or via Files if space is needed."
            )
        }
    }

    func installIfNeeded() throws {
        if FileManager.default.fileExists(atPath: rootfsPath.path) && !isInstalled {
            logger.warning("[Rootfs] arch tag missing or mismatched — will delete and reinstall \(currentArch). archTag=\(archTagDiagnostic()) path=\(rootfsPath.path)")
            try discardOldRootfs()
        }

        guard !isInstalled else {
            logger.info("[Rootfs] already installed (\(currentArch)) at \(rootfsPath.path)")
            return
        }

        guard let zipURL = Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip") else {
            throw NSError(
                domain: "RootfsManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "alpine-rootfs.zip not found in bundle"]
            )
        }

        logger.info("[Rootfs] installing from \(zipURL.path)")

        // Create destination directory
        try FileManager.default.createDirectory(
            at: rootfsPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Unzip using custom ZIP reader
        try unzipFile(at: zipURL, to: rootfsPath)

        // Write architecture tag so we detect mismatches on future launches
        try currentArch.write(to: archTagPath, atomically: true, encoding: .utf8)

        // Pre-create /var/minis/ shared directory structure
        let minisSubdirs = ["var/minis/attachments", "var/minis/offloads", "var/minis/workspace", "var/minis/skills", "var/minis/shared"]
        for subdir in minisSubdirs {
            let dirPath = dataPath.appendingPathComponent(subdir)
            try? FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
        }

        // Flag fresh install so first-boot tasks (e.g. mirror auto-detect) can trigger.
        UserDefaults.standard.set(true, forKey: "rootfs.freshInstall")

        logger.info("[Rootfs] installation complete (\(currentArch)) at \(rootfsPath.path)")
    }

    /// Directory holding user-data backups made by reset(keepUserData:).
    /// Deliberately OUTSIDE rootfsPath (reset deletes that tree) and NOT in
    /// temporaryDirectory (the system purges it, and the restore flow spans
    /// an app restart for reinstall — [R3-032]).
    var backupsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("rootfs-backups")
    }

    /// Newest surviving user-data backup (the `root` directory itself, or
    /// the `home` directory for a home-only backup, as returned by reset),
    /// or nil. Also scans the legacy temporaryDirectory location so a
    /// backup made by an older build can still be found if the system has
    /// not purged it yet.
    func latestBackupURL() -> URL? {
        let fm = FileManager.default
        let searchRoots = [backupsDirectory, fm.temporaryDirectory]
        var candidates: [(url: URL, created: Date)] = []
        for dir in searchRoots {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("rootfs-backup-") {
                let backupDir = dir.appendingPathComponent(name)
                // Prefer the root entry (the historical return contract); a
                // home-only backup — no /root existed when it was made — is
                // still discoverable via its home entry.
                var entry: URL?
                for sub in ["root", "home"] {
                    let candidate = backupDir.appendingPathComponent(sub)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                        entry = candidate
                        break
                    }
                }
                guard let found = entry else { continue }
                let created = (try? found.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                candidates.append((found, created))
            }
        }
        return candidates.max(by: { $0.created < $1.created })?.url
    }

    /// File count + byte total of a directory tree, for backup verification.
    /// Counts every entry (files, directories, symlinks); sizes only regular
    /// files. The same function runs on source and copy, so any difference
    /// means the copy is incomplete.
    private static func treeFingerprint(at url: URL) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        var count = 0
        var bytes: Int64 = 0
        let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            count += 1
            if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true, let size = values.fileSize {
                bytes += Int64(size)
            }
        }
        return (count, bytes)
    }

    /// Throws unless `dest` is a complete copy of `source` (same entry count
    /// and same total regular-file bytes). Runs before the old rootfs is
    /// deleted, so a failed or partial backup aborts the reset instead of
    /// destroying the only copy of the user's data.
    private static func verifyBackupCopy(from source: URL, to dest: URL, label: String) throws {
        let expected = treeFingerprint(at: source)
        let actual = treeFingerprint(at: dest)
        guard expected == actual else {
            throw NSError(
                domain: "RootfsManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Backup of \(label) is incomplete: copied \(actual.count) of \(expected.count) entries (\(actual.bytes) of \(expected.bytes) bytes). Aborted; your data was left in place."]
            )
        }
    }

    /// Reset (delete) the rootfs, forcing a fresh install on next launch
    /// - Parameter keepUserData: If true, backs up /root and /home before
    ///   deletion. Each copy is verified (file count + size) before anything
    ///   is deleted; a failed or incomplete backup aborts the reset and
    ///   leaves the rootfs in place.
    /// - Returns: URL of the backed-up /root directory if keepUserData was
    ///   true and /root existed, nil otherwise. The /home backup, when made,
    ///   sits next to it as `rootfs-backup-<ts>/home`.
    @discardableResult
    func reset(keepUserData: Bool = false) throws -> URL? {
        logger.warning("[Rootfs] reset requested — deleting \(rootfsPath.path)")

        var backupURL: URL?

        if keepUserData {
            // Back up /root AND /home — both are user iSH data. (Previously
            // only /root was copied, so a reset silently destroyed /home.)
            let userDirs = ["root", "home"].filter {
                FileManager.default.fileExists(atPath: dataPath.appendingPathComponent($0).path)
            }
            if !userDirs.isEmpty {
                let backupRoot = backupsDirectory
                    .appendingPathComponent("rootfs-backup-\(Date().timeIntervalSince1970)")
                try FileManager.default.createDirectory(
                    at: backupRoot,
                    withIntermediateDirectories: true
                )
                do {
                    for name in userDirs {
                        let source = dataPath.appendingPathComponent(name)
                        let dest = backupRoot.appendingPathComponent(name)
                        try FileManager.default.copyItem(at: source, to: dest)
                        try Self.verifyBackupCopy(from: source, to: dest, label: "/\(name)")
                        if name == "root" { backupURL = dest }
                    }
                } catch {
                    // Never present a partial backup as restorable: remove
                    // it, then abort the reset — the rootfs stays in place.
                    try? FileManager.default.removeItem(at: backupRoot)
                    logger.error("[Rootfs] user-data backup failed (\(error.localizedDescription)) — reset aborted, rootfs left in place")
                    throw error
                }
                logger.info("[Rootfs] user data backed up to \(backupRoot.path)")
            }
        }

        // Delete rootfs. Uses the same move-aside fallback as installIfNeeded:
        // a reset exists precisely to recover from a broken rootfs, so it must
        // not be the one operation that a broken rootfs can block.
        if FileManager.default.fileExists(atPath: rootfsPath.path) {
            try discardOldRootfs()
            logger.warning("[Rootfs] rootfs removed from \(rootfsPath.path)")
        }

        // [T-rootfs-reset-terminal-crash] If the kernel already booted this
        // session, its fakefs is now mounted against a deleted tree. The kernel
        // cannot be re-mounted or un-booted in-process, so mark the session
        // poisoned; the terminal start path checks this and refuses to reuse the
        // stale mount (which would crash) until the app is relaunched.
        if ISHKernel.shared.isBooted {
            didResetWhileBooted = true
            logger.warning("Rootfs reset while kernel booted; terminal disabled until app relaunch")
        }

        logger.info("[Rootfs] reset complete — installIfNeeded() will reinstall")

        return backupURL
    }

    /// Restore one user directory (/root or /home) from a backup copy.
    /// Atomic with respect to the live directory: the backup is first
    /// copied to a temp sibling and verified; only then is the live
    /// directory moved aside — a rename, which succeeds even where a
    /// recursive delete cannot (see discardOldRootfs) — and the verified
    /// copy moved into place. If the final move fails, the live directory
    /// is moved back, so a failed restore never destroys the live data.
    /// The moved-aside copy is removed afterwards on a best-effort basis.
    private func restoreOneUserDirectory(from source: URL, to live: URL, label: String) throws {
        let fm = FileManager.default
        let parent = live.deletingLastPathComponent()
        let stamp = UUID().uuidString
        let temp = parent.appendingPathComponent(".restore-\(label)-\(stamp)")
        let aside = parent.appendingPathComponent(".old-\(label)-\(stamp)")

        do {
            try fm.copyItem(at: source, to: temp)
            try Self.verifyBackupCopy(from: source, to: temp, label: "/\(label)")
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }

        let hadLive = fm.fileExists(atPath: live.path)
        if hadLive {
            do {
                try fm.moveItem(at: live, to: aside)
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
        }
        do {
            try fm.moveItem(at: temp, to: live)
        } catch {
            // Put the live directory back: the restore failed, the data must not move.
            if hadLive {
                try? fm.moveItem(at: aside, to: live)
            }
            try? fm.removeItem(at: temp)
            throw error
        }
        if hadLive, (try? fm.removeItem(at: aside)) == nil {
            logger.warning("[Rootfs] could not remove moved-aside \(label) at \(aside.lastPathComponent); left on disk")
        }
        logger.info("[Rootfs] \(label) restored from \(source.path)")
    }

    /// Restore user data from a backup
    /// - Parameter backupURL: URL of a `root` (or, for a home-only backup,
    ///   `home`) directory inside a `rootfs-backup-<ts>/` folder, as
    ///   returned by `latestBackupURL()`. Restores /root from it and, when
    ///   the backup folder also holds a sibling `home/` directory, restores
    ///   /home too. Each directory is restored via a verified temp copy +
    ///   swap, so a failed restore leaves the live directory untouched.
    func restoreUserData(from backupURL: URL) throws {
        guard isInstalled else {
            throw NSError(
                domain: "RootfsManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Rootfs not installed. Run installIfNeeded() first."]
            )
        }

        switch backupURL.lastPathComponent {
        case "home":
            // Home-only backup (no /root existed when the backup was made).
            try restoreOneUserDirectory(
                from: backupURL,
                to: dataPath.appendingPathComponent("home"),
                label: "home"
            )
        case "root":
            try restoreOneUserDirectory(
                from: backupURL,
                to: dataPath.appendingPathComponent("root"),
                label: "root"
            )
            // The /home backup, when made, sits next to it as
            // `rootfs-backup-<ts>/home`.
            let homeBackup = backupURL.deletingLastPathComponent().appendingPathComponent("home")
            if FileManager.default.fileExists(atPath: homeBackup.path) {
                try restoreOneUserDirectory(
                    from: homeBackup,
                    to: dataPath.appendingPathComponent("home"),
                    label: "home"
                )
            }
        default:
            // Refuse anything else: passing the backup folder itself would
            // nest root/ and home/ inside /root.
            throw NSError(
                domain: "RootfsManager",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Not a user-data backup directory: \(backupURL.lastPathComponent). Expected rootfs-backup-<ts>/root or /home."]
            )
        }

        logger.info("[Rootfs] user data restored from \(backupURL.path)")
    }

    /// Overlay default configuration files from the bundle onto the rootfs.
    /// Runs on every boot so app updates with new defaults take effect.
    func applyDefaultMountOverlay() {
        let totalStart = CFAbsoluteTimeGetCurrent()
        logger.info("[DefaultMount] applyDefaultMountOverlay() called")

        guard let overlayURL = Bundle.main.url(forResource: "default_mount", withExtension: nil) else {
            logger.info("[DefaultMount] No default_mount found in bundle")
            return
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: overlayURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }

        var fileCount = 0
        var copyTotalMs: Double = 0
        var metaDbTotalMs: Double = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }

            // relativePath e.g. "/etc/pip/pip.conf"
            let relativePath = fileURL.path.replacingOccurrences(of: overlayURL.path, with: "")
            let destURL = dataPath.appendingPathComponent(relativePath)

            do {
                let copyStart = CFAbsoluteTimeGetCurrent()
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.copyItem(at: fileURL, to: destURL)
                copyTotalMs += (CFAbsoluteTimeGetCurrent() - copyStart) * 1000
                fileCount += 1

                // Determine the fakefs mode. iOS strips POSIX execute bits
                // from some bundle resources during install, so reading
                // `attributesOfItem` is unreliable for the +x case. Fall
                // back to a path-based heuristic: anything shipped under
                // a standard *bin directory is forced to 0755 so scripts
                // like /usr/local/bin/minis-open are always executable.
                var posixMode: UInt16 = 0o644
                if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                   let num = attrs[.posixPermissions] as? NSNumber {
                    posixMode = num.uint16Value
                }
                let binDirs = ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/local/bin/", "/usr/local/sbin/"]
                if binDirs.contains(where: { relativePath.hasPrefix($0) }) {
                    posixMode = 0o755
                }
                // [T-mcp-cli-help-and-readonly-ios] The bundled minis-mcp-cli
                // Python lib is app-managed and shipped read-only so users
                // cannot tamper with it from inside iSH (e.g. `vi`). Register
                // these regular files as 0o444 (read-only) — iSH's access_check
                // then rejects writes in-guest. The host copy is unaffected, so
                // the every-boot overwrite still updates them on app upgrade.
                // Scoped to this lib subtree ONLY; the sh wrapper under
                // /usr/local/bin/ stays 0o755 (handled by binDirs above).
                if relativePath.hasPrefix(Self.mcpCliLibPrefix) {
                    posixMode = 0o444
                }
                let fakefsMode: UInt32 = 0o100000 | UInt32(posixMode)

                // Register in fakefs meta.db so iSH kernel can see the file
                let metaStart = CFAbsoluteTimeGetCurrent()
                ensureParentDirsInMetaDB(for: relativePath)
                ensureFakefsMetadata(for: relativePath, isDirectory: false, mode: fakefsMode)
                metaDbTotalMs += (CFAbsoluteTimeGetCurrent() - metaStart) * 1000
            } catch {
                logger.error("[DefaultMount] ERROR \(relativePath): \(error)")
            }
        }

        // [T-mcp-cli-help-and-readonly-ios] The per-file loop above stamped the
        // minis-mcp-cli lib FILES read-only (0o444), but ensureParentDirsInMetaDB
        // creates the containing directories with the default writable mode
        // (0o040755) — which would still let the guest create/delete files
        // inside them. Re-register the lib directories as 0o555 (read+execute,
        // no write) so the whole subtree is read-only to the guest. Idempotent:
        // ensureFakefsMetadata updates the stat row in place each boot.
        for dir in [Self.mcpCliLibDir, "\(Self.mcpCliLibDir)/transport", "\(Self.mcpCliLibDir)/utils"] {
            ensureFakefsMetadata(for: dir, isDirectory: true, mode: 0o040555)
        }

        // Remove PEP 668 EXTERNALLY-MANAGED marker so pip install works without
        // --break-system-packages. Safe in this embedded Alpine rootfs.
        let markerStart = CFAbsoluteTimeGetCurrent()
        removeExternallyManagedMarker()
        let markerMs = (CFAbsoluteTimeGetCurrent() - markerStart) * 1000

        let totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
        let avgCopyMs = fileCount > 0 ? copyTotalMs / Double(fileCount) : 0
        let avgMetaMs = fileCount > 0 ? metaDbTotalMs / Double(fileCount) : 0
        logger.info("[DefaultMount] Done. \(fileCount) file(s) overlaid in \(String(format: "%.1f", totalMs))ms — copy: \(String(format: "%.1f", copyTotalMs))ms (avg \(String(format: "%.2f", avgCopyMs))ms/file), metaDB: \(String(format: "%.1f", metaDbTotalMs))ms (avg \(String(format: "%.2f", avgMetaMs))ms/file), marker: \(String(format: "%.1f", markerMs))ms")

        // [OpenMinis#288] Seed the path-scoped ffmpeg stub only when absent.
        // Never overwrite: apk add ffmpeg / user binaries at /usr/bin/ffmpeg
        // must win. default_mount always replaces files, so the stub cannot
        // live there.
        ensureNativeFfmpegStubIfNeeded()
    }

    /// Install a non-ELF placeholder at `/usr/bin/ffmpeg` when missing so PATH
    /// can resolve `ffmpeg` and the path-scoped native offload can claim it.
    ///
    /// [OpenMinis#288] Real ELF binaries (Alpine apk, user builds) are left
    /// alone — `native_offload_lookup` also refuses to hijack ELFs at this
    /// path. The stub content is never executed when offload is active; it
    /// only needs to exist and not look like an ELF.
    func ensureNativeFfmpegStubIfNeeded() {
        let relativePath = "/usr/bin/ffmpeg"
        // Match applyDefaultMountOverlay path join (relativePath keeps leading "/").
        let destURL = dataPath.appendingPathComponent(relativePath)
        let fm = FileManager.default
        if fm.fileExists(atPath: destURL.path) {
            return
        }
        do {
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stub = """
            #!/bin/sh
            # MINIS_NATIVE_FFMPEG_STUB — placeholder for path-scoped FFmpegOffload.
            # If you see this message, native offload did not intercept execve.
            echo "minis: ffmpeg native offload unavailable; try minis-ffmpeg or apk add ffmpeg" >&2
            exit 127
            """
            try stub.write(to: destURL, atomically: true, encoding: .utf8)
            ensureParentDirsInMetaDB(for: relativePath)
            ensureFakefsMetadata(for: relativePath, isDirectory: false, mode: 0o100755)
            logger.info("[DefaultMount] seeded native ffmpeg stub at \(relativePath)")
        } catch {
            logger.error("[DefaultMount] failed to seed ffmpeg stub: \(error)")
        }
    }

    /// Remove the PEP 668 EXTERNALLY-MANAGED marker file from all Python versions.
    private func removeExternallyManagedMarker() {
        let fm = FileManager.default
        let usrLib = dataPath.appendingPathComponent("usr/lib")
        guard let contents = try? fm.contentsOfDirectory(atPath: usrLib.path) else { return }
        for entry in contents where entry.hasPrefix("python3") {
            let marker = usrLib.appendingPathComponent(entry).appendingPathComponent("EXTERNALLY-MANAGED")
            if fm.fileExists(atPath: marker.path) {
                try? fm.removeItem(at: marker)
                logger.info("[DefaultMount] removed EXTERNALLY-MANAGED from \(entry)")
            }
        }
    }

    // MARK: - Fakefs meta.db helpers

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindPathBlob(_ stmt: OpaquePointer, index: Int32, path: String) {
        let utf8 = Array(path.utf8)
        sqlite3_bind_blob(stmt, index, utf8, Int32(utf8.count), Self.SQLITE_TRANSIENT)
    }

    func ensureFakefsMetadata(for linuxPath: String, isDirectory: Bool, mode: UInt32? = nil) {
        let metaDBPath = rootfsPath.appendingPathComponent("meta.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(metaDBPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else { return }
        defer { sqlite3_close(db) }

        let effectiveMode: UInt32 = mode ?? (isDirectory ? 0o040755 : 0o100644)
        var statBytes: [UInt8] = Array(repeating: 0, count: 16)
        let leMode = effectiveMode.littleEndian
        withUnsafeBytes(of: leMode) { src in
            for i in 0..<4 { statBytes[i] = src[i] }
        }

        // If the path already exists, update its stat row in place so we can
        // refresh mode bits (e.g. when a newer app version ships an updated
        // default_mount file with different permissions).
        var checkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT inode FROM paths WHERE path = ?", -1, &checkStmt, nil) == SQLITE_OK,
              let checkStmt else { return }
        defer { sqlite3_finalize(checkStmt) }

        bindPathBlob(checkStmt, index: 1, path: linuxPath)
        if sqlite3_step(checkStmt) == SQLITE_ROW {
            let existingInode = sqlite3_column_int64(checkStmt, 0)
            var updateStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE stats SET stat = ? WHERE inode = ?", -1, &updateStmt, nil) == SQLITE_OK,
                  let updateStmt else { return }
            defer { sqlite3_finalize(updateStmt) }
            sqlite3_bind_blob(updateStmt, 1, statBytes, Int32(statBytes.count), Self.SQLITE_TRANSIENT)
            sqlite3_bind_int64(updateStmt, 2, existingInode)
            sqlite3_step(updateStmt)
            return
        }

        var insertStatStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO stats (stat) VALUES (?)", -1, &insertStatStmt, nil) == SQLITE_OK,
              let insertStatStmt else { return }
        defer { sqlite3_finalize(insertStatStmt) }

        sqlite3_bind_blob(insertStatStmt, 1, statBytes, Int32(statBytes.count), Self.SQLITE_TRANSIENT)
        guard sqlite3_step(insertStatStmt) == SQLITE_DONE else { return }

        var insertPathStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO paths (path, inode) VALUES (?, last_insert_rowid())", -1, &insertPathStmt, nil) == SQLITE_OK,
              let insertPathStmt else { return }
        defer { sqlite3_finalize(insertPathStmt) }

        bindPathBlob(insertPathStmt, index: 1, path: linuxPath)
        sqlite3_step(insertPathStmt)
    }

    func ensureParentDirsInMetaDB(for linuxPath: String) {
        var current = (linuxPath as NSString).deletingLastPathComponent
        var dirs: [String] = []
        while current != "/" && !current.isEmpty {
            dirs.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        for dir in dirs.reversed() {
            ensureFakefsMetadata(for: dir, isDirectory: true)
        }
    }

    /// Remove a path (and, if it's a directory subtree, all of its descendants)
    /// from fakefs `meta.db`. Also drops orphaned `stats` rows. Safe to call on
    /// paths that don't exist in meta.db (it's a no-op in that case).
    func removeFakefsPath(_ linuxPath: String) {
        let metaDBPath = rootfsPath.appendingPathComponent("meta.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(metaDBPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else { return }
        defer { sqlite3_close(db) }

        // Collect inodes of rows that will be deleted so we can drop their
        // stat rows too (meta.db has no FK cascade).
        var inodes: [Int64] = []
        let prefix = linuxPath.hasSuffix("/") ? linuxPath : linuxPath + "/"
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db,
            "SELECT inode FROM paths WHERE path = ? OR substr(path, 1, ?) = ?",
            -1, &selectStmt, nil) == SQLITE_OK, let selectStmt {
            bindPathBlob(selectStmt, index: 1, path: linuxPath)
            sqlite3_bind_int(selectStmt, 2, Int32(Array(prefix.utf8).count))
            bindPathBlob(selectStmt, index: 3, path: prefix)
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                inodes.append(sqlite3_column_int64(selectStmt, 0))
            }
            sqlite3_finalize(selectStmt)
        }
        if inodes.isEmpty { return }

        var deletePathsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db,
            "DELETE FROM paths WHERE path = ? OR substr(path, 1, ?) = ?",
            -1, &deletePathsStmt, nil) == SQLITE_OK, let deletePathsStmt {
            bindPathBlob(deletePathsStmt, index: 1, path: linuxPath)
            sqlite3_bind_int(deletePathsStmt, 2, Int32(Array(prefix.utf8).count))
            bindPathBlob(deletePathsStmt, index: 3, path: prefix)
            sqlite3_step(deletePathsStmt)
            sqlite3_finalize(deletePathsStmt)
        }

        var deleteStatsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM stats WHERE inode = ?", -1, &deleteStatsStmt, nil) == SQLITE_OK,
           let deleteStatsStmt {
            for inode in inodes {
                sqlite3_reset(deleteStatsStmt)
                sqlite3_bind_int64(deleteStatsStmt, 1, inode)
                sqlite3_step(deleteStatsStmt)
            }
            sqlite3_finalize(deleteStatsStmt)
        }
    }

    /// Register every existing file/directory under `hostRoot` into `meta.db`,
    /// using Linux paths relative to `dataPath`. Used after copying a directory
    /// subtree from the host filesystem (e.g. FileBrowser import/copy/move)
    /// so that the iSH kernel can see the new entries.
    func registerSubtreeInMetaDB(hostRoot: URL) {
        let fm = FileManager.default
        let dataPrefix = dataPath.standardized.path
        let rootStd = hostRoot.standardized.path
        guard rootStd == dataPrefix || rootStd.hasPrefix(dataPrefix + "/") else { return }

        func linuxPath(for hostPath: String) -> String? {
            if hostPath == dataPrefix { return "/" }
            guard hostPath.hasPrefix(dataPrefix + "/") else { return nil }
            return String(hostPath.dropFirst(dataPrefix.count))
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootStd, isDirectory: &isDir) else { return }
        guard let rootLinux = linuxPath(for: rootStd) else { return }

        ensureParentDirsInMetaDB(for: rootLinux)
        ensureFakefsMetadata(for: rootLinux, isDirectory: isDir.boolValue)
        guard isDir.boolValue else { return }

        var stack: [URL] = [URL(fileURLWithPath: rootStd)]
        while let dir = stack.popLast() {
            guard let children = try? fm.contentsOfDirectory(at: dir,
                                                             includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: []) else { continue }
            for child in children {
                let childStd = child.standardized.path
                guard let childLinux = linuxPath(for: childStd) else { continue }
                var childIsDir: ObjCBool = false
                fm.fileExists(atPath: childStd, isDirectory: &childIsDir)
                ensureFakefsMetadata(for: childLinux, isDirectory: childIsDir.boolValue)
                if childIsDir.boolValue {
                    stack.append(URL(fileURLWithPath: childStd))
                }
            }
        }
    }

    /// Get the size of the rootfs installation
    /// - Returns: Size in bytes
    func getRootfsSize() throws -> Int64 {
        guard FileManager.default.fileExists(atPath: rootfsPath.path) else { return 0 }
        return Self.directorySize(at: rootfsPath)
    }

    /// Size of a directory tree, in bytes. Never throws: unreadable
    /// entries are skipped, so a size probe can never fail the screen
    /// that shows it.
    static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Storage breakdown + safe cleanup (2026-11-13)

    /// One row of the storage breakdown shown on the Rootfs page.
    struct StorageRow {
        /// Display name, e.g. "Your files (/root)".
        let label: String
        /// Guest path, e.g. "/root" — "" for rows that live outside the guest.
        let linuxPath: String
        let bytes: Int64
    }

    /// Where the rootfs bytes actually are, top folders first.
    ///
    /// Rows are the big subtrees under `data/` plus the reset-backup
    /// folder (which lives OUTSIDE the rootfs, so it is not part of
    /// `total` — it is shown as its own row because it is the same
    /// disk). `otherBytes` is everything else in the installed tree
    /// (the Alpine system files, `meta.db`, the arch tag).
    func storageBreakdown() -> (rows: [StorageRow], otherBytes: Int64, total: Int64) {
        let total = (try? getRootfsSize()) ?? 0
        let data = dataPath
        let defs: [(label: String, linuxPath: String, rel: String)] = [
            ("Your files (/root)", "/root", "root"),
            ("Your files (/home)", "/home", "home"),
            ("Chats & workspace (/var/minis)", "/var/minis", "var/minis"),
            ("Package cache (/var/cache/apk)", "/var/cache/apk", "var/cache/apk"),
            ("Temporary files (/tmp)", "/tmp", "tmp"),
            ("System programs (/usr)", "/usr", "usr"),
            ("Logs (/var/log)", "/var/log", "var/log"),
        ]
        var rows: [StorageRow] = []
        var accounted: Int64 = 0
        for def in defs {
            let bytes = Self.directorySize(at: data.appendingPathComponent(def.rel))
            rows.append(StorageRow(label: def.label, linuxPath: def.linuxPath, bytes: bytes))
            accounted += bytes
        }
        // Reset backups live in Documents/rootfs-backups, outside the
        // installed tree — same disk, separate row, not in `total`.
        let backupBytes = Self.directorySize(at: backupsDirectory)
        rows.append(StorageRow(label: "Reset backups (rootfs-backups)",
                               linuxPath: "", bytes: backupBytes))
        return (rows, max(0, total - accounted), total)
    }

    /// What `cleanSafeJunk()` removed, so the UI can say how much came back.
    struct CleanupResult {
        /// Bytes freed, junk + pruned old reset backups together.
        let freedBytes: Int64
        /// Junk entries removed (files / directories under the allowlist).
        let removedEntries: Int
        /// Old reset-backup folders pruned (newest one kept).
        let prunedBackups: Int
    }

    /// Delete ONLY regenerable junk — never user data, never the system.
    ///
    /// Allowlist (contents only — the directories themselves stay):
    ///   * `data/var/cache/apk/*` — downloaded package files; `apk` re-fetches them.
    ///   * `data/tmp/*` — scratch files.
    ///   * `data/var/log/*` — log files.
    /// Plus: prune `Documents/rootfs-backups/` to the newest 1 folder.
    ///
    /// NEVER deleted here: `/root`, `/home`, chats, skills, memory,
    /// shared files, the installed system (`/usr`, `/bin`, …), or the
    /// newest reset backup. A failure on one entry is logged and the
    /// rest still runs, so a partial cleanup still reports what it freed.
    ///
    /// Safe while the kernel is booted: deleting these host-side files is
    /// the same as running `rm` inside the guest — the host/app-group
    /// design already relies on the guest seeing host-side changes, and
    /// each removed path is also dropped from fakefs `meta.db` so no
    /// stale entry points at it.
    func cleanSafeJunk() -> CleanupResult {
        let fm = FileManager.default
        var freed: Int64 = 0
        var removed = 0

        let junkDirs = ["var/cache/apk", "tmp", "var/log"]
        for rel in junkDirs {
            let dir = dataPath.appendingPathComponent(rel)
            let children = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for child in children {
                // The target must be a direct child of an allowlisted dir —
                // never anything else, even if the list above is edited.
                guard child.deletingLastPathComponent().standardized.path == dir.standardized.path else { continue }
                let bytes = Self.directorySize(at: child)
                do {
                    try fm.removeItem(at: child)
                    freed += bytes
                    removed += 1
                    // Drop the fakefs entry (and descendants) so the running
                    // kernel never resolves a deleted path. No-op when the
                    // path was never registered; failures are ignored.
                    let linuxPath = "/" + rel + "/" + child.lastPathComponent
                    removeFakefsPath(linuxPath)
                } catch {
                    logger.warning("[Rootfs] cleanup skipped \(child.path): \(error.localizedDescription)")
                }
            }
        }

        // Prune reset backups to the newest 1. Only folders this feature
        // itself created (`rootfs-backup-*` under backupsDirectory) are
        // ever touched; the legacy tmp location is left alone.
        var pruned = 0
        let names = (try? fm.contentsOfDirectory(atPath: backupsDirectory.path)) ?? []
        var candidates: [(url: URL, created: Date)] = []
        for name in names where name.hasPrefix("rootfs-backup-") {
            let url = backupsDirectory.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            candidates.append((url, created))
        }
        candidates.sort { $0.created > $1.created }
        for old in candidates.dropFirst() {
            let bytes = Self.directorySize(at: old.url)
            do {
                try fm.removeItem(at: old.url)
                freed += bytes
                pruned += 1
                logger.info("[Rootfs] cleanup pruned old reset backup \(old.url.lastPathComponent)")
            } catch {
                logger.warning("[Rootfs] cleanup could not prune \(old.url.path): \(error.localizedDescription)")
            }
        }

        logger.info("[Rootfs] cleanup freed \(freed) bytes (\(removed) junk entries, \(pruned) old reset backups)")
        return CleanupResult(freedBytes: freed, removedEntries: removed, prunedBackups: pruned)
    }

    private func unzipFile(at sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default

        guard let archive = ZIPArchive(url: sourceURL) else {
            throw NSError(
                domain: "RootfsManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to open zip archive"]
            )
        }

        // Find common prefix to strip (e.g., "alpine-rootfs/")
        let prefix = "alpine-rootfs/"

        for entry in archive.entries {
            var relativePath = entry.path

            // Strip the common prefix if present
            if relativePath.hasPrefix(prefix) {
                relativePath = String(relativePath.dropFirst(prefix.count))
            }

            // Skip empty paths (the root directory itself)
            guard !relativePath.isEmpty else { continue }

            let entryPath = destinationURL.appendingPathComponent(relativePath)

            // Create parent directories if needed
            let parentDir = entryPath.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            // Extract entry
            if entry.isDirectory {
                try fileManager.createDirectory(at: entryPath, withIntermediateDirectories: true)
            } else {
                if let data = try archive.extractData(for: entry) {
                    try data.write(to: entryPath)
                }
            }
        }
    }
}

// Minimal ZIP archive reader with safe unaligned memory access
private class ZIPArchive {
    /// Own logger: this is a separate type from RootfsManager, and its failures
    /// (a corrupt archive, an unsupported compression method) are exactly the
    /// kind that must survive in the daily log file rather than vanishing into
    /// a print() the way the rootfs lifecycle messages used to.
    private let logger = AppLogger(category: "RootfsZIP")

    struct Entry {
        let path: String
        let isDirectory: Bool
        let compressedSize: Int
        let uncompressedSize: Int
        let compressionMethod: UInt16
        let localHeaderOffset: UInt64
    }

    private let fileHandle: FileHandle
    private(set) var entries: [Entry] = []

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.fileHandle = handle

        do {
            try parseZipFile()
        } catch {
            logger.error("[RootfsZIP] parse error: \(error)")
            return nil
        }
    }

    deinit {
        try? fileHandle.close()
    }

    // Safe unaligned read helpers
    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        return UInt32(data[offset]) |
               (UInt32(data[offset + 1]) << 8) |
               (UInt32(data[offset + 2]) << 16) |
               (UInt32(data[offset + 3]) << 24)
    }

    private func parseZipFile() throws {
        fileHandle.seekToEndOfFile()
        let fileSize = fileHandle.offsetInFile

        // Search for End of Central Directory
        let searchSize: UInt64 = Swift.min(fileSize, 65557)
        fileHandle.seek(toFileOffset: fileSize - searchSize)
        let searchData = fileHandle.readDataToEndOfFile()

        guard let eocdOffset = findEOCD(in: searchData) else {
            throw NSError(domain: "ZIPArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid ZIP"])
        }

        let eocdStart = Int(fileSize - searchSize) + eocdOffset

        fileHandle.seek(toFileOffset: UInt64(eocdStart))
        let eocdData = fileHandle.readData(ofLength: 22)
        guard eocdData.count == 22 else { throw NSError(domain: "ZIPArchive", code: 2, userInfo: nil) }

        let centralDirOffset = readUInt32(eocdData, at: 16)
        let entryCount = readUInt16(eocdData, at: 10)

        fileHandle.seek(toFileOffset: UInt64(centralDirOffset))

        for _ in 0..<entryCount {
            guard let entry = readCentralDirectoryEntry() else { break }
            entries.append(entry)
        }
    }

    private func findEOCD(in data: Data) -> Int? {
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        for i in stride(from: data.count - 22, through: 0, by: -1) {
            if data[i] == signature[0] && data[i+1] == signature[1] &&
               data[i+2] == signature[2] && data[i+3] == signature[3] {
                return i
            }
        }
        return nil
    }

    private func readCentralDirectoryEntry() -> Entry? {
        let headerData = fileHandle.readData(ofLength: 46)
        guard headerData.count == 46 else { return nil }

        let sig = readUInt32(headerData, at: 0)
        guard sig == 0x02014B50 else { return nil }

        let compressionMethod = readUInt16(headerData, at: 10)
        let compressedSize = readUInt32(headerData, at: 20)
        let uncompressedSize = readUInt32(headerData, at: 24)
        let fileNameLength = readUInt16(headerData, at: 28)
        let extraLength = readUInt16(headerData, at: 30)
        let commentLength = readUInt16(headerData, at: 32)
        let localHeaderOffset = readUInt32(headerData, at: 42)

        let fileNameData = fileHandle.readData(ofLength: Int(fileNameLength))
        let fileName = String(data: fileNameData, encoding: .utf8) ?? ""

        fileHandle.seek(toFileOffset: fileHandle.offsetInFile + UInt64(extraLength + commentLength))

        return Entry(
            path: fileName,
            isDirectory: fileName.hasSuffix("/"),
            compressedSize: Int(compressedSize),
            uncompressedSize: Int(uncompressedSize),
            compressionMethod: compressionMethod,
            localHeaderOffset: UInt64(localHeaderOffset)
        )
    }

    func extractData(for entry: Entry) throws -> Data? {
        fileHandle.seek(toFileOffset: entry.localHeaderOffset)

        let localHeader = fileHandle.readData(ofLength: 30)
        guard localHeader.count == 30 else { return nil }

        let fileNameLen = readUInt16(localHeader, at: 26)
        let extraLen = readUInt16(localHeader, at: 28)

        fileHandle.seek(toFileOffset: fileHandle.offsetInFile + UInt64(fileNameLen + extraLen))

        let compressedData = fileHandle.readData(ofLength: entry.compressedSize)

        if entry.compressionMethod == 0 {
            return compressedData
        } else if entry.compressionMethod == 8 {
            return decompressDeflate(compressedData, expectedSize: entry.uncompressedSize)
        } else {
            logger.error("[RootfsZIP] unsupported compression method: \(entry.compressionMethod)")
            return nil
        }
    }

    private func decompressDeflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }

        var decompressed = Data(count: expectedSize)
        let result = decompressed.withUnsafeMutableBytes { destPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                let dstSize = expectedSize
                let status = compression_decode_buffer(
                    destPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    dstSize,
                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
                return status
            }
        }

        if result > 0 {
            decompressed.count = result
            return decompressed
        }
        return nil
    }
}
