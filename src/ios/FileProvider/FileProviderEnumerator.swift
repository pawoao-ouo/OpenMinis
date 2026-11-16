import FileProvider
import os.log

/// Enumerates the contents of a directory in the shared folder.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerItemIdentifier: NSFileProviderItemIdentifier
    private let recursive: Bool
    private static let log = OSLog(subsystem: "com.openminis.clone.FileProvider", category: "Enumerator")

    init(containerItemIdentifier: NSFileProviderItemIdentifier, recursive: Bool = false) {
        self.containerItemIdentifier = containerItemIdentifier
        self.recursive = recursive
        super.init()
    }

    func invalidate() {}

    // MARK: - Full enumeration (initial sync)

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // [audit-E5] Do NOT swallow directory-read errors into `[]` — that
        // makes iOS Files mistake an unreadable directory (permissions,
        // disk glitch, App Group lockup) for a genuine empty folder, and can
        // prompt a destructive sync against an empty snapshot. Propagate the
        // error so Files shows "Cannot Connect" instead of blank.
        do {
            let items = try listItemsThrowing()
            os_log("enumerateItems container=%{public}@ recursive=%d count=%d",
                   log: Self.log, type: .info,
                   containerItemIdentifier.rawValue, recursive ? 1 : 0, items.count)
            FPSyncTraceLog.log("enumerateItems id=\(containerItemIdentifier.rawValue) recursive=\(recursive) count=\(items.count)")
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
            // [audit-C1] A full enumeration is a complete report; the next
            // incremental diff is measured against it.
            EnumeratorSnapshotStore.store(
                Set(items.map { $0.itemIdentifier.rawValue }), forKey: snapshotKey)
        } catch {
            os_log("enumerateItems container=%{public}@ failed: %{public}@",
                   log: Self.log, type: .error,
                   containerItemIdentifier.rawValue, error.localizedDescription)
            FPSyncTraceLog.log("enumerateItems id=\(containerItemIdentifier.rawValue) ERROR=\(error.localizedDescription)")
            observer.finishEnumeratingWithError(error)
        }
    }

    // MARK: - Change enumeration (incremental updates)

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        // [audit-C2] Fail honestly: a directory we cannot read is an error,
        // not an empty folder. `listItems()` used to swallow the error into
        // `[]`, which is indistinguishable from a genuinely empty folder.
        let items: [FileProviderItem]
        let currentAnchor: NSFileProviderSyncAnchor
        do {
            items = try listItemsThrowing()
            currentAnchor = Self.anchor(for: items)
        } catch {
            os_log("enumerateChanges container=%{public}@ list failed: %{public}@",
                   log: Self.log, type: .error,
                   containerItemIdentifier.rawValue, error.localizedDescription)
            FPSyncTraceLog.log("enumerateChanges id=\(containerItemIdentifier.rawValue) ERROR=\(error.localizedDescription)")
            observer.finishEnumeratingWithError(error)
            return
        }
        os_log("enumerateChanges container=%{public}@ anchorMatch=%d itemCount=%d",
               log: Self.log, type: .info,
               containerItemIdentifier.rawValue,
               syncAnchor == currentAnchor ? 1 : 0,
               items.count)
        FPSyncTraceLog.log("enumerateChanges id=\(containerItemIdentifier.rawValue) anchorOld=\(Self.hex(syncAnchor.rawValue)) anchorNew=\(Self.hex(currentAnchor.rawValue)) match=\(syncAnchor == currentAnchor) count=\(items.count)")

        let currentIDs = Set(items.map { $0.itemIdentifier.rawValue })
        if syncAnchor == currentAnchor {
            // Nothing changed — but bootstrap the snapshot if this container
            // never stored one (e.g. first run after upgrade), so the next
            // real change can diff against something.
            EnumeratorSnapshotStore.storeIfMissing(currentIDs, forKey: snapshotKey)
            observer.finishEnumeratingChanges(upTo: currentAnchor, moreComing: false)
            return
        }

        // [audit-C1] Diff against the last reported listing and report
        // deletions. External writes (iSH shell, FileBrowserView, etc.)
        // change the anchor but carry no per-anchor history; the persisted
        // snapshot is that history.
        //
        // Empirically, returning `.syncAnchorExpired` here causes iOS Files to
        // refuse re-enumeration in many cases — the container stays stuck on
        // its cached listing, which is the user-visible "writes don't appear"
        // bug. Instead, replay every current item via `didUpdate` and finish
        // with the new anchor: iOS dedups by itemIdentifier and refreshes
        // metadata for items that already existed, while picking up newly-
        // appeared ones — plus `didDelete` for anything that vanished.
        let previousIDs = EnumeratorSnapshotStore.identifiers(forKey: snapshotKey) ?? []
        let deletedIDs = previousIDs.subtracting(currentIDs).sorted()
        if !deletedIDs.isEmpty {
            os_log("enumerateChanges container=%{public}@ deleted=%d",
                   log: Self.log, type: .info,
                   containerItemIdentifier.rawValue, deletedIDs.count)
            FPSyncTraceLog.log("enumerateChanges id=\(containerItemIdentifier.rawValue) deleted=\(deletedIDs.count)")
            observer.didDelete(deletedIDs.map { NSFileProviderItemIdentifier($0) })
        }
        observer.didUpdate(items)
        observer.finishEnumeratingChanges(upTo: currentAnchor, moreComing: false)
        // Report first, persist second (see EnumeratorSnapshotStore): a crash
        // between the two just re-reports the same deletions next time.
        EnumeratorSnapshotStore.store(currentIDs, forKey: snapshotKey)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // [audit-C2] An unreadable directory yields no anchor (nil) rather
        // than a fake empty-folder anchor.
        completionHandler(try? buildSyncAnchor())
    }

    /// Hex-encode an 8-byte anchor for human-readable log lines. Falls back
    /// to a length tag for non-standard anchor sizes (shouldn't happen, but
    /// keeps the log line readable if framework changes the format).
    private static func hex(_ data: Data) -> String {
        if data.count == 8 {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        return "len=\(data.count)"
    }

    // MARK: - Helpers

    /// True if `name` looks like a FileProvider framework-reserved identifier
    /// (e.g. "NSFileProviderTrashContainerItemIdentifier"). Such names must
    /// never appear as real filenames in providerRoot.
    private static func isReservedIdentifier(_ name: String) -> Bool {
        return name.hasPrefix("NSFileProvider") && name.hasSuffix("Identifier")
    }

    /// Names of metadata files/dirs that historically lived under providerRoot
    /// and must never be exposed to iOS Files. Even after migration to
    /// MinisConfig/, a stale copy might still be around after upgrading —
    /// this list protects against that.
    private static let metadataBlacklist: Set<String> = [
        "mounted-folders.json",
        "logs",
    ]

    /// True if `name` is either a dotfile, reserved FP identifier, or a
    /// known metadata filename that must not appear in iOS Files.
    private static func isHiddenMetadata(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        if isReservedIdentifier(name) { return true }
        if metadataBlacklist.contains(name) { return true }
        return false
    }

    /// Snapshot key for this enumerator. The recursive working-set listing
    /// covers the whole subtree, so it must not share a snapshot with the
    /// plain root listing. [audit-C1]
    private var snapshotKey: String {
        "\(containerItemIdentifier.rawValue)|recursive=\(recursive)"
    }

    private func directoryURL() -> URL {
        if containerItemIdentifier == .rootContainer {
            return FileProviderExtension.providerRoot
        }
        return FileProviderExtension.providerRoot
            .appendingPathComponent(containerItemIdentifier.rawValue)
    }

    private func listItems() -> [FileProviderItem] {
        (try? listItemsThrowing()) ?? []
    }

    /// [audit-E5] Throwing counterpart: preserves the underlying FileManager
    /// error so `enumerateItems` can fail honestly via `finishEnumeratingWithError`.
    private func listItemsThrowing() throws -> [FileProviderItem] {
        // Trash is not supported — always return empty.
        if containerItemIdentifier == .trashContainer {
            return []
        }

        // [audit-C3] A hidden top-level folder must not leak its contents
        // when enumerated directly by identifier.
        if FileProviderExtension.isHiddenTopLevelFolder(containerItemIdentifier) {
            return []
        }

        let dirURL = directoryURL()
        let fm = FileManager.default
        if containerItemIdentifier == .rootContainer {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }

        if recursive {
            return listItemsRecursively(at: dirURL, parentIdentifier: containerItemIdentifier)
        }

        var contents = try fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        // Defensive: never expose a disk entry whose name collides with a
        // system-reserved FileProvider identifier. A prior bug allowed
        // `NSFileProviderTrashContainerItemIdentifier/` to be materialized
        // under providerRoot when iOS Files asked to move an item to trash.
        contents = contents.filter { !Self.isHiddenMetadata($0.lastPathComponent) }

        // At the root container, filter out top-level subdirs the user has
        // hidden from iOS Files via Settings → Shared Folders. The data still
        // lives on disk; it just doesn't appear in the Files app until the
        // user re-enables the toggle.
        if containerItemIdentifier == .rootContainer {
            let visible = SharedFolderVisibility.visibleFolderNames
            contents = contents.filter { url in
                // Only filter known top-level names; unknown entries (if any)
                // are passed through unchanged so future additions are safe.
                let name = url.lastPathComponent
                if SharedFolderVisibility.allFolderNames.contains(name) {
                    return visible.contains(name)
                }
                return true
            }
        }

        return contents.map { url in
            FileProviderItem(url: url, parentIdentifier: containerItemIdentifier)
        }
    }

    /// Recursively list all items under a directory for the working set.
    private func listItemsRecursively(at dirURL: URL, parentIdentifier: NSFileProviderItemIdentifier) -> [FileProviderItem] {
        let fm = FileManager.default
        guard var contents = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // Defensive: same reserved-identifier filter as the non-recursive path.
        contents = contents.filter { !Self.isHiddenMetadata($0.lastPathComponent) }

        let rootURL = FileProviderExtension.providerRoot
        // At the provider root, apply the same hidden-folder filter as the
        // non-recursive path so hidden top-level subdirs don't leak into the
        // working set when iOS Files enumerates recursively.
        if dirURL.standardized.path == rootURL.standardized.path {
            let visible = SharedFolderVisibility.visibleFolderNames
            contents = contents.filter { url in
                let name = url.lastPathComponent
                if SharedFolderVisibility.allFolderNames.contains(name) {
                    return visible.contains(name)
                }
                return true
            }
        }

        let root = rootURL.path
        var items: [FileProviderItem] = []
        for url in contents {
            let item = FileProviderItem(url: url, parentIdentifier: parentIdentifier)
            items.append(item)

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let relative = url.path.replacingOccurrences(of: root, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let childParentID = relative.isEmpty
                    ? NSFileProviderItemIdentifier.rootContainer
                    : NSFileProviderItemIdentifier(relative)
                items.append(contentsOf: listItemsRecursively(at: url, parentIdentifier: childParentID))
            }
        }
        return items
    }

    /// Build a compact, deterministic sync anchor from directory contents.
    /// Uses a fixed-size 8-byte representation to avoid exceeding the system's
    /// vendor-token size limit (which causes an assertion in FPXObserver).
    /// [audit-C2] Throwing: an unreadable directory is an error, not an
    /// empty-folder anchor.
    private func buildSyncAnchor() throws -> NSFileProviderSyncAnchor {
        try Self.anchor(for: listItemsThrowing())
    }

    /// Hash a listing into a fixed-size 8-byte anchor.
    private static func anchor(for items: [FileProviderItem]) -> NSFileProviderSyncAnchor {
        // Base hash: item count (even 0 is fine — we still fold visibility in below).
        var hash: UInt64 = UInt64(items.count)

        // Mix the current visibility state into the anchor so toggling a
        // shared folder's "Show in Files app" switch causes iOS Files to
        // discard its cache and re-enumerate. Without this, the recursive
        // working-set path can keep returning stale entries even after the
        // non-recursive listItems() path has started filtering them out.
        for name in SharedFolderVisibility.allFolderNames {
            let isVisible = SharedFolderVisibility.visibleFolderNames.contains(name)
            hash = hash &* 31 &+ (isVisible ? 1 : 0)
            // Also fold in the name so adding new names later doesn't collide.
            for byte in name.utf8 {
                hash = hash &* 31 &+ UInt64(byte)
            }
        }

        for item in items {
            let mtime = item.contentModificationDate ?? Date.distantPast
            hash = hash &+ UInt64(bitPattern: Int64(mtime.timeIntervalSince1970 * 1000))
            // Mix in the file size: a content swap that preserves the mtime
            // (cp -p, touch -r, archive extraction with stored timestamps)
            // must still change the anchor, or Files keeps showing the old
            // content as if nothing changed.
            hash = hash &* 31 &+ (item.documentSize?.uint64Value ?? 0)
            // Mix in the identifier to detect renames
            for byte in item.itemIdentifier.rawValue.utf8 {
                hash = hash &* 31 &+ UInt64(byte)
            }
        }
        var hashBytes = hash
        return NSFileProviderSyncAnchor(Data(bytes: &hashBytes, count: 8))
    }

}

