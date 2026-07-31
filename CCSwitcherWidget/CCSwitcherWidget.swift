import WidgetKit
import SwiftUI

// MARK: - Brand Color

private let brandColor = Color(red: 0xE8 / 255.0, green: 0x6D / 255.0, blue: 0x45 / 255.0)

// MARK: - Provider Theme

/// Widget-local palette, keyed off `WidgetData.provider`. Not shared with
/// `CCSwitcher/Providers/ProviderTheme.swift` — that struct's Codex colours
/// route through `CCSwitcher/Models/AppStyle.swift` and `BrandColor.swift`,
/// which are app-target-only files the sandboxed widget extension cannot see.
/// The six Codex hex values below are transcribed from there; keep them
/// in sync if that source ever changes.
private struct WidgetTheme {
    let accent: Color
    let containerBackground: AnyShapeStyle
    let cardFill: Color
    let cardBorder: Color
    let textPrimary: AnyShapeStyle
    let textSecondary: AnyShapeStyle
    let textTertiary: AnyShapeStyle
    let quaternary: AnyShapeStyle

    /// Today's look, unchanged: system materials and semantic text styles.
    static let claude = WidgetTheme(
        accent: brandColor,
        containerBackground: AnyShapeStyle(.fill.tertiary),
        cardFill: Color.white.opacity(0.04),
        cardBorder: Color.white.opacity(0.08),
        textPrimary: AnyShapeStyle(.primary),
        textSecondary: AnyShapeStyle(.secondary),
        textTertiary: AnyShapeStyle(.tertiary),
        quaternary: AnyShapeStyle(.quaternary)
    )

    /// Modeled on ChatGPT Desktop: flat near-black, monochrome accents.
    /// Utilization colours stay semantic (`colorForUtilization`) in both
    /// themes — a monochrome bar makes the percentage unreadable at a glance.
    static let codex = WidgetTheme(
        accent: Color(hex: 0xFFFFFF),
        containerBackground: AnyShapeStyle(Color(hex: 0x0D0D0D)),
        cardFill: Color(hex: 0x171717),
        cardBorder: Color(hex: 0x2E2E2E),
        textPrimary: AnyShapeStyle(Color(hex: 0xECECEC)),
        textSecondary: AnyShapeStyle(Color(hex: 0x9A9A9A)),
        textTertiary: AnyShapeStyle(Color(hex: 0x9A9A9A)),
        quaternary: AnyShapeStyle(Color(hex: 0x9A9A9A).opacity(0.4))
    )

    static func theme(for provider: String?) -> WidgetTheme {
        provider == "Codex" ? .codex : .claude
    }
}

private extension Color {
    /// 24-bit hex, for the Codex palette transcribed from `ProviderTheme`.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Timeline Entry

struct CCSwitcherEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?

    static let placeholder = CCSwitcherEntry(
        date: .now,
        data: WidgetData(
            accounts: [
                WidgetAccountData(
                    email: "us***@ex***.com",
                    displayName: "My Org",
                    subscriptionType: "Pro",
                    isActive: true,
                    sessionUtilization: 42,
                    sessionResetTime: "2 hr 15 min",
                    weeklyUtilization: 28,
                    weeklyResetTime: "in 3 days",
                    extraUsageEnabled: true,
                    hasError: false,
                    errorMessage: nil,
                    scopedLimits: [WidgetScopedLimit(modelName: "Fable", utilization: 46, resetTime: "in 4 days")]
                )
            ],
            todayCost: 3.45,
            conversationTurns: 18,
            activeCodingTime: "1h 30m",
            linesWritten: 326,
            modelUsage: ["Fable": 18, "Opus": 12, "Sonnet": 5, "Haiku": 1],
            lastUpdated: .now
        )
    )
}

// MARK: - Timeline Provider

struct CCSwitcherProvider: TimelineProvider {
    func placeholder(in context: Context) -> CCSwitcherEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (CCSwitcherEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CCSwitcherEntry>) -> Void) {
        let entry = currentEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func currentEntry() -> CCSwitcherEntry {
        CCSwitcherEntry(date: .now, data: WidgetData.load())
    }
}

