import SwiftUI

/// Reusable capsule badge for status indicators (subscription type, active state, etc.).
struct Badge: View {
    let text: String
    let color: Color
    /// Text colour. Defaults to white, which reads on every Claude-theme badge
    /// colour — but the Codex theme's accent is white itself, so callers using a
    /// theme accent must pass that theme's `accentForeground` instead.
    var foreground: Color = .white

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, AppStyle.badgeHPadding)
            .padding(.vertical, AppStyle.badgeVPadding)
            .background(color, in: Capsule())
    }
}
