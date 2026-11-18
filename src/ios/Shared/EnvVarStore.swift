import Foundation
import Security
import os.log

private let logger = AppLogger(category: "EnvVarStore")

// MARK: - EnvVarEntry

struct EnvVarEntry: Identifiable, Codable {
    let id: String
    var key: String
    var createdAt: Date
    /// Optional human-readable description of what this variable is for. Empty
    /// string when omitted. Stored in the JSON metadata file; not secret.
    var note: String

    init(id: String = UUID().uuidString, key: String, createdAt: Date = Date(), note: String = "") {
        self.id = id
        self.key = key
        self.createdAt = createdAt
        self.note = note
    }

    // Custom decoder so older entries without a `note` field still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.key = try c.decode(String.self, forKey: .key)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.note = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
}

// MARK: - Save failure

/// Why a store write did not land. `add`/`update`/`delete` return Bool for
/// the success signal; the reason for a failure is stashed in
/// `lastSaveFailure` so the form can show the actual cause instead of a
/// generic line. Invariant: every `false` on the add/update/delete path
/// sets `lastSaveFailure` first; it is cleared at the start of each call.
enum EnvVarSaveFailure: Equatable {
    /// A variable with this name already exists (add, or rename in update).
    case duplicateKey(String)
    /// The Keychain write (or the read-back verify on rename) failed.
    case keychainFailed(String)
    /// The entries JSON could not be written; the in-memory change was rolled back.
    case jsonFailed
    /// The name is empty or fails `isValidKey`.
    case invalidKey(String)
    /// The entry being edited no longer exists (deleted elsewhere).
    case entryGone

    /// User-facing text naming the actual cause.
    var displayText: String {
        switch self {
        case .duplicateKey(let key):
            return AppLocalized("A variable named \"\(key)\" already exists. Edit the existing one instead of adding a new one.")
        case .keychainFailed(let key):
            return AppLocalized("Could not save the value for \"\(key)\" to the Keychain — nothing was saved.")
        case .jsonFailed:
            return AppLocalized("Could not save the variable list to disk — your change was rolled back. Try again.")
        case .invalidKey(let key):
            return AppLocalized("\"\(key)\" is not a valid variable name. It must start with a letter and contain only letters, digits, and underscores.")
        case .entryGone:
            return AppLocalized("This variable no longer exists — it may have been deleted elsewhere. Close this form and try again.")
        }
    }
}

// MARK: - EnvVarStore

@MainActor
final class EnvVarStore: ObservableObject {
    static let shared = EnvVarStore()

    @Published private(set) var entries: [EnvVarEntry] = []

    /// Reason the most recent add/update/delete failed (nil when it
    /// succeeded). Read synchronously right after a `false` return; the
    /// form shows it inline. Not @Published — no observation is needed.
    private(set) var lastSaveFailure: EnvVarSaveFailure?

    private let fileURL: URL
    nonisolated private static let keychainService = "com.openminis.clone.envvar"

    init() {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let baseURL = libraryURL.appendingPathComponent("MinisChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        self.fileURL = baseURL.appendingPathComponent("env-vars.json")
        self.entries = Self.loadEntries(from: fileURL)
    }


    // MARK: - Persistence (key list)

    private static func loadEntries(from url: URL) -> [EnvVarEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([EnvVarEntry].self, from: data) else {
            return []
        }
        return entries
    }


    /// [ENV-5] Returns whether the entries JSON actually landed on disk.
    /// Callers must roll their in-memory change back on false — otherwise
    /// the list looks right until the next restart, when the entry is gone.
    @discardableResult
    private func saveEntries() -> Bool {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            logger.error("Failed to save env var entries: \(error)")
            return false
        }
    }



    // MARK: - Keychain (values)

    /// Persist a value under `key` in the synchronizable Keychain.
    ///
    /// Previously this did delete-then-add unconditionally. That had a
    /// data-loss window: if the two SecItemDelete calls didn't fully remove
    /// the prior synchronizable item (iCloud Keychain replication lag), the
    /// following SecItemAdd returned errSecDuplicateItem — the old value was
    /// already deleted and the new value never landed, so the variable read
    /// back EMPTY. That is the intermittent "saved a value but it comes back
    /// blank" the user hit (e.g. WEBDAV_USER).
    ///
    /// Now: update-in-place first; only add when the item genuinely doesn't
    /// exist; and on a duplicate race, fall back to update. The prior value is
    /// never deleted before the new one is committed, so a failed write leaves
    /// the old value intact instead of blanking it. Returns whether the value
    /// is now persisted.
    @discardableResult
    nonisolated private static func saveValue(_ value: String, forKey key: String) -> Bool {
        let syncMatch: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: true,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        // Remove any legacy NON-synchronizable item for this key so reads
        // (which prefer the sync item) don't shadow it — but do this only
        // after we know the sync write will be attempted, and never let its
        // result blank the value.
        func dropLegacyNonSyncItem() {
            var legacy = syncMatch
            legacy[kSecAttrSynchronizable as String] = false
            SecItemDelete(legacy as CFDictionary)
        }

        var status = SecItemUpdate(syncMatch as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = syncMatch
            addQuery.merge(attrs) { _, new in new }
            status = SecItemAdd(addQuery as CFDictionary, nil)
            // Lost a race: the item appeared between our update and add
            // (replication or a concurrent write). Update it instead of
            // failing — this is the exact case that used to blank the value.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(syncMatch as CFDictionary, attrs as CFDictionary)
            }
        }

