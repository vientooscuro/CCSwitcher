import Foundation

// MARK: - Token Cost Models

/// Per-model pricing in USD per 1M tokens.
///
/// Sourced from https://platform.claude.com/docs/en/about-claude/pricing.
/// Anthropic exposes two prompt-cache write tiers:
///   * 5-minute ephemeral: 1.25× base input
///   * 1-hour ephemeral:   2.00× base input
/// Claude Code uses the 1-hour tier by default for system prompts and tool
/// definitions; the 5-minute tier is used for short-lived assistant scratch.
/// Cache *read* is 0.10× base input regardless of tier.
struct ModelPricing {
    let input: Double
    let output: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let cacheRead: Double

    /// Models share two pricing tiers within each family:
    ///   * Opus 4.0 / 4.1     → premium  ($15 / $75)
    ///   * Opus 4.5 / 4.6 / 4.7 → consumer ($5  / $25)   ← introduced Oct 2025
    ///   * Sonnet 4 / 4.5 / 4.6 → $3  / $15
    ///   * Haiku 4.5            → $1  / $5
    ///   * Haiku 3.5            → $0.80 / $4
    static let pricing: [String: ModelPricing] = [
        // Opus consumer tier (4.5+) — current generation
        "claude-opus-4-7": ModelPricing(input: 5.0, output: 25.0, cacheWrite5m: 6.25, cacheWrite1h: 10.0, cacheRead: 0.50),
        "claude-opus-4-6": ModelPricing(input: 5.0, output: 25.0, cacheWrite5m: 6.25, cacheWrite1h: 10.0, cacheRead: 0.50),
        "claude-opus-4-5": ModelPricing(input: 5.0, output: 25.0, cacheWrite5m: 6.25, cacheWrite1h: 10.0, cacheRead: 0.50),
        // Opus premium tier (legacy 4.0/4.1)
        "claude-opus-4-1": ModelPricing(input: 15.0, output: 75.0, cacheWrite5m: 18.75, cacheWrite1h: 30.0, cacheRead: 1.50),
        "claude-opus-4":   ModelPricing(input: 15.0, output: 75.0, cacheWrite5m: 18.75, cacheWrite1h: 30.0, cacheRead: 1.50),
        // Sonnet 4 family — same pricing across versions
        "claude-sonnet-4-6": ModelPricing(input: 3.0, output: 15.0, cacheWrite5m: 3.75, cacheWrite1h: 6.0, cacheRead: 0.30),
        "claude-sonnet-4-5": ModelPricing(input: 3.0, output: 15.0, cacheWrite5m: 3.75, cacheWrite1h: 6.0, cacheRead: 0.30),
        "claude-sonnet-4":   ModelPricing(input: 3.0, output: 15.0, cacheWrite5m: 3.75, cacheWrite1h: 6.0, cacheRead: 0.30),
        // Haiku
        "claude-haiku-4-5": ModelPricing(input: 1.0, output: 5.0, cacheWrite5m: 1.25, cacheWrite1h: 2.0, cacheRead: 0.10),
        "claude-haiku-3-5": ModelPricing(input: 0.80, output: 4.0, cacheWrite5m: 1.0, cacheWrite1h: 1.6, cacheRead: 0.08),
    ]

    /// Pre-computed longest-first key list for deterministic prefix matching.
    /// Plain `for (k, v) in pricing` returned different prices on every run
    /// (dictionary iteration order is unstable) — for `claude-opus-4-7` it
    /// could return either premium ($15) or consumer ($5) tier.
    private static let prefixMatchKeys: [String] = pricing.keys.sorted { $0.count > $1.count }

    static func forModel(_ model: String) -> ModelPricing? {
        if let exact = pricing[model] { return exact }

        // Longest-prefix match: claude-opus-4-7 → claude-opus-4-7 (miss),
        // then claude-opus-4-6 (no — model doesn't start with that),
        // ... → claude-opus-4 (yes — but that's premium tier, wrong!).
        // Use family-based prefix instead.
        for key in prefixMatchKeys where model.hasPrefix(key) {
            return pricing[key]
        }

        // Date-suffixed names (claude-sonnet-4-20251001) — strip suffix and retry.
        if let stripped = stripDateSuffix(model), stripped != model {
            if let exact = pricing[stripped] { return exact }
            for key in prefixMatchKeys where stripped.hasPrefix(key) {
                return pricing[key]
            }
        }

        // Final fallback for bare family names appearing in some logs
        // (e.g. just "sonnet", "opus", "haiku"). Map to *current* consumer
        // tier — better than charging $0 and silently dropping the cost.
        let lower = model.lowercased()
        if lower.contains("opus") { return pricing["claude-opus-4-7"] }
        if lower.contains("sonnet") { return pricing["claude-sonnet-4-6"] }
        if lower.contains("haiku") { return pricing["claude-haiku-4-5"] }
        return nil
    }

    /// Drop a trailing `-YYYYMMDD` (8-digit) date stamp from a model id.
    private static func stripDateSuffix(_ model: String) -> String? {
        let parts = model.split(separator: "-")
        guard let last = parts.last,
              last.count == 8,
              last.allSatisfy(\.isNumber) else { return nil }
        return parts.dropLast().joined(separator: "-")
    }
}

/// Token usage from a single API call.
struct TokenUsage {
    let inputTokens: Int
    let outputTokens: Int
    /// 5-minute ephemeral cache write tokens.
    let cacheWrite5mTokens: Int
    /// 1-hour ephemeral cache write tokens.
    let cacheWrite1hTokens: Int
    let cacheReadTokens: Int
    let model: String
    let timestamp: Date
    let sessionFile: String

    /// Combined cache-write tokens for display purposes (UI doesn't break out
    /// the tiers, but cost accounting must).
    var cacheWriteTokens: Int { cacheWrite5mTokens + cacheWrite1hTokens }

    var cost: Double {
        guard let p = ModelPricing.forModel(model) else { return 0 }
        return Double(inputTokens) / 1_000_000 * p.input
            + Double(outputTokens) / 1_000_000 * p.output
            + Double(cacheWrite5mTokens) / 1_000_000 * p.cacheWrite5m
            + Double(cacheWrite1hTokens) / 1_000_000 * p.cacheWrite1h
            + Double(cacheReadTokens) / 1_000_000 * p.cacheRead
    }
}

/// Aggregated cost for a single day.
struct DailyCost: Identifiable {
    let date: String // "yyyy-MM-dd"
    let totalCost: Double
    let modelBreakdown: [String: Double] // model -> cost
    /// Pre-sorted by descending cost. Built once in `CostParser`; views
    /// shouldn't re-sort on every body invalidation.
    let sortedBreakdown: [(model: String, cost: Double)]
    let sessionCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int

    var id: String { date }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
    }

    var parsedDate: Date? {
        Formatters.isoDay.date(from: date)
    }
}

/// Overall cost summary.
struct CostSummary {
    let todayCost: Double
    let dailyCosts: [DailyCost]

    var totalCost: Double {
        dailyCosts.reduce(0) { $0 + $1.totalCost }
    }

    static let empty = CostSummary(todayCost: 0, dailyCosts: [])
}
