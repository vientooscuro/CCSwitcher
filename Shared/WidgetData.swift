import Foundation

/// Data shared between the main app and widget via direct file in the widget's sandbox container.
///
/// The main app (non-sandboxed) writes a JSON file into the widget extension's container directory.
/// The widget (sandboxed) reads from its own Application Support, which maps to the same path.
/// A model-scoped rate-limit (e.g. a separate Fable 5 weekly limit), flattened
/// for the widget. Only populated when the subscription carries such a limit.
struct WidgetScopedLimit: Codable, Hashable {
    let modelName: String
    let utilization: Double
    let resetTime: String?
}

struct WidgetAccountData: Codable {
    let email: String          // pre-obfuscated
    let displayName: String    // pre-obfuscated
    let subscriptionType: String?
    let isActive: Bool
    let sessionUtilization: Double?
    let sessionResetTime: String?
    let weeklyUtilization: Double?
    let weeklyResetTime: String?
    let extraUsageEnabled: Bool?
    let hasError: Bool
    let errorMessage: String?
    // Optional for backward-compatible decode of older widget-data.json files.
    let scopedLimits: [WidgetScopedLimit]?
}

struct WidgetData: Codable {
    let accounts: [WidgetAccountData]
    let todayCost: Double
    let conversationTurns: Int
    let activeCodingTime: String
    let linesWritten: Int
    let modelUsage: [String: Int]
    let lastUpdated: Date
    /// Raw value of `AIProviderType`. Optional so a snapshot written by an
    /// older build still decodes — the widget then falls back to Claude
    /// styling. Kept `Codable`-synthesized (no custom `init(from:)`), which is
    /// what makes a missing key decode as nil rather than fail.
    let provider: String?

    init(
        accounts: [WidgetAccountData],
        todayCost: Double,
        conversationTurns: Int,
        activeCodingTime: String,
        linesWritten: Int,
        modelUsage: [String: Int],
        lastUpdated: Date,
        provider: String? = nil
    ) {
        self.accounts = accounts
        self.todayCost = todayCost
        self.conversationTurns = conversationTurns
        self.activeCodingTime = activeCodingTime
        self.linesWritten = linesWritten
        self.modelUsage = modelUsage
        self.lastUpdated = lastUpdated
        self.provider = provider
    }

    // Team-ID-prefixed App Group. macOS Sequoia (15+) prompts for App
    // Management on `group.<bundle-id>` style identifiers; the
    // `<TEAMID>.<bundle-id>` form is auto-authorized for Developer-ID-signed
    // apps without a provisioning profile and avoids the prompt entirely.
    private static let appGroupID = "XTPJK8U436.com.vientooscuro.ccswitcher"
    private static let fileName = "widget-data.json"

    private static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Load from the shared App Group container.
    static func load() -> WidgetData? {
        guard let containerURL = sharedContainerURL else { return nil }
        return try? load(from: containerURL)
    }

    static func load(provider: String) -> WidgetData? {
        guard let containerURL = sharedContainerURL else { return nil }
        return try? load(provider: provider, from: containerURL)
    }

    /// Save to the shared App Group container.
    func save() {
        guard let containerURL = Self.sharedContainerURL else { return }
        try? save(to: containerURL)
    }

    static func load(from directory: URL) throws -> WidgetData? {
        try load(fileName: fileName, from: directory)
    }

    static func load(provider: String, from directory: URL) throws -> WidgetData? {
        try load(fileName: providerFileName(provider), from: directory)
    }

    func save(to directory: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
        if let provider {
            try data.write(to: directory.appendingPathComponent(Self.providerFileName(provider)), options: .atomic)
        }
    }

    private static func load(fileName: String, from directory: URL) throws -> WidgetData? {
        let fileURL = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(WidgetData.self, from: Data(contentsOf: fileURL))
    }

    private static func providerFileName(_ provider: String) -> String {
        let slug = provider.lowercased().filter { $0.isLetter || $0.isNumber }
        return "widget-data-\(slug).json"
    }
}
