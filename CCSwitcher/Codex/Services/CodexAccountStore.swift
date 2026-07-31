import Foundation
import Security

private let log = FileLog("CodexAccountStore")

/// Per-account backups of `~/.codex/auth.json`, one Keychain item holding a
/// JSON dictionary keyed by account id — mirrors `KeychainService`'s Claude
/// backup store, but the value is the raw `auth.json` text rather than the
/// Claude-shaped `AccountBackup` struct.
actor CodexAccountStore {
    static let shared = CodexAccountStore()

    private let appBackupService = "com.vientooscuro.ccswitcher.codex.backups"
    private let appBackupAccount = "all-accounts"

    /// In-memory mirror of the backup store. Loaded lazily.
    private var backupCache: [String: String]?

    /// Entire `auth.json` text for `accountId`, or nil.
    func backup(forAccountId accountId: String) -> String? {
        let backup = loadBackupStore()[accountId]
        if let backup {
            log.info("[backup] Found for \(accountId), length=\(backup.count)")
        } else {
            log.error("[backup] No backup for accountId=\(accountId)")
        }
        return backup
    }

    func saveBackup(_ authJSON: String, forAccountId accountId: String) -> Bool {
        log.info("[saveBackup] Saving for \(accountId), length=\(authJSON.count)")
        var store = loadBackupStore()
        store[accountId] = authJSON
        let result = saveBackupStore(store)
        if result { backupCache = store }
        log.info("[saveBackup] Result: \(result)")
        return result
    }

    @discardableResult
    func removeBackup(forAccountId accountId: String) -> Bool {
        log.info("[removeBackup] Removing for accountId=\(accountId)")
        var store = loadBackupStore()
        store.removeValue(forKey: accountId)
        let ok = saveBackupStore(store)
        if ok { backupCache = store }
        return ok
    }

    /// Ids that currently have a backup, from one store read.
    func backedUpAccountIds() -> Set<String> {
        Set(loadBackupStore().keys)
    }

    // MARK: - Serialization (pure, testable)

    static func encode(_ store: [String: String]) throws -> Data {
        try JSONEncoder().encode(store)
    }

    static func decode(_ data: Data) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: data)
    }

    /// Never throws: a corrupt or foreign Keychain item yields an empty
    /// store rather than bricking account switching.
    static func decodeLenient(_ data: Data) -> [String: String] {
        guard let decoded = try? decode(data) else {
            log.warning("[decodeLenient] Corrupt or foreign payload, returning empty store")
            return [:]
        }
        return decoded
    }

    // MARK: - Keychain operations

    private func loadBackupStore() -> [String: String] {
        if let cached = backupCache {
            return cached
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appBackupService,
            kSecAttrAccount as String: appBackupAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data {
            let dict = Self.decodeLenient(data)
            log.debug("[loadBackupStore] Loaded \(dict.count) entries from Keychain")
            backupCache = dict
            return dict
        }

        log.debug("[loadBackupStore] No existing backups, returning empty")
        backupCache = [:]
        return [:]
    }

    private func saveBackupStore(_ store: [String: String]) -> Bool {
        do {
            let data = try Self.encode(store)

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: appBackupService,
                kSecAttrAccount as String: appBackupAccount
            ]

            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]

            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

            if status == errSecItemNotFound {
                var newItem = query
                newItem[kSecValueData as String] = data
                status = SecItemAdd(newItem as CFDictionary, nil)
            }

            let success = status == errSecSuccess
            if success {
                log.debug("[saveBackupStore] Saved \(store.count) entries to Keychain")
            } else {
                log.error("[saveBackupStore] Failed to save to Keychain, OSStatus: \(status)")
            }
            return success
        } catch {
            log.error("[saveBackupStore] Failed: \(error.localizedDescription)")
            return false
        }
    }
}