        if status == errSecSuccess {
            dropLegacyNonSyncItem()
            return true
        }
        logger.error("Keychain save failed for \(key): OSStatus \(status) — prior value left intact")
        return false
    }

    nonisolated private static func loadValue(forKey key: String) -> String? {
        // Try synchronizable first
        let syncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(syncQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data { return String(data: data, encoding: .utf8) }
        // Fallback to legacy non-sync
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func deleteValue(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var syncQuery = query
        syncQuery[kSecAttrSynchronizable as String] = true
        SecItemDelete(syncQuery as CFDictionary)
    }

    /// Keychain values are keyed by NAME while entries are per-UUID, and
    /// sync deliberately keeps same-name entries created on two devices —
    /// so two entries can share the one value stored under their key.
    /// Deleting/renaming either entry must not destroy the shared value
    /// while another entry still references that key.
    private func deleteValueIfUnreferenced(forKey key: String) {
        guard !entries.contains(where: { $0.key == key }) else { return }
        Self.deleteValue(forKey: key)
    }

    /// Non-isolated read for use from background threads (backup, debug RPC).
    nonisolated static func loadValueSync(forKey key: String) -> String? {
        loadValue(forKey: key)
    }

    /// Non-isolated write for use from background threads (backup restore).
    /// [A-F8] Returns whether the write actually landed; saveValue already
    /// computed this Bool and threw it away, so the importer counted
    /// env-var restores it never verified.
    @discardableResult
    nonisolated static func saveValueSync(_ value: String, forKey key: String) -> Bool {
        saveValue(value, forKey: key)
    }

    // MARK: - Validation

    /// Valid env var name: starts with a letter, contains only letters, digits, and underscores.
    static let keyRegex = /^[A-Za-z][A-Za-z0-9_]*$/

    static func isValidKey(_ key: String) -> Bool {
        key.wholeMatch(of: keyRegex) != nil
    }

    // MARK: - Value Sanitization

    /// Strip invisible/control characters that iOS paste can introduce (e.g. \u{9b} CSI).
    /// Keeps only printable ASCII and common whitespace (space, tab).
    private static func sanitizeValue(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            // Allow printable ASCII (0x20-0x7E) and tab (0x09)
            (scalar.value >= 0x20 && scalar.value <= 0x7E) || scalar.value == 0x09
        })
    }

    // MARK: - Public API

    /// Returns whether the variable is now persisted (Keychain value +
    /// entries JSON). False means nothing was saved; `lastSaveFailure`
    /// says why. Callers that show a form must not dismiss on false.
    @discardableResult
    func add(key: String, value: String, note: String = "") -> Bool {
        lastSaveFailure = nil
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmedKey.isEmpty, Self.isValidKey(trimmedKey) else {
            lastSaveFailure = .invalidKey(trimmedKey)
            return false
        }

        // Don't allow duplicate keys
        guard !entries.contains(where: { $0.key == trimmedKey }) else {
            logger.warning("Duplicate env var key: \(trimmedKey)")
            lastSaveFailure = .duplicateKey(trimmedKey)
            return false
        }

        let cleanValue = Self.sanitizeValue(value)
        // Commit the value to the Keychain FIRST. If it fails, don't insert a
        // list entry — otherwise the variable shows up with a blank value.
        guard Self.saveValue(cleanValue, forKey: trimmedKey) else {
            logger.error("Add env var aborted — Keychain write failed for \(trimmedKey)")
            lastSaveFailure = .keychainFailed(trimmedKey)
            return false
        }
        let entry = EnvVarEntry(key: trimmedKey, note: note)
        entries.append(entry)
        // The JSON write is part of the save: if it fails, roll the entry
        // back out so memory and disk never diverge. (The Keychain value
        // just written stays as an invisible orphan; re-adding the key
        // overwrites it, and it is never shown without an entry.)
        guard saveEntries() else {
            entries.removeLast()
            lastSaveFailure = .jsonFailed
            return false
        }
        logger.info("Added env var: \(trimmedKey)")
        return true
    }

    /// Update an entry. Pass `note: nil` to leave the existing note untouched
    /// (used by the deep-link overwrite path which only updates the value).
    /// Returns whether the update is now persisted; false means nothing was
    /// changed (see `lastSaveFailure`). The entry is rolled back in memory
    /// if the JSON write fails.
    @discardableResult
    func update(id: String, key: String, value: String, note: String? = nil) -> Bool {
        lastSaveFailure = nil
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            lastSaveFailure = .entryGone
            return false
        }

        let oldKey = entries[idx].key
        let oldNote = entries[idx].note
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmedKey.isEmpty, Self.isValidKey(trimmedKey) else {
            lastSaveFailure = .invalidKey(trimmedKey)
            return false
        }

        let keyChanged = oldKey != trimmedKey
        if keyChanged {
            guard !entries.contains(where: { $0.key == trimmedKey && $0.id != id }) else {
                logger.warning("Cannot rename to duplicate key: \(trimmedKey)")
                lastSaveFailure = .duplicateKey(trimmedKey)
                return false
            }
        }

        let cleanValue = Self.sanitizeValue(value)
        // Write under the destination key first (same-key path is update-in-place
        // inside saveValue). Only after that succeeds do we delete the old
        // Keychain account on rename — delete-then-write used to lose the
        // secret if SecItemAdd/Update failed after SecItemDelete.
        guard Self.saveValue(cleanValue, forKey: trimmedKey) else {
            logger.error("Update env var aborted — Keychain write failed for \(trimmedKey); prior key \(oldKey) left intact")
            lastSaveFailure = .keychainFailed(trimmedKey)
            return false
        }
        // Confirm the destination account is readable before dropping the old
        // one on rename (mirrors the copy-then-delete migration below).
        if keyChanged {
            guard Self.loadValue(forKey: trimmedKey) != nil else {
                logger.error("Update env var aborted — Keychain verify failed for \(trimmedKey); prior key \(oldKey) left intact")
                lastSaveFailure = .keychainFailed(trimmedKey)
                return false
            }
        }

        entries[idx].key = trimmedKey
        if let note { entries[idx].note = note }
        // The JSON write is part of the save: if it fails, roll the entry
        // back so memory and disk never diverge.
        guard saveEntries() else {
            entries[idx].key = oldKey
            entries[idx].note = oldNote
            lastSaveFailure = .jsonFailed
            return false
        }

        if keyChanged {
            deleteValueIfUnreferenced(forKey: oldKey)
        }
        logger.info("Updated env var: \(trimmedKey)")
        return true
    }

    /// Update only the human-readable note without touching the
    /// Keychain-stored value. Used by minis-config so the agent can
    /// annotate variables without ever seeing or overwriting the
    /// secret.
    func updateNote(id: String, note: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].note = note
        saveEntries()
    }

    /// Returns whether the deletion is now persisted. The list is written
    /// FIRST and the Keychain value dropped only after that lands: the old
    /// order deleted the value first, so a failed JSON write left a
    /// restored entry with a blank value. On failure the entry is rolled
    /// back into the list and the value is untouched.
    @discardableResult
    func delete(id: String) -> Bool {
        lastSaveFailure = nil
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            lastSaveFailure = .entryGone
            return false
        }
        let key = entries[idx].key
        let entry = entries[idx]
        entries.remove(at: idx)
        guard saveEntries() else {
            entries.insert(entry, at: idx)
            lastSaveFailure = .jsonFailed
            return false
        }
        deleteValueIfUnreferenced(forKey: key)
        // Mark the entry's per-key record for cloud deletion. Peers will
        // hard-delete it via applyEnvVarItemDeletion. The recordId is the
        // entry UUID, not the key — same as upsert path.
        logger.info("Deleted env var: \(key)")
        return true
    }

    func value(forKey key: String) -> String? {
        Self.loadValue(forKey: key)
    }

    func entry(id: String) -> EnvVarEntry? {
        entries.first(where: { $0.id == id })
    }


    /// Returns all env vars as a dictionary for injection into shell execution.
    nonisolated func allAsDict() -> [String: String] {
        var dict: [String: String] = [:]
        // Read entries from the JSON file directly (avoid MainActor requirement)
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let fileURL = libraryURL.appendingPathComponent("MinisChat/env-vars.json")
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([EnvVarEntry].self, from: data) else {
            return dict
        }
        for entry in entries {
            if let val = Self.loadValue(forKey: entry.key) {
                dict[entry.key] = val
            }
        }
        return dict
    }
}
