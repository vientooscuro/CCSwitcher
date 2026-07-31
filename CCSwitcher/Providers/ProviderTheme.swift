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

private extension Color {
    /// 24-bit hex, for themes transcribed from a design reference.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
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

    /// Modeled on ChatGPT Desktop: flat near-black, monochrome accents, hairline
    /// borders. No brand orange participates.
    ///
    /// Utilization colours stay semantic (see `utilizationColor`) — a monochrome
    /// bar makes the percentage unreadable at a glance, which defeats its purpose.
    static let codex = ProviderTheme(
        panel: .flat(Color(hex: 0x0D0D0D)),
        accent: Color(hex: 0xFFFFFF),
        accentForeground: Color(hex: 0x0D0D0D),
        cardFill: Color(hex: 0x171717),
        cardFillStrong: Color(hex: 0x1F1F1F),
        cardBorder: Color(hex: 0x2E2E2E),
        textPrimary: Color(hex: 0xECECEC),
        textSecondary: Color(hex: 0x9A9A9A),
        tabFill: Color(hex: 0x161616),
        tabBorder: Color(hex: 0x2E2E2E),
        tabSelectedFill: Color(hex: 0x303030),
        tabSelectedForeground: Color(hex: 0xFFFFFF),
        progressTrack: Color(hex: 0x2A2A2A),
        subtleAccent: Color(hex: 0x1A1A1A),
        forcedColorScheme: .dark
    )

    static func theme(for provider: AIProviderType) -> ProviderTheme {
        switch provider {
        case .claudeCode: return .claude
        case .codex: return .codex
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