// MARK: - Enumeration snapshot store (C1)

/// Persists the last listing reported to Files, per enumerator, so
/// `enumerateChanges` can report deletions via `didDelete`.
///
/// Why disk, not instance state: the system creates a fresh
/// `FileProviderEnumerator` per enumeration request, so an instance snapshot
/// would be empty on the next call — and the extension process itself can be
/// killed at any time. The snapshot lives in
/// `MinisConfig/fp-enumerator-snapshots.json` in the App Group container
/// (the same container the extension already reads and writes).
///
/// Ordering rule — report first, persist second: if the extension dies
/// between reporting a deletion and persisting the new snapshot, the next
/// `enumerateChanges` recomputes the same deletion (idempotent). Persisting
/// first would lose deletions Files never saw.
///
/// If the App Group container is unavailable, the store degrades to
/// in-memory only: deletions are still reported while the extension process
/// lives, and silently missed after a restart (same as before this fix).
private enum EnumeratorSnapshotStore {
    private static let queue = DispatchQueue(label: "com.openminis.clone.fp-snapshots")
    private static var cache: [String: Set<String>]?
    private static let fileName = "fp-enumerator-snapshots.json"

    private static func snapshotsURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.openminis.clone") else { return nil }
        return container.appendingPathComponent("MinisConfig", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static func loadIfNeeded() {
        if cache != nil { return }
        guard let url = snapshotsURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            cache = [:]
            return
        }
        cache = decoded.mapValues { Set($0) }
    }

    /// Identifiers in the last stored snapshot for `key`, or nil if none was ever stored.
    static func identifiers(forKey key: String) -> Set<String>? {
        queue.sync {
            loadIfNeeded()
            return cache?[key]
        }
    }

    /// Store `identifiers` as the snapshot for `key`. Call AFTER reporting.
    static func store(_ identifiers: Set<String>, forKey key: String) {
        queue.sync {
            loadIfNeeded()
            cache?[key] = identifiers
            persistLocked()
        }
    }

    /// Store only if no snapshot exists yet (first-run bootstrap on the anchor-match path).
    static func storeIfMissing(_ identifiers: Set<String>, forKey key: String) {
        queue.sync {
            loadIfNeeded()
            guard cache?[key] == nil else { return }
            cache?[key] = identifiers
            persistLocked()
        }
    }

    /// Must be called with `queue` held. Never throws — a failed write just
    /// means the next enumeration re-derives from the older snapshot.
    private static func persistLocked() {
        guard let url = snapshotsURL(), let cache else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plain = cache.mapValues { Array($0).sorted() }
        guard let data = try? JSONEncoder().encode(plain) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
