import Foundation

/// Which providers are usable on this machine, and which one is active.
///
/// Detection is injectable so it is testable without touching the real
/// filesystem or forking the Claude CLI.
enum ProviderRegistry {

    /// Ordered so the switcher's segments never reshuffle between launches.
    private static let displayOrder: [AIProviderType] = [.claudeCode, .codex, .gemini]

    static func detect(
        claudeInstalled: Bool,
        fileExists: (String) -> Bool
    ) -> [AIProviderType] {
        var available: [AIProviderType] = []
        if claudeInstalled { available.append(.claudeCode) }
        if fileExists(codexAuthPath) { available.append(.codex) }

        // Never return empty: the hub must always have a surface to render, and
        // a Claude-shaped empty state is the same thing the app shows today
        // when the CLI is missing.
        return available.isEmpty ? [.claudeCode] : available.sorted { lhs, rhs in
            (displayOrder.firstIndex(of: lhs) ?? Int.max) < (displayOrder.firstIndex(of: rhs) ?? Int.max)
        }
    }

    static var codexAuthPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")
    }

    /// Pick the active provider, honouring the user's persisted choice unless
    /// that provider is no longer installed.
    static func resolveActive(persisted: String?, available: [AIProviderType]) -> AIProviderType {
        if let persisted, let provider = AIProviderType(rawValue: persisted), available.contains(provider) {
            return provider
        }
        return available.first ?? .claudeCode
    }
}
