import SwiftUI

/// Codex-to-display-model mapping. Pure and free of actor isolation so the
/// numbers the UI shows are pinned by unit tests.
enum CodexDisplayMapper {

    /// Stable per-model tints. Codex model names are open-ended (`gpt-5.6-sol`,
    /// `gpt-5.6-luna`, future ids), so the colour is derived from the name's
    /// hash rather than enumerated — a fixed switch would silently grey out
    /// every model released after this build.
    static func tint(forModel name: String) -> Color {
        let palette: [Color] = [.teal, .purple, .blue, .green, .pink, .orange, .indigo]
        var hash = 5381
        for byte in name.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }

    static func planBadge(from planType: String?) -> String? {
        guard let planType, !planType.isEmpty else { return nil }
        return planType.prefix(1).uppercased() + planType.dropFirst()
    }

    static func windows(from snapshot: CodexRateLimitSnapshot) -> [UsageWindowModel] {
        snapshot.windows.map { window in
            UsageWindowModel(
                kind: UsageWindowModel.Kind(windowSeconds: window.windowSeconds),
                utilization: window.usedPercent,
                resetsAt: window.resetAt,
                windowSeconds: window.windowSeconds
            )
        }
    }

    static func windows(from response: CodexUsageResponse) -> [UsageWindowModel] {
        windows(from: CodexRateLimitSnapshot(response: response))
    }

    static func scopedLimits(from snapshot: CodexRateLimitSnapshot) -> [ScopedLimitModel] {
        snapshot.scoped.map { entry in
            ScopedLimitModel(
                modelName: entry.name,
                utilization: entry.usedPercent,
                resetsAt: entry.resetAt,
                tint: tint(forModel: entry.name)
            )
        }
    }

    static func scopedLimits(from response: CodexUsageResponse) -> [ScopedLimitModel] {
        scopedLimits(from: CodexRateLimitSnapshot(response: response))
    }

    static func credits(from snapshot: CodexRateLimitSnapshot) -> CreditPoolModel? {
        // A plan with no credit pool at all still reports the block with
        // has_credits false, so always show the row for parity with Claude's
        // "Extra usage Off".
        CreditPoolModel(
            isEnabled: snapshot.hasCredits || snapshot.unlimitedCredits,
            isUnlimited: snapshot.unlimitedCredits,
            balanceText: snapshot.creditsBalance,
            utilization: nil
        )
    }

    static func credits(from response: CodexUsageResponse) -> CreditPoolModel? {
        guard response.credits != nil else { return nil }
        return credits(from: CodexRateLimitSnapshot(response: response))
    }

    static func notice(from snapshot: CodexRateLimitSnapshot, isStale: Bool) -> String? {
        if snapshot.spendControlReached {
            return String(localized: "Spend limit reached.", bundle: L10n.bundle)
        }
        if let reached = snapshot.reachedType {
            return String(localized: "Rate limit reached (\(reached)).", bundle: L10n.bundle)
        }
        if isStale {
            return String(localized: "Showing the last snapshot Codex wrote locally.", bundle: L10n.bundle)
        }
        return nil
    }

    static func notice(from response: CodexUsageResponse, isStale: Bool) -> String? {
        notice(from: CodexRateLimitSnapshot(response: response), isStale: isStale)
    }

    /// Flattens one Codex account for the desktop widget. `WidgetAccountData`
    /// was shaped for Claude's fixed five-hour/seven-day windows, so windows
    /// are matched by `kind` — never by position, since Codex's primary and
    /// secondary slots do not reliably correspond to session and weekly (see
    /// `UsageWindowModel.Kind`). Anything Codex has no equivalent for is left
    /// nil rather than reshaping the type.
    static func widgetAccount(
        email: String,
        displayName: String,
        planBadge: String?,
        windows: [UsageWindowModel],
        scopedLimits: [ScopedLimitModel],
        credits: CreditPoolModel?,
        error: ProviderErrorModel?
    ) -> WidgetAccountData {
        let sessionWindow = windows.first { $0.kind == .session }
        let weeklyWindow = windows.first { $0.kind == .weekly }
        return WidgetAccountData(
            email: email,
            displayName: displayName,
            subscriptionType: planBadge,
            isActive: true,
            sessionUtilization: sessionWindow?.utilization,
            sessionResetTime: sessionWindow.flatMap { UsageWindowFormat.resetText(until: $0.resetsAt) },
            weeklyUtilization: weeklyWindow?.utilization,
            weeklyResetTime: weeklyWindow.flatMap { UsageWindowFormat.resetText(until: $0.resetsAt) },
            extraUsageEnabled: credits?.isEnabled,
            hasError: error != nil,
            errorMessage: error?.message,
            scopedLimits: scopedLimits.map {
                WidgetScopedLimit(
                    modelName: $0.modelName,
                    utilization: $0.utilization,
                    resetTime: UsageWindowFormat.resetText(until: $0.resetsAt)
                )
            }
        )
    }
}
