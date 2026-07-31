import SwiftUI

/// Renders one configured menu-bar module in the iStats-style two-line layout:
/// a short uppercase label on top and either a horizontal bar (for utilization
/// percentages) or a value text (for absolute numbers / times) on the bottom.
struct MenuBarModuleView: View {
    let module: MenuBarModule
    let hub: ProviderHub
    let showFullEmail: Bool
    /// Tick value that recomputes reset countdowns once a minute.
    /// Passed in (and ignored by non-countdown modules) so the parent timer
    /// can drive view updates without each module owning a timer.
    let tick: Date

    // Fixed row geometry so every module shares the same baseline grid: the
    // label row and the value/bar row line up across all modules regardless of
    // whether the bottom row is text (taller) or a bar (shorter).
    private let labelRowHeight: CGFloat = 9
    private let valueRowHeight: CGFloat = 13

    var body: some View {
        if module == .account {
            // Account is shown as a single line (no label) — the name is
            // self-identifying and the `@` label added noise. No height frame:
            // wrapping the Text in a fixed-height frame truncated it.
            Text(accountText)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .fixedSize()
        } else if module == .scopedLimitBar {
            // Renders nothing at all when there's no scoped limit — an empty
            // bar in its place would look like a bug rather than "not present".
            if let limit = activeCard?.scopedLimits.first {
                VStack(alignment: .center, spacing: 0) {
                    Text(limit.modelName.prefix(4).uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .kerning(0.2)
                        .foregroundStyle(.primary)
                        .fixedSize()
                        .frame(height: labelRowHeight)

                    UtilizationBar(utilization: limit.utilization)
                        .frame(height: valueRowHeight)
                }
                .fixedSize()
            }
        } else {
            VStack(alignment: .center, spacing: 0) {
                Text(compactLabel)
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(0.2)
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .frame(height: labelRowHeight)

                valueRow
                    .frame(height: valueRowHeight)
            }
            .fixedSize()
        }
    }

    /// Top-line label: derived from the actual window once its data has
    /// loaded, falling back to the module's static label before then.
    private var compactLabel: String {
        switch module {
        case .sessionBar, .sessionBarPlain:
            window(.session).map(MenuBarModule.compactLabel(for:)) ?? module.compactLabel
        case .weeklyBar, .weeklyBarPlain:
            window(.weekly).map(MenuBarModule.compactLabel(for:)) ?? module.compactLabel
        // The countdown modules carry the same window label plus a reset glyph,
        // so they would mislabel a Codex window exactly as the bars did.
        case .sessionReset:
            window(.session).map { MenuBarModule.compactLabel(for: $0) + "↻" } ?? module.compactLabel
        case .weeklyReset:
            window(.weekly).map { MenuBarModule.compactLabel(for: $0) + "↻" } ?? module.compactLabel
        default:
            module.compactLabel
        }
    }

    @ViewBuilder
    private var valueRow: some View {
        switch module {
        case .account:
            Text(accountText)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .fixedSize()

        case .sessionBar:
            UtilizationBar(utilization: sessionUtilization, markerPercent: sessionTimeElapsed)

        case .weeklyBar:
            UtilizationBar(utilization: weeklyUtilization, markerPercent: weeklyTimeElapsed)

        case .sessionBarPlain:
            UtilizationBar(utilization: sessionUtilization)

        case .weeklyBarPlain:
            UtilizationBar(utilization: weeklyUtilization)

        case .dailyCost:
            Text(dailyCostText)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()

        case .sessionReset:
            Text(sessionResetText)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()

        case .weeklyReset:
            Text(weeklyResetText)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()

        case .scopedLimitBar:
            // Handled entirely in `body` (it needs to render nothing rather
            // than an empty bar when there's no scoped limit); unreachable here.
            EmptyView()
        }
    }

    // MARK: - Data accessors

    private var activeCard: UsageCardModel? {
        hub.surface.accountCards.first { $0.isActive } ?? hub.surface.accountCards.first
    }

    private func window(_ kind: UsageWindowModel.Kind) -> UsageWindowModel? {
        activeCard?.windows.first { $0.kind == kind }
    }

    private var accountText: String {
        guard let card = activeCard else { return "—" }
        return card.title.isEmpty ? "—" : card.title
    }

    private var sessionUtilization: Double? { window(.session)?.utilization }

    private var weeklyUtilization: Double? { window(.weekly)?.utilization }

    private var sessionTimeElapsed: Double? {
        _ = tick // recompute as the window progresses
        return window(.session)?.elapsedPercent
    }

    private var weeklyTimeElapsed: Double? {
        _ = tick
        return window(.weekly)?.elapsedPercent
    }

    private var dailyCostText: String {
        let cost = hub.surface.cost.todayCost
        guard cost > 0 else { return "—" }
        return String(format: "$%.2f", cost)
    }

    private var sessionResetText: String {
        // `tick` is read so SwiftUI recomputes on each timer fire.
        _ = tick
        return UsageWindowFormat.compactResetText(until: window(.session)?.resetsAt) ?? "—"
    }

    private var weeklyResetText: String {
        _ = tick
        return UsageWindowFormat.compactResetText(until: window(.weekly)?.resetsAt) ?? "—"
    }
}

/// Hollow rounded capsule with an inner filled pill whose width reflects
/// `utilization` (a 0–100 percentage, normalized to 0–1). Fill is monochrome
/// (adapts to the light/dark menu bar), turning red above 90% (and staying red
/// on overage, clamped at 100%).
///
/// `markerPercent` (0–100, optional) draws a thin vertical "pace" tick at the
/// fraction of the rate-limit window already elapsed. Compare the fill to the
/// tick: fill past the tick = burning faster than the clock; behind = slower.
private struct UtilizationBar: View {
    /// 0–100 percentage (as returned by the usage API), or nil if unavailable.
    let utilization: Double?
    /// 0–100 time-elapsed percentage for the pace tick, or nil to hide it.
    var markerPercent: Double? = nil

