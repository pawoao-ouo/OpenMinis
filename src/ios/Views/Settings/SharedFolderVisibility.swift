//
//  SharedFolderVisibility.swift
//  MinisApp
//
//  Shared storage for which top-level subdirs of the FileProvider
//  (shared / skills / memory) should appear in the iOS Files app.
//  Both the main app process and the FileProvider extension read this.
//
//  Backing store: App Group UserDefaults (`group.com.openminis.clone`) so
//  the FileProvider extension sees the same state as the main app.
//
//  Semantics:
//    - Default = visible (all three are exposed on first launch).
//    - Toggling an entry off does NOT delete any data — it just hides the
//      subdir from the FileProvider enumerator so iOS Files no longer
//      shows it under "On My iPhone → Minis".
//

import Foundation

enum SharedFolderVisibility {
    /// The three top-level FileProvider subdirs we expose.
    /// Must match FileProviderExtension.topLevelSubdirs.
    static let allFolderNames: [String] = ["shared", "skills", "memory"]

    private static let userDefaultsKeyPrefix = "fileProviderVisible."

    private static var store: UserDefaults {
        // [Batch 26] Route through SharedContainerStore so the fallback
        // decision (and its loud log) lives in one place. NOTE: this still
        // falls back to .standard when the App Group is unavailable — the
        // real guard is the UI + provider gating on isAppGroupAvailable,
        // which refuse to pretend the toggles work in that case.
        SharedContainerStore.sharedDefaults ?? .standard
    }

    /// Whether the given folder name (e.g. "shared") is currently visible in Files.
    /// Defaults to `true` if no explicit value has been set.
    static func isVisible(_ name: String) -> Bool {
        let key = userDefaultsKeyPrefix + name
        // If the key doesn't exist, default to visible.
        if store.object(forKey: key) == nil {
            return true
        }
        return store.bool(forKey: key)
    }

    /// Update the visibility for a folder name. Caller is responsible for
    /// asking the FileProvider to re-enumerate afterwards.
    static func setVisible(_ name: String, to visible: Bool) {
        store.set(visible, forKey: userDefaultsKeyPrefix + name)
    }

    /// Names of all currently-visible folders.
    static var visibleFolderNames: Set<String> {
        Set(allFolderNames.filter { isVisible($0) })
    }
}
