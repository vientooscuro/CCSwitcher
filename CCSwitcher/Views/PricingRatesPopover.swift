import SwiftUI

/// Live per-model rates for whichever provider is currently active, shown from
/// the "?" button on the Costs tab so the dollar total above it is traceable
/// to real numbers instead of a black box.
///
/// Only models the user actually used (from the on-screen cost breakdown) are
/// listed — the bundled table has 50+ Claude rows and 56 OpenAI rows, most of
/// them irrelevant to any one user.
struct PricingRatesPopover: View {
    let provider: AIProviderType
    /// model id -> total spend across the visible daily series. Used only to
    /// decide which models to show and their sort order, not displayed.
    let modelSpend: [String: Double]

    @Environment(\.providerTheme) private var theme

    private struct Row: Identifiable {
        let model: String
        let pricing: LiteLLMModelPricing?
        var id: String { model }
    }

    @State private var rows: [Row] = []
    @State private var source: PricingSource?

    private static let columnWidth: CGFloat = 46
    private static let fetchedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var showsCacheWrite: Bool { provider != .codex }
    private var sortedModelIds: [String] { modelSpend.keys.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(provider == .codex
                 ? String(localized: "OpenAI rates", bundle: L10n.bundle)
                 : String(localized: "Claude rates", bundle: L10n.bundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.textPrimary)

            if let source {
                Text(sourceCaption(source))
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if rows.isEmpty {
                Text(String(localized: "No priced models used yet.", bundle: L10n.bundle))
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            } else {
                columnHeader
                Divider()
                VStack(spacing: 6) {
                    ForEach(rows) { rateRow($0) }
                }
            }

            if provider == .codex {
                Text(String(localized: "OpenAI's input figure already includes cached tokens; cache reads bill at the lower rate below, so actual cost runs under the input rate shown.", bundle: L10n.bundle))
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .task(id: sortedModelIds) {
            await load()
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 6) {
            Text(String(localized: "Model", bundle: L10n.bundle))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "In", bundle: L10n.bundle))
                .frame(width: Self.columnWidth, alignment: .trailing)
            Text(String(localized: "Out", bundle: L10n.bundle))
                .frame(width: Self.columnWidth, alignment: .trailing)
            if showsCacheWrite {
                Text(String(localized: "C.Write", bundle: L10n.bundle))
                    .frame(width: Self.columnWidth, alignment: .trailing)
            }
            Text(String(localized: "C.Read", bundle: L10n.bundle))
                .frame(width: Self.columnWidth, alignment: .trailing)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(theme.textSecondary)
    }

    private func rateRow(_ row: Row) -> some View {
        HStack(spacing: 6) {
            Text(row.model)
                .font(.caption2)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let pricing = row.pricing {
                rateValue(pricing.inputPerToken)
                rateValue(pricing.outputPerToken)
                if showsCacheWrite {
                    rateValue(pricing.cacheCreatePerToken)
                }
                rateValue(pricing.cacheReadPerToken)
            } else {
                // A silent $0.00 here would look like a real (free) rate —
                // this sheet exists to expose exactly that kind of mistake.
                Text(String(localized: "no published rate", bundle: L10n.bundle))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func rateValue(_ perToken: Double) -> some View {
        Text(Formatters.pricePerMillionTokens(perToken))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(theme.textPrimary)
            .frame(width: Self.columnWidth, alignment: .trailing)
    }

    private func sourceCaption(_ source: PricingSource) -> String {
        switch source {
        case .bundle(let commit):
            String(localized: "Rates bundled with the app (LiteLLM \(commit)).", bundle: L10n.bundle)
        case .fresh(let fetchedAt):
            String(localized: "Rates refreshed from LiteLLM on \(Self.fetchedAtFormatter.string(from: fetchedAt)).", bundle: L10n.bundle)
        }
    }

    private func load() async {
        let ids = sortedModelIds
        guard !ids.isEmpty else {
            rows = []
            return
        }
        await PricingService.shared.ensureLoaded()
        let priced = await PricingService.shared.prices(for: ids)
        source = await PricingService.shared.currentSource()
        rows = ids
            .map { Row(model: $0, pricing: priced[$0] ?? nil) }
            .sorted { (modelSpend[$0.model] ?? 0) > (modelSpend[$1.model] ?? 0) }
    }
}
