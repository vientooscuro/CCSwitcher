import SwiftUI

/// The main popover content shown when clicking the menubar icon.
struct MainMenuView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("refreshInterval") private var refreshInterval: Double = 300
    @AppStorage("showFullEmail") private var showFullEmail = false
    @State private var selectedTab: Tab = .usage

    enum Tab: String, CaseIterable {
        case usage, costs, accounts

        var localizedTitle: LocalizedStringKey {
            switch self {
            case .usage: "Usage"
            case .costs: "Costs"
            case .accounts: "Accounts"
            }
        }

        var iconName: String {
            switch self {
            case .usage: "chart.bar.fill"
            case .costs: "dollarsign.circle.fill"
            case .accounts: "person.2.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Tab selector
            tabBar

            // Content
            Group {
                switch selectedTab {
                case .usage:
                    UsageDashboardView()
                case .costs:
                    CostDetailView()
                case .accounts:
                    AccountSwitcherView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer
            footerView
        }
        .frame(width: 360, height: 540)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(.brand)

            VStack(alignment: .leading, spacing: 3) {
                if let account = appState.activeAccount {
                    HStack(spacing: 6) {
                        Text(account.effectiveDisplayName(obfuscated: !showFullEmail))
                            .font(.headline)
                        if let sub = account.displaySubscriptionType {
                            Badge(text: sub, color: .brand)
                        }
                    }
                    Text(account.displayEmail(obfuscated: !showFullEmail))
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                } else {
                    Text("CCSwitcher")
                        .font(.headline)
                    Text("No account connected")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }

            Spacer()

            if appState.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ZStack {
            // Background capsule
            Capsule()
                .fill(.tabFill)
                .overlay(Capsule().stroke(.tabBorder, lineWidth: 1))

            // Sliding indicator
            GeometryReader { geo in
                let count = CGFloat(Tab.allCases.count)
                let tabWidth = geo.size.width / count
                let index = CGFloat(Tab.allCases.firstIndex(of: selectedTab) ?? 0)
                Capsule()
                    .fill(Color.brand)
                    .padding(2)
                    .frame(width: tabWidth)
                    .offset(x: tabWidth * index)
                    .animation(.easeInOut(duration: 0.15), value: selectedTab)
            }

            // Tab labels on top
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    VStack(spacing: 2) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 12))
                        Text(tab.localizedTitle)
                            .font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selectedTab == tab ? .white : .textSecondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    }
                }
            }
        }
        .frame(width: 260, height: 44)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if let error = appState.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task { await appState.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Refresh")

            Button {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: .ccswitcherOpenSettings,
                    object: nil
                )
            } label: {
                Image(systemName: "gear")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Quit")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