// MARK: - Widget Entry View

struct CCSwitcherWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: CCSwitcherEntry

    var body: some View {
        if let data = entry.data {
            let theme = WidgetTheme.theme(for: data.provider)
            switch family {
            case .systemSmall:
                SmallWidgetView(data: data, theme: theme)
            case .systemMedium:
                MediumWidgetView(data: data, theme: theme)
            case .systemLarge:
                LargeWidgetView(data: data, theme: theme)
            default:
                SmallWidgetView(data: data, theme: theme)
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 28))
                .foregroundStyle(brandColor)
                .widgetAccentable()
            Text("Open CCSwitcher")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("to load data")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Small Widget

private struct SmallWidgetView: View {
    let data: WidgetData
    let theme: WidgetTheme

    private var activeAccount: WidgetAccountData? {
        data.accounts.first(where: \.isActive) ?? data.accounts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header — icon + account + badge
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
                    .widgetAccentable()
                if let account = activeAccount {
                    Text(account.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if let sub = account.subscriptionType {
                        Text(sub)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(theme.accent.opacity(0.15), in: Capsule())
                    }
                } else {
                    Text("CCSwitcher")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                }
            }

            if let account = activeAccount {
                Spacer(minLength: 2)

                // Usage bars
                if account.hasError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                        if let msg = account.errorMessage {
                            Text(msg)
                                .font(.caption2)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(2)
                        } else {
                            Text("Error")
                                .font(.caption2)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                } else {
                    compactUsageBar(label: "Session", utilization: account.sessionUtilization)
                    compactUsageBar(label: "Weekly", utilization: account.weeklyUtilization)
                    ForEach(account.scopedLimits ?? [], id: \.modelName) { limit in
                        compactUsageBar(labelText: limit.modelName, utilization: limit.utilization)
                    }
                }

                Spacer(minLength: 2)

                // Today's cost
                HStack {
                    Text(formatCost(data.todayCost))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.green)
                    Text("today")
                        .font(.caption)
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                }
            } else {
                Spacer()
                Text("No accounts")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
        }
    }

    private func compactUsageBar(label: LocalizedStringKey, utilization: Double?) -> some View {
        compactUsageBar(labelView: Text(label), utilization: utilization)
    }

    private func compactUsageBar(labelText: String, utilization: Double?) -> some View {
        compactUsageBar(labelView: Text(labelText), utilization: utilization)
    }

    private func compactUsageBar(labelView: Text, utilization: Double?) -> some View {
        let pct = utilization ?? 0
        return VStack(spacing: 3) {
            HStack {
                labelView
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text("\(Int(pct))%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(colorForUtilization(pct))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(theme.quaternary)
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(colorForUtilization(pct))
                        .frame(width: max(0, geo.size.width * min(pct / 100.0, 1.0)), height: 5)
                }
            }
            .frame(height: 5)
        }
    }
}

// MARK: - Medium Widget

private struct MediumWidgetView: View {
    let data: WidgetData
    let theme: WidgetTheme

