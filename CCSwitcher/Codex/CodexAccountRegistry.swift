import Foundation

/// Persists Codex accounts under their own `UserDefaults` key, separate from
/// `AppState`'s Claude account array, so a Codex row can never leak into
/// `AppState.loadAccounts` and corrupt its active-account tracking.
enum CodexAccountRegistry {
    static let storageKey = "com.ccswitcher.accounts.codex"

    static func load(from defaults: UserDefaults = .standard) -> [Account] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    static func save(_ accounts: [Account], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Returns a copy with exactly the given id active, or none if it is absent.
    static func markActive(id: UUID, in accounts: [Account]) -> [Account] {
        accounts.map { account in
            var account = account
            account.isActive = account.id == id
            return account
        }
    }
}
