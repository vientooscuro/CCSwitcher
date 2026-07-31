import SwiftUI

/// Per-provider visual tokens. Injected through `Environment` so shared
/// components restyle without knowing which provider is active.
struct ProviderTheme {
    enum Panel {
        case material(Material)
        case flat(Color)
    }

    let panel: Panel
    let accent: Color
    let accentForeground: Color
    let cardFill: Color
    let cardFillStrong: Color
    let cardBorder: Color
    let textPrimary: Color
    let textSecondary: Color
    let tabFill: Color
    let tabBorder: Color
    let tabSelectedFill: Color
    let tabSelectedForeground: Color
    let progressTrack: Color
    let subtleAccent: Color
    /// Forced appearance. Nil means follow the system, which is what Claude does.
    let forcedColorScheme: ColorScheme?

    /// Utilization ramp. Kept semantic in every theme: a monochrome bar makes
    /// the number unreadable at a glance, which defeats the point of the bar.
    func utilizationColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 60 { return .orange }
        return .green
    }
}

extension ProviderTheme {
    /// Today's look, unchanged.
    static let claude = ProviderTheme(
        panel: .material(.ultraThinMaterial),
        accent: .brand,
        accentForeground: .white,
        cardFill: .cardFill,
        cardFillStrong: .cardFillStrong,
        cardBorder: .cardBorder,
        textPrimary: .textPrimary,
        textSecondary: .textSecondary,
        tabFill: .tabFill,
        tabBorder: .tabBorder,
        tabSelectedFill: .brand,
        tabSelectedForeground: .white,
        progressTrack: .progressTrack,
        subtleAccent: .subtleBrand,
        forcedColorScheme: nil
    )

    static func theme(for provider: AIProviderType) -> ProviderTheme {
        switch provider {
        case .claudeCode: return .claude
        case .codex: return .claude   // replaced by the Codex theme in stage 2
        case .gemini: return .claude
        }
    }
}

private struct ProviderThemeKey: EnvironmentKey {
    static let defaultValue: ProviderTheme = .claude
}

extension EnvironmentValues {
    var providerTheme: ProviderTheme {
        get { self[ProviderThemeKey.self] }
        set { self[ProviderThemeKey.self] = newValue }
    }
}