    private var activeAccount: WidgetAccountData? {
        data.accounts.first(where: \.isActive) ?? data.accounts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
                    .widgetAccentable()
                if let account = activeAccount {
                    Text(account.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if let sub = account.subscriptionType {
                        Text(sub)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(theme.accent.opacity(0.15), in: Capsule())
                    }
                }
                Spacer()
                Text(data.lastUpdated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 4)

            // Main content: usage bars on left, activity on right
            HStack(spacing: 12) {
                // Left: Usage bars
                VStack(alignment: .leading, spacing: 0) {
                    if let account = activeAccount {
                        if account.hasError {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                                if let msg = account.errorMessage {
                                    Text(msg)
                                        .font(.caption2)
                                        .foregroundStyle(theme.textSecondary)
                                        .lineLimit(2)
                                } else {
                                    Text("Error")
                                        .font(.caption2)
                                        .foregroundStyle(theme.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                            usageBar(label: "Session", utilization: account.sessionUtilization, resetTime: account.sessionResetTime)
                            Spacer(minLength: 4)
                            usageBar(label: "Weekly", utilization: account.weeklyUtilization, resetTime: account.weeklyResetTime)

                            ForEach(account.scopedLimits ?? [], id: \.modelName) { limit in
                                Spacer(minLength: 4)
                                usageBar(labelText: limit.modelName, utilization: limit.utilization, resetTime: limit.resetTime)
                            }

                            if let extra = account.extraUsageEnabled {
                                Spacer(minLength: 4)
                                HStack(spacing: 4) {
                                    Image(systemName: extra ? "bolt.fill" : "bolt.slash")
                                        .font(.caption2)
                                        .foregroundStyle(extra ? .orange : .gray)
                                    Text("Extra usage")
                                        .font(.caption2)
                                        .foregroundStyle(theme.textSecondary)
                                    Text(LocalizedStringKey(extra ? "On" : "Off"))
                                        .font(.caption2)
                                        .foregroundStyle(extra ? .orange : .gray)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Divider
                Rectangle()
                    .fill(theme.quaternary)
                    .frame(width: 1)

                // Right: Activity stats
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    statRow(icon: "dollarsign.circle", label: "Cost", value: formatCost(data.todayCost), valueColor: AnyShapeStyle(.green))
                    Spacer(minLength: 4)
                    statRow(icon: "bubble.left.and.bubble.right", label: "Turns", value: "\(data.conversationTurns)")
                    Spacer(minLength: 4)
                    statRow(icon: "clock", label: "Active", value: data.activeCodingTime)
                    Spacer(minLength: 4)
                    statRow(icon: "doc.text", label: "Lines", value: "\(data.linesWritten)")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func usageBar(label: LocalizedStringKey, utilization: Double?, resetTime: String?) -> some View {
        usageBar(labelView: Text(label), utilization: utilization, resetTime: resetTime)
    }

    private func usageBar(labelText: String, utilization: Double?, resetTime: String?) -> some View {
        usageBar(labelView: Text(labelText), utilization: utilization, resetTime: resetTime)
    }

    private func usageBar(labelView: Text, utilization: Double?, resetTime: String?) -> some View {
        let pct = utilization ?? 0
        return VStack(spacing: 3) {
            HStack {
                labelView
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                if let reset = resetTime {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(theme.textTertiary)
                }
                Text("\(Int(pct))%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(colorForUtilization(pct))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(theme.quaternary)
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(colorForUtilization(pct))
                        .frame(width: max(0, geo.size.width * min(pct / 100.0, 1.0)), height: 5)
                }
            }
            .frame(height: 5)
        }
    }

    private func statRow(icon: String, label: LocalizedStringKey, value: String, valueColor: AnyShapeStyle? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 14)
            Text(label)
                .font(.caption2)
                .foregroundStyle(theme.textTertiary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(valueColor ?? theme.textPrimary)
        }
    }
}

// MARK: - Large Widget

private struct LargeWidgetView: View {
    let data: WidgetData
    let theme: WidgetTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.subheadline)
                    .foregroundStyle(theme.accent)
                    .widgetAccentable()
                Text("CCSwitcher")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(data.lastUpdated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(theme.textTertiary)
            }

            // Today's activity + model usage
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    activityStat(icon: "bubble.left.and.bubble.right", value: "\(data.conversationTurns)", label: "Turns")
                    activityStat(icon: "clock", value: data.activeCodingTime, label: "Active")
                    activityStat(icon: "doc.text", value: "\(data.linesWritten)", label: "Lines")
                    activityStat(icon: "dollarsign.circle", value: formatCost(data.todayCost), label: "Cost", valueColor: AnyShapeStyle(.green))
                }

                if !data.modelUsage.isEmpty {
                    Rectangle()
                        .fill(theme.quaternary)
                        .frame(height: 0.5)
                        .padding(.horizontal, 8)

                    HStack(spacing: 0) {
                        modelStat(name: "Fable", count: data.modelUsage["Fable"] ?? 0, color: .purple)
                        modelStat(name: "Opus", count: data.modelUsage["Opus"] ?? 0, color: theme.accent)
                        modelStat(name: "Sonnet", count: data.modelUsage["Sonnet"] ?? 0, color: .blue)
                        modelStat(name: "Haiku", count: data.modelUsage["Haiku"] ?? 0, color: .green)
                    }
                }
            }
            .padding(.vertical, 10)
            .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            // Per-account cards — expand to fill remaining space
            ForEach(Array(data.accounts.enumerated()), id: \.offset) { _, account in
                accountCard(account)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func activityStat(icon: String, value: String, label: LocalizedStringKey, valueColor: AnyShapeStyle? = nil) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(valueColor ?? theme.textPrimary)
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func modelStat(name: String, count: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(count > 0 ? theme.textPrimary : theme.quaternary)
            HStack(spacing: 3) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(count > 0 ? theme.textTertiary : theme.quaternary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func accountCard(_ account: WidgetAccountData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Account header
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.caption2)
                    .foregroundStyle(account.isActive ? AnyShapeStyle(theme.accent) : theme.textSecondary)
                Text(account.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if account.isActive {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(
                            Capsule()
                                .stroke(Color.green, lineWidth: 1)
                        )
                }
                Spacer()
                if let sub = account.subscriptionType {
                    Text(sub)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.accent)
                }
            }

            if account.hasError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    if let msg = account.errorMessage {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    } else {
                        Text("Error")
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            } else {
                accountUsageBar(label: "Session", utilization: account.sessionUtilization, resetTime: account.sessionResetTime)
                accountUsageBar(label: "Weekly", utilization: account.weeklyUtilization, resetTime: account.weeklyResetTime)
                ForEach(account.scopedLimits ?? [], id: \.modelName) { limit in
                    accountUsageBar(labelText: limit.modelName, utilization: limit.utilization, resetTime: limit.resetTime)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(account.isActive ? theme.accent.opacity(0.22) : theme.cardFill)
                .strokeBorder(account.isActive ? theme.accent.opacity(0.6) : theme.cardBorder, lineWidth: account.isActive ? 1.0 : 0.5)
        )
    }

    private func accountUsageBar(label: LocalizedStringKey, utilization: Double?, resetTime: String?) -> some View {
        accountUsageBar(labelView: Text(label), utilization: utilization, resetTime: resetTime)
    }

    private func accountUsageBar(labelText: String, utilization: Double?, resetTime: String?) -> some View {
        accountUsageBar(labelView: Text(labelText), utilization: utilization, resetTime: resetTime)
    }

    private func accountUsageBar(labelView: Text, utilization: Double?, resetTime: String?) -> some View {
        let pct = utilization ?? 0
        return HStack(spacing: 6) {
            labelView
                .font(.caption2)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 48, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(theme.quaternary)
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(colorForUtilization(pct))
                        .frame(width: max(0, geo.size.width * min(pct / 100.0, 1.0)), height: 5)
                }
            }
            .frame(height: 5)
            Text("\(Int(pct))%")
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(colorForUtilization(pct))
                .frame(width: 32, alignment: .trailing)
        }
    }
}

// MARK: - Circular (Rings) Widget

private struct CircleWidgetView: View {
    let data: WidgetData
    let theme: WidgetTheme

    private var activeAccount: WidgetAccountData? {
        data.accounts.first(where: \.isActive) ?? data.accounts.first
    }

    var body: some View {
        VStack(spacing: 8) {
            // Header — show account name instead of app name
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
                    .widgetAccentable()
                Text(activeAccount?.displayName ?? "CCSwitcher")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if let sub = activeAccount?.subscriptionType {
                    Text(sub)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.accent.opacity(0.15), in: Capsule())
                }
            }

            Spacer(minLength: 0)

            if let account = activeAccount, !account.hasError {
                HStack(spacing: 12) {
                    ringStat(
                        label: "Session",
                        resetTime: account.sessionResetTime,
                        utilization: account.sessionUtilization,
                        accent: colorForUtilization(account.sessionUtilization ?? 0)
                    )
                    ringStat(
                        label: "Weekly",
                        resetTime: account.weeklyResetTime,
                        utilization: account.weeklyUtilization,
                        accent: colorForUtilization(account.weeklyUtilization ?? 0)
                    )
                    ForEach(account.scopedLimits ?? [], id: \.modelName) { limit in
                        ringStat(
                            labelText: limit.modelName,
                            resetTime: limit.resetTime,
                            utilization: limit.utilization,
                            accent: colorForUtilization(limit.utilization)
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            } else if let account = activeAccount, account.hasError {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                    if let msg = account.errorMessage {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    } else {
                        Text("Error")
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
            } else {
                Text("No accounts")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func ringStat(label: LocalizedStringKey, resetTime: String?, utilization: Double?, accent: Color) -> some View {
        ringStat(labelView: Text(label), resetTime: resetTime, utilization: utilization, accent: accent)
    }

    private func ringStat(labelText: String, resetTime: String?, utilization: Double?, accent: Color) -> some View {
        ringStat(labelView: Text(labelText), resetTime: resetTime, utilization: utilization, accent: accent)
    }

    private func ringStat(labelView: Text, resetTime: String?, utilization: Double?, accent: Color) -> some View {
        let pct = utilization ?? 0
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(theme.quaternary, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: min(pct / 100.0, 1.0))
                    .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(pct))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.textPrimary)
            }
            .aspectRatio(1, contentMode: .fit)

            labelView
                .font(.caption2)
                .foregroundStyle(theme.textSecondary)
            if let reset = resetTime {
                Text(reset)
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CircleWidgetEntryView: View {
    var entry: CCSwitcherEntry

    var body: some View {
        if let data = entry.data {
            CircleWidgetView(data: data, theme: .theme(for: data.provider))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 28))
                    .foregroundStyle(brandColor)
                Text("Open CCSwitcher")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("to load data")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Helpers

private func colorForUtilization(_ pct: Double) -> Color {
    if pct >= 90 { return .red }
    if pct >= 60 { return .orange }
    return .green
}

private func formatCost(_ cost: Double) -> String {
    cost >= 1 ? String(format: "$%.2f", cost) : String(format: "$%.4f", cost)
}

// MARK: - Widget Definition

struct CCSwitcherWidget: Widget {
    let kind: String = "CCSwitcherWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CCSwitcherProvider()) { entry in
            CCSwitcherWidgetEntryView(entry: entry)
                .containerBackground(WidgetTheme.theme(for: entry.data?.provider).containerBackground, for: .widget)
        }
        .configurationDisplayName("CCSwitcher")
        .description("Monitor your Claude Code account usage, costs, and activity.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CCSwitcherCircleWidget: Widget {
    let kind: String = "CCSwitcherCircleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CCSwitcherProvider()) { entry in
            CircleWidgetEntryView(entry: entry)
                .containerBackground(WidgetTheme.theme(for: entry.data?.provider).containerBackground, for: .widget)
        }
        .configurationDisplayName("CCSwitcher Rings")
        .description("Session and weekly usage shown as circular progress rings.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Widget Bundle

@main
struct CCSwitcherWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        CCSwitcherWidget()
        CCSwitcherCircleWidget()
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    CCSwitcherWidget()
} timeline: {
    CCSwitcherEntry.placeholder
}

#Preview("Medium", as: .systemMedium) {
    CCSwitcherWidget()
} timeline: {
    CCSwitcherEntry.placeholder
}

#Preview("Large", as: .systemLarge) {
    CCSwitcherWidget()
} timeline: {
    CCSwitcherEntry.placeholder
}
