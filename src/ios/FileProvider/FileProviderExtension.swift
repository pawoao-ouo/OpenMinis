import FileProvider
import UniformTypeIdentifiers
import os.log

/// Replicated File Provider extension that exposes MinisFileProvider/ to the system Files app.
/// Structure: Minis → { memory, skills, shared }
/// Uses the modern NSFileProviderReplicatedExtension protocol (iOS 16+).
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    let domain: NSFileProviderDomain

    private static let log = OSLog(subsystem: "com.openminis.clone.FileProvider", category: "Extension")

    /// Whether the mount can work in this process: the App Group container
    /// must exist. Without it, every process falls back to its own sandbox
    /// and the mount silently splits (Batch 26, P2-44). All entry points
    /// refuse first when this is false — see the guards in init, item(for:),
    /// fetchContents, createItem, modifyItem, deleteItem, and the
    /// enumerator's listItemsThrowing.
    static var isMountAvailable: Bool {
        SharedContainerStore.isAppGroupAvailable
    }

    /// Root directory for all FileProvider-visible files in the App Group container.
    /// Single source of truth is SharedContainerStore.containerURL — do NOT
    /// re-implement the fallback here. NOTE: this still resolves to the
    /// per-process fallback dir when the App Group is unavailable; it must
    /// never be dereferenced in that case (every entry point gates on
    /// isMountAvailable first).
    static var providerRoot: URL {
        let url = SharedContainerStore.containerURL
            .appendingPathComponent("MinisFileProvider", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The three top-level subdirectories exposed via the FileProvider.
    static let topLevelSubdirs = ["memory", "skills", "shared"]

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        // [Batch 26] Without the App Group, creating dirs here would plant
        // split state in this process's own sandbox. Log loudly and serve
        // nothing instead.
        guard Self.isMountAvailable else {
            os_log("FileProviderExtension init — App Group unavailable, mount disabled",
                   log: Self.log, type: .fault)
            return
        }
        let fm = FileManager.default
        let root = Self.providerRoot
        for sub in Self.topLevelSubdirs {
            try? fm.createDirectory(at: root.appendingPathComponent(sub, isDirectory: true),
                                    withIntermediateDirectories: true)
        }
        os_log("FileProviderExtension init — domain: %{public}@, providerRoot: %{public}@",
               log: Self.log, type: .info,
               domain.identifier.rawValue, root.path)

        let resolvedRoot = root.resolvingSymlinksInPath().path
        var rootSummaries: [String] = []
        for sub in Self.topLevelSubdirs {
            let dir = root.appendingPathComponent(sub, isDirectory: true)
            let count = (try? fm.contentsOfDirectory(atPath: dir.path).count) ?? -1
            rootSummaries.append("\(sub)=\(count)")
        }
        // [T-ios-fp-mac-bootcrash] Stamp every SUCCESSFUL launch with the app
        // version and the executable's mtime. The pre-main SIGILL launches
        // (TestFlight D8_ZguC2Ikr7Wl0fRI7Ubn, macOS 27 beta) can never log —
        // dyld dies before our code runs — so the diagnosis has to come from
        // the other side: the main app appends an "app-updated" line to this
        // same trace file when the bundle changes, and each init line here
        // carries the executable generation. If a .crash timestamp falls
        // between an "app-updated" line and the next init with a NEW exec
        // mtime, the bundle-replacement theory is confirmed from field data.
        let bundle = Bundle.main
        let ver = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var execStamp = "?"
        if let execURL = bundle.executableURL,
           let mod = (try? fm.attributesOfItem(atPath: execURL.path))?[.modificationDate] as? Date {
            execStamp = ISO8601DateFormatter().string(from: mod)
        }
        let onMac = ProcessInfo.processInfo.isiOSAppOnMac
        FPSyncTraceLog.log("init domain=\(domain.identifier.rawValue) ver=\(ver)(\(build)) exec=\(execStamp) mac=\(onMac) providerRoot=\(root.path) resolved=\(resolvedRoot) [\(rootSummaries.joined(separator: " "))]")

        Self.recoverFakeTrashDirIfNeeded(root: root)
        Self.cleanupLegacyLogsDirIfNeeded(root: root)
        Self.cleanupLegacyMountedFoldersIfNeeded(root: root)
    }

    /// Delete leftover FileProvider extension log directories.
    /// Two historical locations exist:
    ///   1. `<providerRoot>/logs/` — original buggy location (leaked
    ///      into iOS Files).
    ///   2. `<App Group>/MinisConfig/logs/` — second iteration; private
    ///      to the app, but still grew unbounded with one log file
    ///      written per FileProvider invocation.
    /// Both are now dead — the extension no longer writes any file
    /// logs (relies on `os_log` only), so we delete whatever is there.
    private static func cleanupLegacyLogsDirIfNeeded(root: URL) {
        let fm = FileManager.default

        // Location 1: under providerRoot (would leak into iOS Files).
        let inProvider = root.appendingPathComponent("logs", isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: inProvider.path, isDirectory: &isDir), isDir.boolValue {
            try? fm.removeItem(at: inProvider)
        }

        // Location 2: under MinisConfig (private but still pure cruft).
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.openminis.clone") {
            let inConfig = container.appendingPathComponent("MinisConfig/logs", isDirectory: true)
            if fm.fileExists(atPath: inConfig.path, isDirectory: &isDir), isDir.boolValue {
                try? fm.removeItem(at: inConfig)
            }
        }
    }

    /// Delete a residual `mounted-folders.json` file that the main app
    /// already migrated to `MinisConfig/`. If both copies exist the main
    /// app prefers the current-location one and drops the legacy one,
    /// but if migration didn't run (e.g. extension launched first on a
    /// cold boot) we should still not expose the stale copy to Files.
    private static func cleanupLegacyMountedFoldersIfNeeded(root: URL) {
        let fm = FileManager.default
        let legacy = root.appendingPathComponent("mounted-folders.json")
        guard fm.fileExists(atPath: legacy.path) else { return }
        // Only delete if the canonical copy already exists under MinisConfig —
        // otherwise we'd lose the data.
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.openminis.clone") else { return }
        let canonical = container.appendingPathComponent("MinisConfig/mounted-folders.json")
        if fm.fileExists(atPath: canonical.path) {
            try? fm.removeItem(at: legacy)
        }
    }

    /// Clean up any leftover `NSFileProviderTrashContainerItemIdentifier`
    /// directory under providerRoot. Historical bug: `createItem` /
    /// `modifyItem` would happily use this literal string as a path
    /// component when iOS Files tried to move an item to trash, creating
    /// a real directory whose name collides with the system-reserved
    /// identifier. The framework then gets confused and paused syncing.
    ///
    /// Contents are moved into `shared/_recovered_trash/` so no data is
    /// lost, and the fake directory is removed.
    private static func recoverFakeTrashDirIfNeeded(root: URL) {
        let fm = FileManager.default
        let fakeTrash = root.appendingPathComponent("NSFileProviderTrashContainerItemIdentifier", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fakeTrash.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }

        let recovered = root.appendingPathComponent("shared/_recovered_trash", isDirectory: true)
        do {
            try fm.createDirectory(at: recovered, withIntermediateDirectories: true)
        } catch {
            return
        }

        if let entries = try? fm.contentsOfDirectory(atPath: fakeTrash.path) {
            for name in entries {
                let src = fakeTrash.appendingPathComponent(name)
                var dst = recovered.appendingPathComponent(name)
                var n = 1
                while fm.fileExists(atPath: dst.path) {
                    let ext = (name as NSString).pathExtension
                    let base = (name as NSString).deletingPathExtension
                    let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                    dst = recovered.appendingPathComponent(candidate)
                    n += 1
                }
                try? fm.moveItem(at: src, to: dst)
            }
        }

        try? fm.removeItem(at: fakeTrash)
    }

    func invalidate() {
        os_log("FileProviderExtension invalidate", log: Self.log, type: .info)
    }

    // MARK: - Signal helper

    /// Notify the system that a container's contents changed so it re-enumerates.
    private func signalParent(_ parentIdentifier: NSFileProviderItemIdentifier) {
        NSFileProviderManager(for: domain)?.signalEnumerator(for: parentIdentifier) { error in
            if let error {
                os_log("signalEnumerator(%{public}@) error: %{public}@",
                       log: Self.log, type: .error,
                       parentIdentifier.rawValue, error.localizedDescription)
            }
        }
    }

    // MARK: - Item Lookup

    /// True if `identifier` is a top-level shared folder the user hid from
    /// the Files app, or anything inside one. [audit-C3] The root listing
    /// filters hidden folders, but `item(for:)` and direct subfolder
    /// enumeration did not — a cached identifier could still resolve a
    /// "hidden" folder.
    static func isHiddenTopLevelFolder(_ identifier: NSFileProviderItemIdentifier) -> Bool {
        let first = identifier.rawValue
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? identifier.rawValue
        guard SharedFolderVisibility.allFolderNames.contains(first) else { return false }
        return !SharedFolderVisibility.isVisible(first)
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        os_log("item(for: %{public}@)", log: Self.log, type: .debug, identifier.rawValue)
        // [Batch 26] No App Group, no mount — refuse rather than resolve
        // a path inside this process's own sandbox.
        if !Self.isMountAvailable {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        if identifier == .rootContainer {
            completionHandler(FileProviderItem(url: Self.providerRoot, parentIdentifier: .rootContainer, isRoot: true), nil)
            return Progress()
        }
        if identifier == .trashContainer {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        // [audit-C3] Do not resolve a hidden folder (or anything inside it)
        // through a cached identifier.
        if Self.isHiddenTopLevelFolder(identifier) {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let url = Self.providerRoot.appendingPathComponent(identifier.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let parentPath = (identifier.rawValue as NSString).deletingLastPathComponent
        let parentID = parentPath.isEmpty
            ? NSFileProviderItemIdentifier.rootContainer
            : NSFileProviderItemIdentifier(parentPath)
        completionHandler(FileProviderItem(url: url, parentIdentifier: parentID), nil)
        return Progress()
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        os_log("enumerator(for: %{public}@)", log: Self.log, type: .info, containerItemIdentifier.rawValue)

        switch containerItemIdentifier {
        case .rootContainer:
            return FileProviderEnumerator(containerItemIdentifier: .rootContainer)
        case .workingSet:
            return FileProviderEnumerator(containerItemIdentifier: .rootContainer, recursive: true)
        case .trashContainer:
            return FileProviderEnumerator(containerItemIdentifier: .trashContainer)
        default:
            return FileProviderEnumerator(containerItemIdentifier: containerItemIdentifier)
        }
    }

    // MARK: - Fetch Contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        // [Batch 26] No App Group, no mount.
        guard Self.isMountAvailable else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let url = Self.providerRoot.appendingPathComponent(itemIdentifier.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let parentPath = (itemIdentifier.rawValue as NSString).deletingLastPathComponent
        let parentID = parentPath.isEmpty
            ? NSFileProviderItemIdentifier.rootContainer
            : NSFileProviderItemIdentifier(parentPath)

        // [audit-C6] Stage the copy in a recognisably-prefixed temp dir so
        // stale copies left behind by a killed extension can be pruned on the
        // next fetch (see pruneStaleFetchTempDirs).
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minis-fp-" + UUID().uuidString)
        do {
            Self.pruneStaleFetchTempDirs()
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: tempFile)
            // [audit-C6] Re-check existence AFTER the copy and build the item
            // from freshly-read attributes: the file may have vanished between
            // enumerate and fetch. Serve noSuchItem rather than a stale
            // size/mtime from enumerate time.
            guard FileManager.default.fileExists(atPath: url.path) else {
                try? FileManager.default.removeItem(at: tempDir)
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                return Progress()
            }
            let item = FileProviderItem(url: url, parentIdentifier: parentID)
            completionHandler(tempFile, item, nil)
            // [audit-C6] The framework reads the copy after this returns;
            // remove the staging dir once it has had ample time to consume it.
            Self.scheduleFetchTempCleanup(tempDir)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            if !FileManager.default.fileExists(atPath: url.path) {
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            } else {
                completionHandler(nil, nil, error)
            }
        }
        return Progress()
    }

    /// Delay after which a staged fetch copy is removed. The framework reads
    /// the copy promptly after `fetchContents` returns; five minutes is ample
    /// for a local disk copy of any size, and bounds the leak to one staging
    /// dir per fetch at most. [audit-C6]
    private static let fetchTempCleanupDelay: TimeInterval = 300

    /// Remove a staged fetch temp dir after `fetchTempCleanupDelay`. Fire-and-
    /// forget: if the extension is killed before the timer fires, the dir is
    /// picked up by `pruneStaleFetchTempDirs` on the next fetch.
    private static func scheduleFetchTempCleanup(_ tempDir: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + fetchTempCleanupDelay) {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// Remove `minis-fp-*` staging dirs older than one hour — leftovers from
    /// extension processes killed before their delayed cleanup fired. Only
    /// touches our own prefixed dirs; never throws.
    private static func pruneStaleFetchTempDirs() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for entry in entries where entry.lastPathComponent.hasPrefix("minis-fp-") {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            if let mtime = values?.contentModificationDate, mtime < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    // MARK: - Create Item

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        // [Batch 26] No App Group, no mount.
        guard Self.isMountAvailable else {
            completionHandler(nil, [], false,
                              NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }
        // Block creation directly under root — only the fixed subdirs live there.
        // Block creation under memory/ or skills/ (read-only trees).
        // Block creation under trashContainer — we do not support a trash and
        // must not let iOS Files materialize a directory named after the
        // system-reserved identifier in providerRoot.
        let parentRaw = itemTemplate.parentItemIdentifier.rawValue
        if itemTemplate.parentItemIdentifier == .rootContainer
            || itemTemplate.parentItemIdentifier == .trashContainer
            || parentRaw == "memory" || parentRaw.hasPrefix("memory/")
            || parentRaw == "skills" || parentRaw.hasPrefix("skills/") {
            completionHandler(nil, [], false,
                              NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }

        let parentURL = Self.providerRoot.appendingPathComponent(itemTemplate.parentItemIdentifier.rawValue)
        let destURL = parentURL.appendingPathComponent(itemTemplate.filename)

        do {
            if itemTemplate.contentType == .folder {
                try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
            } else if let sourceURL = url {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            } else if !FileManager.default.fileExists(atPath: destURL.path) {
                // File with no contents supplied — an empty placeholder.
                // Materialize an empty file so the success reported below
                // points at something that actually exists; falling through
                // with nothing on disk left Files holding an item whose
                // backing file was never created, and every later read or
                // modify of it failed against a nonexistent path.
                guard FileManager.default.createFile(atPath: destURL.path, contents: nil) else {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
                }
            }
            let item = FileProviderItem(url: destURL, parentIdentifier: itemTemplate.parentItemIdentifier)
            completionHandler(item, [], false, nil)
            signalParent(itemTemplate.parentItemIdentifier)
        } catch {
            completionHandler(nil, [], false, error)
        }
        return Progress()
    }

    // MARK: - Modify Item

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        // [Batch 26] No App Group, no mount.
        guard Self.isMountAvailable else {
            completionHandler(nil, [], false,
                              NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }
        let idRaw = item.itemIdentifier.rawValue

        // Block rename/move of the three fixed top-level subdirectories.
        if Self.topLevelSubdirs.contains(idRaw),
           changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
            completionHandler(nil, [], false,
                              NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }

        // Block modifications to items under memory/ or skills/ (read-only).
        if idRaw.hasPrefix("memory/") || idRaw.hasPrefix("skills/") {
            completionHandler(nil, [], false,
                              NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }

        // Block moving items into the trash — we don't support a trash and
        // must not materialize a "NSFileProviderTrashContainerItemIdentifier"
        // directory in providerRoot. iOS Files will fall back to a hard
        // delete when it can't use the trash.
        if changedFields.contains(.parentItemIdentifier),
           item.parentItemIdentifier == .trashContainer {
            completionHandler(nil, [], false,
                              NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }

        let srcURL = Self.providerRoot.appendingPathComponent(item.itemIdentifier.rawValue)

        do {
            var destURL = srcURL
            if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                let parentURL: URL
                if item.parentItemIdentifier == .rootContainer {
                    parentURL = Self.providerRoot
                } else {
                    parentURL = Self.providerRoot.appendingPathComponent(item.parentItemIdentifier.rawValue)
                }
                destURL = parentURL.appendingPathComponent(item.filename)
                if srcURL != destURL {
                    try FileManager.default.moveItem(at: srcURL, to: destURL)
                }
            }

            if changedFields.contains(.contents), let newContents {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: newContents, to: destURL)
            }

            let resultItem = FileProviderItem(url: destURL, parentIdentifier: item.parentItemIdentifier)
            completionHandler(resultItem, [], false, nil)
            signalParent(item.parentItemIdentifier)
        } catch {
            completionHandler(nil, [], false, error)
        }
        return Progress()
    }

    // MARK: - Delete Item

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        os_log("deleteItem id=%{public}@", log: Self.log, type: .info, identifier.rawValue)

        // [Batch 26] No App Group, no mount.
        guard Self.isMountAvailable else {
            completionHandler(NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }

        let idRaw = identifier.rawValue
        if Self.topLevelSubdirs.contains(idRaw)
            || idRaw.hasPrefix("memory/") || idRaw.hasPrefix("skills/") {
            completionHandler(NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }

        let url = Self.providerRoot.appendingPathComponent(identifier.rawValue)
        // Derive parent identifier and signal it to re-enumerate.
        let parentPath = (identifier.rawValue as NSString).deletingLastPathComponent
        let parentID = parentPath.isEmpty
            ? NSFileProviderItemIdentifier.rootContainer
            : NSFileProviderItemIdentifier(parentPath)
        // [audit-C17] A file that is already gone is not a successful delete,
        // it is a no-op: report noSuchItem (the same error this file already
        // uses for missing items in item(for:) / fetchContents) instead of
        // telling Files the delete "succeeded". The parent is still signalled
        // so Files drops its stale row on re-enumeration.
        // NOTE: the chat/DB reference to this file survives — this extension
        // runs in its own sandbox and cannot open the main app's Library
        // database or the @-mention index (see batch12-report.md).
        guard FileManager.default.fileExists(atPath: url.path) else {
            os_log("deleteItem id=%{public}@ already gone", log: Self.log, type: .info, identifier.rawValue)
            completionHandler(NSFileProviderError(.noSuchItem))
            signalParent(parentID)
            return Progress()
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            os_log("deleteItem removeItem error: %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
            completionHandler(error)
            return Progress()
        }

        completionHandler(nil)
        signalParent(parentID)
        return Progress()
    }
}
