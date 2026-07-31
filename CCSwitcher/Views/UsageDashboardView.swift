import SwiftUI

/// Hover tooltip that works inside MenuBarExtra panels (where `.help()` doesn't).
private struct StatWithTooltip<Content: View>: View {
    let tooltip: LocalizedStringKey
    @ViewBuilder let content: Content
    @State private var isHovering = false
    @Environment(\.locale) private var locale

    var body: some View {
        content
            .onHover { isHovering = $0 }
            .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                Text(tooltip)
                    .font(.caption)
                    .padding(8)
                    .frame(width: 200)
                    .environment(\.locale, locale)
            }
    }
}

/// Shows real usage limits from Claude API, one card per account.
struct UsageDashboardView: View {
    @EnvironmentObject private var hub: ProviderHub
    @Environment(\.providerTheme) private var theme

    var body: some View {
        let surface = hub.surface
        ScrollView {
            VStack(spacing: 16) {
                if surface.accountCards.isEmpty && surface.isLoading {
                    loadingState
                } else if surface.accountCards.isEmpty {
                    emptyState
                } else {
                    todayCostBanner(surface.cost.todayCost)
                    todayActivityCard(surface.activity)
                    ForEach(surface.accountCards) { card in
                        accountUsageCard(card)
                    }
                }

                if let lastRefresh = surface.lastRefresh {
                    HStack(spacing: 4) {
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                        Text(lastRefresh, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
            // Report this VStack's intrinsic height to MainMenuView so it can
            // size the popover frame to fit the Usage tab's content exactly.
            // See MainMenuView.swift for the measurement contract.
            .measureUsageContentHeight()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Loading usage data...")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundStyle(theme.textSecondary)
            Text("Usage data unavailable")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Today Cost Banner

    private func todayCostBanner(_ cost: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                Text("Today's API-Equivalent Cost")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
            }

            StatWithTooltip(tooltip: Self.costDisclaimer) {
                Text(Formatters.currency(cost))
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }
        }
        .cardStyle(fill: theme.cardFill, border: theme.cardBorder)
        .sectionPadding()
    }

    private static let costDisclaimer: LocalizedStringKey = "Estimated API-equivalent cost of your Claude Code usage, for reference only."

    // MARK: - Today Activity Card

    private func todayActivityCard(_ activity: ActivitySummaryModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.subheadline)
                    .foregroundStyle(theme.accent)
                Text("Today's Activity")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            HStack(spacing: 0) {
                activityStat(icon: "bubble.left.and.bubble.right", value: "\(activity.turns)", label: "Turns",
                             tooltip: "Messages you sent today")
                activityStat(icon: "clock", value: activity.activeTimeText, label: "Active",
                             tooltip: "Estimated total time the agent worked for you today. Parallel sessions stack. Idle gaps >10 min excluded. This is an approximation based on message timestamps, not exact.")
                if let lines = activity.linesWritten {
                    activityStat(icon: "doc.text", value: "\(lines)", label: "Lines",
                                 tooltip: "Estimated lines of code written via file-editing tools")
                }
            }

            if !activity.perModel.isEmpty {
                HStack(spacing: 0) {
                    ForEach(activity.perModel) { entry in
                        modelStat(entry)
                    }
                }
            }
        }
        .cardStyle(fill: theme.cardFill, border: theme.cardBorder)
        .sectionPadding()
    }

    private func activityStat(icon: String, value: String, label: LocalizedStringKey, tooltip: LocalizedStringKey) -> some View {
        StatWithTooltip(tooltip: tooltip) {
            VStack(spacing: 3) {
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func modelStat(_ entry: ModelUsageEntry) -> some View {
        VStack(spacing: 3) {
            Text("\(entry.count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(entry.count > 0 ? .primary : .quaternary)
            HStack(spacing: 3) {
                Circle()
                    .fill(entry.tint)
                    .frame(width: 7, height: 7)
                Text(entry.displayName)
                    .font(.caption2)
                    .foregroundStyle(entry.count > 0 ? .tertiary : .quaternary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Per-Account Card

    private func accountUsageCard(_ card: UsageCardModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            accountHeader(card)

            if let error = card.error, card.windows.isEmpty {
                errorRow(error)
            } else if card.isEmpty {
                noticeRow(icon: "exclamationmark.triangle", tint: .yellow,
                          text: Text("No usage data yet — refresh to fetch."))
            } else {
                ForEach(card.windows) { window in
                    usageRow(labelView: label(for: window), dotColor: nil,
                             resetText: UsageWindowFormat.resetText(until: window.resetsAt),
                             utilization: window.utilization)
                }
                ForEach(card.scopedLimits) { limit in
                    usageRow(labelView: Text(limit.modelName), dotColor: limit.tint,
                             resetText: UsageWindowFormat.resetText(until: limit.resetsAt),
                             utilization: limit.utilization)
                }
                if let credits = card.credits {
                    creditsRow(credits)
                }
                if let error = card.error {
                    errorRow(error)
                }
            }

            if let notice = card.notice {
                noticeRow(icon: "info.circle", tint: .orange, text: Text(notice))
            }
        }
        // The pre-migration code read `account.isActive ? .cardFill : .cardFill`,
        // i.e. the active account got no emphasis. Kept identical so this stage
        // changes no pixels; giving the active card `cardFillStrong` is a
        // reasonable improvement but belongs in its own change.
        .cardStyle(fill: theme.cardFill, border: theme.cardBorder)
        .sectionPadding()
    }

    private func label(for window: UsageWindowModel) -> Text {
        switch window.kind {
        case .session: return Text("Session")
        case .weekly: return Text("Weekly")
        case .other(let seconds): return Text(UsageWindowFormat.durationText(seconds: seconds))
        }
    }

    @ViewBuilder
    private func accountHeader(_ card: UsageCardModel) -> some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: hub.activeProvider, size: 15)
                .foregroundStyle(card.isActive ? theme.accent : theme.textSecondary)

            Text(card.subtitle ?? card.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if card.isActive {
                Badge(text: String(localized: "Active", bundle: L10n.bundle), color: .green)
            }

            Spacer()

            if let plan = card.planBadge {
                Badge(text: plan, color: theme.accent, foreground: theme.accentForeground)
            }
        }
    }

    @ViewBuilder
    private func creditsRow(_ credits: CreditPoolModel) -> some View {
        let tint: Color = credits.isEnabled ? .orange : .gray
        HStack(spacing: 6) {
            Image(systemName: credits.isEnabled ? "bolt.fill" : "bolt.slash")
                .font(.caption)
                .foregroundStyle(tint)
            Text("Extra usage")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            if credits.isUnlimited {
                Text("Unlimited")
                    .font(.caption)
                    .foregroundStyle(tint)
            } else if let balance = credits.balanceText {
                Text(balance)
                    .font(.caption)
                    .foregroundStyle(tint)
            } else {
                Text(LocalizedStringKey(credits.isEnabled ? "On" : "Off"))
                    .font(.caption)
                    .foregroundStyle(tint)
            }
        }
    }

    private func errorRow(_ error: ProviderErrorModel) -> some View {
        let icon = error.isRateLimited ? "timer" : (error.needsReauth ? "exclamationmark.triangle" : "xmark.circle")
        return noticeRow(icon: icon, tint: error.needsReauth ? .yellow : .red, text: Text(error.message))
    }

    private func noticeRow(icon: String, tint: Color, text: Text) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(tint)
            text
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Usage Row

    private func usageRow(labelView: Text, dotColor: Color?, resetText: String?, utilization: Double) -> some View {
        VStack(spacing: 5) {
            HStack {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                }
                labelView
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                if let resetText {
                    Text("Resets in \(resetText)")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(theme.progressTrack)
                            .frame(height: 7)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(theme.utilizationColor(utilization))
                            .frame(width: max(0, geo.size.width * min(utilization / 100.0, 1.0)), height: 7)
                    }
                }
                .frame(height: 7)

                Text("\(Int(utilization))%")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(theme.utilizationColor(utilization))
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}
