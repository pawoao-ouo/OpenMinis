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

// MARK: - EnvVarSaveFailure

/// [Batch 20 Fix 1] One reason per failure path (ENV-1 duplicate,
/// ENV-2 Keychain, ENV-5 JSON). No generic fixed string: each message
/// states the actual cause, and the duplicate one names the key.
enum EnvVarSaveFailure {
    case invalidKey(String)
    case duplicateKey(String)
    case keychainFailed(String)
    case keychainVerifyFailed(String)
    case jsonFailed(String)
    case entryMissing

    var message: String {
        switch self {
        case .invalidKey:
            return AppLocalized("Must start with a letter and contain only letters, digits, and underscores.")
        case .duplicateKey(let key):
            return AppLocalized("A variable named \"\(key)\" already exists.")
        case .keychainFailed(let key):
            return AppLocalized("Could not save \"\(key)\" to the Keychain. The value was not saved.")
        case .keychainVerifyFailed(let key):
            return AppLocalized("Could not verify \"\(key)\" in the Keychain. The change was not saved.")
        case .jsonFailed:
            return AppLocalized("Could not save the variable list to disk. Your change was not saved.")
        case .entryMissing:
            return AppLocalized("This variable no longer exists. Please close and reopen the list.")
        }
    }
}

// MARK: - EnvVarStore

@MainActor
final class EnvVarStore: ObservableObject {
    static let shared = EnvVarStore()

    @Published private(set) var entries: [EnvVarEntry] = []

    /// [Batch 20 Fix 1] Why the most recent add/update/delete failed, if
    /// any. The form reads this immediately after a false Bool return —
    /// same actor, same call — so it always matches that call. Cleared
    /// on every success.
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


    /// [Batch 20 Fix 1] Returns whether the JSON actually landed on disk.
    /// Callers must roll their in-memory change back on false — a list that
    /// looks saved in memory but is gone after restart is the ENV-5 bug.
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

    /// [Batch 20 Fix 1] Returns whether the variable actually persisted
    /// (Keychain value + JSON list). False means nothing was saved and the
    /// form must stay open; see `lastSaveFailure` for the reason.
    @discardableResult
    func add(key: String, value: String, note: String = "") -> Bool {
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
        // JSON write failure must roll everything back, Keychain included:
        // no entry references this key (duplicates are rejected), so drop
        // the value just written — otherwise a secret persists for a
        // variable the list says was never saved.
        guard saveEntries() else {
            entries.removeAll { $0.id == entry.id }
            Self.deleteValue(forKey: trimmedKey)
            lastSaveFailure = .jsonFailed(trimmedKey)
            return false
        }
        lastSaveFailure = nil
        logger.info("Added env var: \(trimmedKey)")
        return true
    }

    /// Update an entry. Pass `note: nil` to leave the existing note untouched
    /// (used by the deep-link overwrite path which only updates the value).
    /// [Batch 20 Fix 1] Returns whether the update actually persisted;
    /// false leaves the old entry and the old Keychain value untouched.
    @discardableResult
    func update(id: String, key: String, value: String, note: String? = nil) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            lastSaveFailure = .entryMissing
            return false
        }

        let oldEntry = entries[idx]
        let oldKey = oldEntry.key
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
        // Read the old value BEFORE overwriting it: on a later JSON
        // failure the same-key path must put the old secret back, or
        // "not saved" would be a lie (the new value would already be
        // live in the Keychain). Nil means the old value was unreadable
        // and cannot be restored — logged on that path, not hidden.
        let oldValue = Self.loadValue(forKey: oldKey)
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
                // The write itself landed, so this is a verify failure, not
                // a write failure — say so, and drop the orphaned new-key
                // value so "not saved" stays true.
                deleteValueIfUnreferenced(forKey: trimmedKey)
                lastSaveFailure = .keychainVerifyFailed(trimmedKey)
                return false
            }
        }

        entries[idx].key = trimmedKey
        if let note { entries[idx].note = note }
        // JSON write failure rolls everything back. The old Keychain
        // value was never deleted (that happens only below, after the
        // JSON lands); the new value is undone here — same key: restore
        // the old secret; rename: drop the orphaned new-key value.
        guard saveEntries() else {
            entries[idx] = oldEntry
            if keyChanged {
                deleteValueIfUnreferenced(forKey: trimmedKey)
            } else if let oldValue {
                _ = Self.saveValue(oldValue, forKey: oldKey)
            } else {
                logger.error("Update env var rollback incomplete — old value of \(oldKey) was unreadable, new value remains in Keychain")
            }
            lastSaveFailure = .jsonFailed(trimmedKey)
            return false
        }

        if keyChanged {
            deleteValueIfUnreferenced(forKey: oldKey)
        }
        lastSaveFailure = nil
        logger.info("Updated env var: \(trimmedKey)")
        return true
    }

    /// Update only the human-readable note without touching the
    /// Keychain-stored value. Used by minis-config so the agent can
    /// annotate variables without ever seeing or overwriting the
    /// secret.
    /// [Batch 20 Fix 1] Returns whether the note actually persisted;
    /// a JSON failure rolls the note back and records the reason
    /// instead of failing silently.
    @discardableResult
    func updateNote(id: String, note: String) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            lastSaveFailure = .entryMissing
            return false
        }
        let oldNote = entries[idx].note
        entries[idx].note = note
        guard saveEntries() else {
            entries[idx].note = oldNote
            lastSaveFailure = .jsonFailed(entries[idx].key)
            return false
        }
        lastSaveFailure = nil
        return true
    }

    /// [Batch 20 Fix 1] Returns whether the deletion actually persisted.
    /// The Keychain value is dropped only after the JSON lands — deleting
    /// it first used to lose the secret when the JSON write then failed
    /// and the entry came back on restart with a blank value.
    @discardableResult
    func delete(id: String) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            lastSaveFailure = .entryMissing
            return false
        }
        let entry = entries[idx]
        let key = entry.key
        entries.remove(at: idx)
        guard saveEntries() else {
            entries.insert(entry, at: idx)
            lastSaveFailure = .jsonFailed(key)
            return false
        }
        deleteValueIfUnreferenced(forKey: key)
        // Mark the entry's per-key record for cloud deletion. Peers will
        // hard-delete it via applyEnvVarItemDeletion. The recordId is the
        // entry UUID, not the key — same as upsert path.
        lastSaveFailure = nil
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
