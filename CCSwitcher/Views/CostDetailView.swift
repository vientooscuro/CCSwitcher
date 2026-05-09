import SwiftUI

/// Full cost breakdown tab with today's card and daily history.
struct CostDetailView: View {
    @EnvironmentObject private var appState: AppState

    private static let pricingURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                todayCard
                periodSummaryCards
                dailyHistorySection
                pricingInfoSection
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Summary Cards

    private var todayCard: some View {
        let summary = appState.costSummary
        let today = summary.dailyCosts.first(where: { $0.date == todayString() })

        return VStack(spacing: 8) {
            HStack {
                Text("Today")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.textSecondary)
                Spacer()
                Text(todayDisplayDate())
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)
            }

            Text(formatCost(summary.todayCost))
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.green)

            if let today, !today.sortedBreakdown.isEmpty {
                Divider()
                VStack(spacing: 4) {
                    ForEach(today.sortedBreakdown, id: \.model) { entry in
                        let model = entry.model
                        let cost = entry.cost
                        HStack {
                            Text(model)
                                .font(.caption2)
                                .foregroundStyle(.textSecondary)
                            Spacer()
                            Text(formatCost(cost))
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(.textSecondary)
                        }
                    }
                }

                HStack {
                    Label("\(today.sessionCount) sessions", systemImage: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                    Spacer()
                    Text("\(formatTokenCount(today.totalTokens)) tokens")
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                }
                .padding(.top, 2)
            }
        }
        .cardStyle()
        .sectionPadding()
    }

    private var periodSummaryCards: some View {
        let costs = appState.costSummary.dailyCosts
        let todayStr = todayString()

        let last7 = costForLastDays(7, costs: costs, today: todayStr, formatter: Formatters.isoDay)
        let last30 = costForLastDays(30, costs: costs, today: todayStr, formatter: Formatters.isoDay)

        return HStack(spacing: 10) {
            periodCard(title: "Last 7 Days", cost: last7)
            periodCard(title: "Last 30 Days", cost: last30)
        }
        .padding(.horizontal, 16)
    }

    private func periodCard(title: String, cost: Double) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.textSecondary)
            Text(formatCost(cost))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func costForLastDays(_ days: Int, costs: [DailyCost], today: String, formatter: DateFormatter) -> Double {
        guard let todayDate = formatter.date(from: today) else { return 0 }
        let startDate = Calendar.current.date(byAdding: .day, value: -(days - 1), to: todayDate)!
        let startStr = formatter.string(from: startDate)
        return costs.filter { $0.date >= startStr && $0.date <= today }.reduce(0) { $0 + $1.totalCost }
    }

    // MARK: - Daily History

    private var dailyHistorySection: some View {
        let costs = appState.costSummary.dailyCosts
        let maxCost = costs.map(\.totalCost).max() ?? 1

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Daily History")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.textSecondary)
                Spacer()
                Text("Total: \(formatCost(appState.costSummary.totalCost))")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.textSecondary)
            }
            .padding(.horizontal, 16)

            if costs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.textSecondary)
                    Text("No cost data available")
                        .font(.subheadline)
                        .foregroundStyle(.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 1) {
                    ForEach(costs) { day in
                        dailyRow(day: day, maxCost: maxCost)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func dailyRow(day: DailyCost, maxCost: Double) -> some View {
        let isToday = day.date == todayString()
        let barRatio = maxCost > 0 ? day.totalCost / maxCost : 0

        return HStack(spacing: 8) {
            Text(shortDate(day.date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isToday ? .brand : .secondary)
                .frame(width: 40, alignment: .leading)

            Text(formatCost(day.totalCost))
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(isToday ? .brand : .primary)
                .frame(width: 56, alignment: .trailing)

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(isToday ? Color.brand : Color.blue.opacity(0.6))
                    .frame(width: max(2, geo.size.width * barRatio), height: 8)
            }
            .frame(height: 8)

            // Compact model breakdown
            Text(day.modelBreakdown.keys.sorted().joined(separator: ", "))
                .font(.system(size: 8))
                .foregroundStyle(.textSecondary)
                .frame(width: 50, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isToday ? .cardFillStrong : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Pricing Info

    private var pricingInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("How We Calculate")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 10) {
                Text("Cost is computed from Claude Code session logs (~/.claude/projects/), deduplicated by request ID.")
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)

                // Pricing table
                VStack(spacing: 0) {
                    pricingHeader
                    Divider()
                    ForEach(Self.pricingRows, id: \.model) { row in
                        pricingRow(row)
                        Divider()
                    }
                }
                .background(.cardFill)
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.cardCornerRadius))
                .overlay(RoundedRectangle(cornerRadius: AppStyle.cardCornerRadius).strokeBorder(.cardBorder, lineWidth: 1))

                Text("Cache write shown for 1-hour tier (2× input) — Claude Code's default. 5-min tier is 1.25× input. Cache read = 0.1× input.")
                    .font(.system(size: 9))
                    .foregroundStyle(.textSecondary)

                Button {
                    NSWorkspace.shared.open(Self.pricingURL)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption2)
                        Text("Official Pricing — platform.claude.com")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            .cardStyle()
            .sectionPadding()
        }
    }

    private var pricingHeader: some View {
        HStack(spacing: 0) {
            Text("Model")
                .frame(width: 62, alignment: .leading)
            Text("Input")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Output")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Cache 1h")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Cache R")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private struct PricingRowData {
        let model: String
        let input: String
        let output: String
        let cacheW: String
        let cacheR: String
    }

    /// Static — never changes. The previous computed property allocated a
    /// fresh array on every body invalidation.
    private static let pricingRows: [PricingRowData] = [
        PricingRowData(model: "Opus 4.7", input: "$5", output: "$25", cacheW: "$10", cacheR: "$0.50"),
        PricingRowData(model: "Sonnet 4.6", input: "$3", output: "$15", cacheW: "$6", cacheR: "$0.30"),
        PricingRowData(model: "Haiku 4.5", input: "$1", output: "$5", cacheW: "$2", cacheR: "$0.10"),
    ]

    private func pricingRow(_ row: PricingRowData) -> some View {
        HStack(spacing: 0) {
            Text(row.model)
                .frame(width: 62, alignment: .leading)
            Text(row.input)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(row.output)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(row.cacheW)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(row.cacheR)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func formatCost(_ cost: Double) -> String {
        Formatters.currency(cost)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func todayString() -> String {
        Formatters.isoDay.string(from: Date())
    }

    private func todayDisplayDate() -> String {
        Formatters.monthDay.string(from: Date())
    }

    private func shortDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return dateStr }
        return "\(month)/\(day)"
    }
}
