import Foundation
import Security

private let log = FileLog("Keychain")

/// Per-account backup: keychain token + oauthAccount from ~/.claude.json
///
/// `@unchecked Sendable` — `AnyCodable` wraps `Any`, but in practice we only
/// store immutable JSON-derived values (NSNumber/NSString/NSNull/Array/Dict
/// of the same), so passing snapshots across actors is safe.
struct AccountBackup: Codable, @unchecked Sendable {
    let token: String
    let oauthAccount: [String: AnyCodable]
}

/// Type-erased Codable wrapper for heterogeneous JSON values.
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a }
        else if let o = try? container.decode([String: AnyCodable].self) { value = o }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        case let a as [AnyCodable]: try container.encode(a)
        case let o as [String: AnyCodable]: try container.encode(o)
        default: throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Unsupported type"))
        }
    }
}

/// Manages token + identity storage as an actor.
///
/// Calls fork `/usr/bin/security` and parse `~/.claude.json` (which can be
/// 1–10 MB) — none of that should ever happen on the main thread. Wrapping
/// the type as an `actor` guarantees every call hops to a dedicated
/// executor; chains like `switchAccount` no longer freeze the UI.
///
/// In-memory backup-store cache: `loadBackupStore` used to hit Keychain +
/// `JSONDecoder` once per `getAccountBackup` call. With N accounts and a
/// `fetchAllAccountUsage` round, that meant 2N round-trips per refresh.
/// We now keep the decoded dict in memory and invalidate on writes.
actor KeychainService {
    static let shared = KeychainService()

    private let claudeService = "Claude Code-credentials"
    private let claudeAccount: String
    private let backupsFilePath: String
    private let claudeJsonPath: String

    /// In-memory mirror of the backup store. Loaded lazily.
    private var backupCache: [String: AccountBackup]?

    private init() {
        self.claudeAccount = NSUserName()

        let home = NSHomeDirectory()
        let dir = home + "/.ccswitcher"
        self.backupsFilePath = dir + "/backups.json"
        self.claudeJsonPath = home + "/.claude.json"

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Migrate legacy tokens.json (token-only, can't be salvaged)
        let oldPath = dir + "/tokens.json"
        if FileManager.default.fileExists(atPath: oldPath) && !FileManager.default.fileExists(atPath: backupsFilePath) {
            log.info("init: Migrating tokens.json → backups.json (old format, token-only entries)")
            try? FileManager.default.removeItem(atPath: oldPath)
        }

        log.info("init: claudeAccount=\(claudeAccount), backupsFile=\(backupsFilePath)")
    }

    // MARK: - Claude Code Token Operations (keychain via `security` CLI)

    func readClaudeToken() -> String? {
        let token = runSecurity(args: [
            "find-generic-password",
            "-s", claudeService,
            "-a", claudeAccount,
            "-w"
        ])

        if let token {
            let sanitized = token.trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("[readClaudeToken] Found via security CLI, length=\(sanitized.count)")
            return sanitized
        } else {
            log.error("[readClaudeToken] No token found!")
            return nil
        }
    }

    func writeClaudeToken(_ token: String) -> Bool {
        _ = runSecurityStatus(args: ["delete-generic-password", "-s", claudeService, "-a", claudeAccount])

        let added = runSecurityStatus(args: [
            "add-generic-password",
            "-s", claudeService,
            "-a", claudeAccount,
            "-w", token,
            "-U"
        ])
        log.info("[writeClaudeToken] Result: \(added)")
        return added
    }

    // MARK: - ~/.claude.json oauthAccount Operations
    //
    // Both read and write use `JSONSerialization` directly. The previous
    // implementation round-tripped the entire ~/.claude.json (often several
    // MB) through `[String: AnyCodable]` codable trees, which was a
    // 100–500ms freeze on main thread. Now we touch only the `oauthAccount`
    // sub-tree.

    func readOAuthAccount() -> [String: AnyCodable]? {
        guard let data = FileManager.default.contents(atPath: claudeJsonPath),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let oauth = json["oauthAccount"] as? [String: Any] else {
            log.error("[readOAuthAccount] Failed to read oauthAccount from \(claudeJsonPath)")
            return nil
        }
        let wrapped = Self.wrap(oauth) as? [String: AnyCodable] ?? [:]
        let email = (wrapped["emailAddress"]?.value as? String) ?? "?"
        log.info("[readOAuthAccount] Found: email=\(email)")
        return wrapped
    }

    func writeOAuthAccount(_ oauthAccount: [String: AnyCodable]) -> Bool {
        guard let data = FileManager.default.contents(atPath: claudeJsonPath),
              var json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            log.error("[writeOAuthAccount] Failed to read \(claudeJsonPath)")
            return false
        }

        json["oauthAccount"] = Self.unwrap(oauthAccount)

        do {
            let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try newData.write(to: URL(fileURLWithPath: claudeJsonPath), options: .atomic)
            let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
            log.info("[writeOAuthAccount] Written: email=\(email)")
            return true
        } catch {
            log.error("[writeOAuthAccount] Failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Account Backup Operations (token + oauthAccount)

    func saveAccountBackup(token: String, oauthAccount: [String: AnyCodable], forAccountId accountId: String) -> Bool {
        let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
        log.info("[saveBackup] Saving for \(accountId) (\(email)), token length=\(token.count)")
        var store = loadBackupStore()
        store[accountId] = AccountBackup(token: token, oauthAccount: oauthAccount)
        let result = saveBackupStore(store)
        if result { backupCache = store }
        log.info("[saveBackup] Result: \(result)")
        return result
    }

    func getAccountBackup(forAccountId accountId: String) -> AccountBackup? {
        let store = loadBackupStore()
        let backup = store[accountId]
        if let backup {
            let email = (backup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
            log.info("[getBackup] Found for \(accountId) (\(email)), token length=\(backup.token.count)")
        } else {
            log.error("[getBackup] No backup for accountId=\(accountId)")
        }
        return backup
    }

    @discardableResult
    func removeAccountBackup(forAccountId accountId: String) -> Bool {
        log.info("[removeBackup] Removing for accountId=\(accountId)")
        var store = loadBackupStore()
        store.removeValue(forKey: accountId)
        let ok = saveBackupStore(store)
        if ok { backupCache = store }
        return ok
    }

    // MARK: - App Keychain operations (Backups)

    private let appBackupService = "me.xueshi.ccswitcher.backups"
    private let appBackupAccount = "all-accounts"

    private func loadBackupStore() -> [String: AccountBackup] {
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

        if status == errSecSuccess, let data = item as? Data,
           let dict = try? JSONDecoder().decode([String: AccountBackup].self, from: data) {
            log.debug("[loadBackupStore] Loaded \(dict.count) entries from Keychain")
            backupCache = dict
            return dict
        }

        // One-shot migration from local file
        if FileManager.default.fileExists(atPath: backupsFilePath),
           let data = FileManager.default.contents(atPath: backupsFilePath),
           let dict = try? JSONDecoder().decode([String: AccountBackup].self, from: data) {
            log.info("[loadBackupStore] Migrating from local backups.json to Keychain...")
            _ = saveBackupStore(dict)
            try? FileManager.default.removeItem(atPath: backupsFilePath)
            log.info("[loadBackupStore] Migration complete, local backups.json removed")
            backupCache = dict
            return dict
        }

        log.debug("[loadBackupStore] No existing backups, returning empty")
        backupCache = [:]
        return [:]
    }

    private func saveBackupStore(_ store: [String: AccountBackup]) -> Bool {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(store)

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

    // MARK: - `security` CLI (only for Claude's keychain entry)

    private func runSecurity(args: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                log.debug("[runSecurity] Exit \(process.terminationStatus) for: security \(args.prefix(3).joined(separator: " "))...")
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == true ? nil : output
        } catch {
            log.error("[runSecurity] Launch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func runSecurityStatus(args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            if !ok {
                log.debug("[runSecurityStatus] Exit \(process.terminationStatus) for: security \(args.prefix(3).joined(separator: " "))...")
            }
            return ok
        } catch {
            log.error("[runSecurityStatus] Launch failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - AnyCodable <-> plain JSON helpers

    /// Convert a plain JSONSerialization tree (NSNumber/NSString/NSNull/Array/Dict)
    /// into `AnyCodable`-wrapped form for the legacy in-memory representation.
    private static func wrap(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return dict.mapValues { AnyCodable(wrap($0)) }
        }
        if let arr = value as? [Any] {
            return arr.map { AnyCodable(wrap($0)) }
        }
        return value
    }

    /// Walk an `AnyCodable`-wrapped tree and produce a plain Foundation tree
    /// suitable for `JSONSerialization.data(withJSONObject:)`.
    private static func unwrap(_ value: Any) -> Any {
        if let ac = value as? AnyCodable { return unwrap(ac.value) }
        if let dict = value as? [String: AnyCodable] { return dict.mapValues(unwrap) }
        if let arr = value as? [AnyCodable] { return arr.map(unwrap) }
        if let dict = value as? [String: Any] { return dict.mapValues(unwrap) }
        if let arr = value as? [Any] { return arr.map(unwrap) }
        return value
    }
}
