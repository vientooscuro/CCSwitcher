import SwiftUI

/// A rate limit that applies to one specific model rather than the account as a
/// whole — Claude's scoped weekly limits (e.g. Fable 5) and Codex's
/// `additional_rate_limits` entries (e.g. GPT-5.3-Codex-Spark).
struct ScopedLimitModel: Identifiable {
    let modelName: String
    let utilization: Double
    let resetsAt: Date?
    /// Supplied by the provider. A shared name-to-color switch would be wrong:
    /// the Claude palette keys off Fable/Opus/Sonnet/Haiku, which say nothing
    /// about `gpt-5.6-sol`.
    let tint: Color

    var id: String { modelName }
}

/// Pay-as-you-go pool beyond the subscription: Claude's `extra_usage`,
/// Codex's `credits`.
struct CreditPoolModel {
    let isEnabled: Bool
    let isUnlimited: Bool
    /// Pre-formatted by the provider, because the units differ (dollars vs credits).
    let balanceText: String?
    let utilization: Double?
}

struct ProviderErrorModel {
    let message: String
    /// Drives the "re-authenticate" affordance and the warning icon.
    let needsReauth: Bool
    /// A rate limit blocks refreshes but does not invalidate numbers already
    /// fetched, so the card keeps showing them alongside the message.
    let isRateLimited: Bool
}

/// One account card on the Usage tab.
struct UsageCardModel: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String?
    let planBadge: String?
    let isActive: Bool
    let windows: [UsageWindowModel]
    let scopedLimits: [ScopedLimitModel]
    let credits: CreditPoolModel?
    /// Provider-level notice that is not an error: spend control reached,
    /// limit-reached type, stale local snapshot.
    let notice: String?
    let error: ProviderErrorModel?

    /// True when there is nothing to draw but also no explanation — the
    /// "refresh to fetch" state.
    var isEmpty: Bool {
        windows.isEmpty && scopedLimits.isEmpty && credits == nil && error == nil
    }
}
