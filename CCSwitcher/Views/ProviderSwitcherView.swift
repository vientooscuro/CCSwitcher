import SwiftUI

/// Compact icon segmented control in the popover header. Renders only when more
/// than one provider is installed, so a Claude-only Mac sees no change.
struct ProviderSwitcherView: View {
    @EnvironmentObject private var hub: ProviderHub
    @Environment(\.providerTheme) private var theme

    var body: some View {
        if hub.showsSwitcher {
            HStack(spacing: 2) {
                ForEach(hub.available) { provider in
                    let isSelected = provider == hub.activeProvider
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            hub.select(provider)
                        }
                    } label: {
                        ProviderIcon(provider: provider, size: 12)
                            .frame(width: 26, height: 22)
                            .foregroundStyle(isSelected ? theme.tabSelectedForeground : theme.textSecondary)
                            .background(
                                Capsule().fill(isSelected ? theme.tabSelectedFill : Color.clear)
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(provider.rawValue)
                    .accessibilityLabel(provider.rawValue)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(
                Capsule()
                    .fill(theme.tabFill)
                    .overlay(Capsule().stroke(theme.tabBorder, lineWidth: 1))
            )
        }
    }
}
