import SwiftUI

/// Pure Claude-to-display-model mapping. Deliberately free of `AppState` and of
/// any actor isolation so it can be unit-tested without forking the CLI, and so
/// the numbers the UI shows are pinned by tests.
enum ClaudeDisplayMapper {

    /// Fixed order matching today's UI: the four Claude tiers always render,
    /// including zeros, because a disappearing column reads as a bug.
    static let modelOrder = ["Fable", "Opus", "Sonnet", "Haiku"]

    static func tint(forModel name: String) -> Color {
        switch name {
        case "Fable": return .purple
        case "Opus": return .brand
        case "Sonnet": return .blue
        case "Haiku": return .green
        default: return .gray
        }
    }

    static func windows(from usage: UsageAPIResponse) -> [UsageWindowModel] {
        var result: [UsageWindowModel] = []
        if let session = usage.fiveHour {
            result.append(UsageWindowModel(
                kind: .session,
                utilization: session.utilization ?? 0,
                resetsAt: session.resetsAtDate,
                windowSeconds: RateLimitWindow.fiveHourSeconds
            ))
        }
        if let weekly = usage.sevenDay {
            result.append(UsageWindowModel(
                kind: .weekly,
                utilization: weekly.utilization ?? 0,
                resetsAt: weekly.resetsAtDate,
                windowSeconds: RateLimitWindow.sevenDaySeconds
            ))
        }
        return result
    }

    static func scopedLimits(from usage: UsageAPIResponse) -> [ScopedLimitModel] {
        (usage.limits ?? []).compactMap { limit in
            guard limit.kind == "weekly_scoped",
                  let name = limit.scope?.model?.displayName else { return nil }
            return ScopedLimitModel(
                modelName: name,
                utilization: limit.percent ?? 0,
                resetsAt: UsageWindow(utilization: limit.percent, resetsAt: limit.resetsAt).resetsAtDate,
                tint: tint(forModel: name)
            )
        }
    }

    static func credits(from usage: UsageAPIResponse) -> CreditPoolModel? {
        guard let extra = usage.extraUsage else { return nil }
        return CreditPoolModel(
            isEnabled: extra.isEnabled == true,
            isUnlimited: false,
            balanceText: nil,
            utilization: extra.utilization
        )
    }

    static func card(
        account: Account,
        usage: UsageAPIResponse?,
        error: ProviderErrorModel?,
        obfuscate: Bool
    ) -> UsageCardModel {
        UsageCardModel(
            id: account.id,
            title: account.effectiveDisplayName(obfuscated: obfuscate),
            subtitle: account.displayEmail(obfuscated: obfuscate),
            planBadge: account.displaySubscriptionType,
            isActive: account.isActive,
            windows: usage.map(windows(from:)) ?? [],
            scopedLimits: usage.map(scopedLimits(from:)) ?? [],
            credits: usage.flatMap(credits(from:)),
            notice: nil,
            error: error
        )
    }

    static func header(account: Account, obfuscate: Bool) -> AccountHeaderModel {
        AccountHeaderModel(
            title: account.effectiveDisplayName(obfuscated: obfuscate),
            subtitle: account.displayEmail(obfuscated: obfuscate),
            planBadge: account.displaySubscriptionType
        )
    }

    static func row(account: Account, hasStoredCredentials: Bool, obfuscate: Bool) -> AccountRowModel {
        AccountRowModel(
            id: account.id,
            title: account.effectiveDisplayName(obfuscated: obfuscate),
            email: account.displayEmail(obfuscated: obfuscate),
            planBadge: account.displaySubscriptionType,
            isActive: account.isActive,
            lastUsedText: account.lastUsed.map { Formatters.monthDay.string(from: $0) },
            hasStoredCredentials: hasStoredCredentials,
            rawLabel: account.customLabel
        )
    }

    static func activity(_ stats: ActivityStats) -> ActivitySummaryModel {
        ActivitySummaryModel(
            turns: stats.conversationTurns,
            activeTimeText: stats.activeCodingTimeString,
            linesWritten: stats.linesWritten,
            perModel: modelOrder.map { name in
                ModelUsageEntry(displayName: name, count: stats.modelUsage[name] ?? 0, tint: tint(forModel: name))
            }
        )
    }

    static func cost(_ summary: CostSummary) -> CostSeriesModel {
        CostSeriesModel(
            todayCost: summary.todayCost,
            daily: summary.dailyCosts.map { day in
                DailyCostEntry(
                    date: day.date,
                    cost: day.totalCost,
                    sessionCount: day.sessionCount,
                    modelBreakdown: day.modelBreakdown,
                    inputTokens: day.inputTokens,
                    outputTokens: day.outputTokens,
                    cacheWriteTokens: day.cacheWriteTokens,
                    cacheReadTokens: day.cacheReadTokens
                )
            }
        )
    }
}
