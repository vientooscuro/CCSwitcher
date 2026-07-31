import Foundation

/// Token counters as Codex reports them. `inputTokens` is inclusive of
/// `cachedInputTokens`, and `outputTokens` is inclusive of reasoning tokens —
/// see `LiteLLMModelPricing.openAICost` for why both matter.
struct CodexTokenTotals: Codable, Sendable {
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var outputTokens: Int = 0

    static func + (lhs: CodexTokenTotals, rhs: CodexTokenTotals) -> CodexTokenTotals {
        CodexTokenTotals(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens
        )
    }
}

/// Everything one rollout file contributes. Cached on disk keyed by path and
/// mtime, so an unchanged file is never re-read.
struct CodexRolloutAggregate: Codable, Sendable {
    /// "yyyy-MM-dd" -> model id -> totals.
    var tokens: [String: [String: CodexTokenTotals]] = [:]
    var turns: [String: Int] = [:]
    var linesAdded: [String: Int] = [:]
    var activeMinutes: [String: Int] = [:]
    /// Newest `rate_limits` block seen in this file, for the offline fallback.
    var latestSnapshot: CodexRateLimitSnapshot?
    /// Timestamp of the newest event, used to pick the freshest file's snapshot.
    var latestEventAt: Double = 0
    var mtime: Double = 0
}