    private let trackWidth: CGFloat = 26
    private let trackHeight: CGFloat = 8
    private let strokeWidth: CGFloat = 1
    private let innerInset: CGFloat = 1.5

    private var clamped: Double { min(max((utilization ?? 0) / 100.0, 0), 1) }

    private var fillColor: Color {
        guard let u = utilization, u > 90 else { return .primary }
        return .red
    }

    /// X offset (within the inset interior) of the pace tick, if shown.
    /// Suppressed when there's no usage data so a dashed "no data" bar can't
    /// sprout a stray tick.
    private var markerX: CGFloat? {
        guard utilization != nil, let m = markerPercent else { return nil }
        let frac = min(max(m / 100.0, 0), 1)
        return innerInset + (trackWidth - innerInset * 2) * frac
    }

    // Restored verbatim from the original (commit b012f0d): a left-anchored
    // inset Capsule fill. Plus one optional vertical pace tick. No clip /
    // compositingGroup / blend — those are what broke it.
    var body: some View {
        ZStack(alignment: .leading) {
            // Track — hollow capsule outline.
            Capsule()
                .stroke(
                    Color.primary.opacity(utilization == nil ? 0.25 : 0.55),
                    style: StrokeStyle(
                        lineWidth: strokeWidth,
                        dash: utilization == nil ? [2, 2] : []
                    )
                )
                .frame(width: trackWidth, height: trackHeight)

            // Fill — inset pill scaled to utilization. Omitted entirely when
            // no data so a missing value is visually distinct from 0%.
            if utilization != nil {
                Capsule()
                    .fill(fillColor)
                    .frame(
                        width: max(
                            0,
                            (trackWidth - innerInset * 2) * clamped
                        ),
                        height: trackHeight - innerInset * 2
                    )
                    .padding(.leading, innerInset)
            }

            // Pace tick — time elapsed in the window. Brand color so it stays
            // visible over both the monochrome fill and the empty track.
            if let x = markerX {
                Rectangle()
                    .fill(Color.brand)
                    .frame(width: 1.5, height: trackHeight - strokeWidth)
                    .offset(x: x - 0.75)
            }
        }
        .frame(width: trackWidth, height: trackHeight)
    }
}
