import Foundation

/// Token counters as Codex reports them. `inputTokens` is inclusive of
/// `cachedInputTokens`, and `outputTokens` is inclusive of reasoning tokens —
/// see `LiteLLMModelPricing.openAICost` for why both matter.
struct CodexTokenTotals: Sendable, Hashable {
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var outputTokens: Int = 0

    /// Input plus output. `inputTokens` already contains the cached portion, so
    /// adding it again would double-count.
    var totalBillableTokens: Int { inputTokens + outputTokens }

    static func + (lhs: CodexTokenTotals, rhs: CodexTokenTotals) -> CodexTokenTotals {
        CodexTokenTotals(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens
        )
    }
}

extension CodexTokenTotals: Codable {
    // Encoded as a bare 4-element array instead of a keyed object. This is an
    // on-disk cache, not a public format, and `CodexRolloutAggregate` can hold
    // one of these per `token_count` event across ~1,000 rollout files — the
    // four repeated key names (`inputTokens`, `cachedInputTokens`, ...) would
    // otherwise outweigh the four integers they label many times over.
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        inputTokens = try container.decode(Int.self)
        cachedInputTokens = try container.decode(Int.self)
        cacheWriteTokens = try container.decode(Int.self)
        outputTokens = try container.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(inputTokens)
        try container.encode(cachedInputTokens)
        try container.encode(cacheWriteTokens)
        try container.encode(outputTokens)
    }
}

/// One point on a session's cumulative token counter: the running total as of
/// one `token_count` event, tagged with the day and model active when it was
/// recorded. A resumed or subagent rollout file replays every earlier
/// `token_count` event with an identical `cumulative` value, so two
/// observations from different files of the same session with equal
/// `cumulative` describe the same real event — see `CodexSessionCache`.
///
/// Not stored directly: `CodexRolloutAggregate` groups these into
/// `CodexTokenObservationRun`s on disk. This is the flattened, one-event-at-a-
/// time view `CodexSessionCache`'s merge works with in memory.
struct CodexTokenObservation: Sendable, Equatable {
    var day: String
    var model: String
    var cumulative: CodexTokenTotals
}

/// A run of cumulative snapshots sharing one day and model. Consecutive
/// `token_count` events almost always share both — a model only changes at a
/// `turn_context` and a day only changes at midnight — so storing the pair
/// once per run instead of once per event avoids repeating those strings for
/// every event in a long session.
struct CodexTokenObservationRun: Codable, Sendable {
    var day: String
    var model: String
    var cumulatives: [CodexTokenTotals]
}

/// One `apply_patch` tool call. `id` is the event's `call_id` where present —
/// a resumed or subagent file replays the same `call_id` verbatim for shared
/// history, making it a far better cross-file dedup key than a timestamp.
/// Falls back to a timestamp+line-count key for the rare event without one,
/// so replays of that event still dedup, just less precisely.
struct CodexPatchEvent: Sendable {
    var id: String
    var lines: Int
}

extension CodexPatchEvent: Codable {
    // Unkeyed array, matching `CodexTokenTotals` — this can appear once per
    // `apply_patch` call across ~1,000 rollout files.
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        id = try container.decode(String.self)
        lines = try container.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(id)
        try container.encode(lines)
    }
}

/// Everything one rollout file contributes. Cached on disk keyed by path and
/// mtime, so an unchanged file is never re-read.
struct CodexRolloutAggregate: Codable, Sendable {
    /// "yyyy-MM-dd" -> model id -> totals, computed from this file's own events
    /// in isolation. Correct for a standalone file, but summing this across
    /// every file of a resumed session double- (or n-times-) counts replayed
    /// history — `CodexSessionCache` uses `tokenObservationRuns` instead for that.
    var tokens: [String: [String: CodexTokenTotals]] = [:]
    /// This file's own per-day counts, computed in isolation — see `tokens`
    /// above for why these are unsafe to sum across a session's files.
    /// `CodexSessionCache` uses the raw fields below instead.
    var turns: [String: Int] = [:]
    var linesAdded: [String: Int] = [:]
    var activeMinutes: [String: Int] = [:]
    /// `session_meta.session_id`, shared by every rollout file that resumes or
    /// forks off the same session.
    var sessionId: String?
    /// Every `token_count` event this file saw, as raw cumulative snapshots
    /// grouped into runs (not yet turned into deltas). Cross-file dedup needs
    /// the cumulative value itself, since deltas already collapsed the
    /// information needed to recognize replayed history from another file of
    /// the same session.
    var tokenObservationRuns: [CodexTokenObservationRun] = []
    /// `task_started` event timestamps (epoch seconds), by day. Two files of
    /// the same session replay the same `task_started` verbatim, so the
    /// timestamp — not this file's own count — is what `CodexSessionCache`
    /// dedups on to recover the session's real turn count.
    var turnTimestampsByDay: [String: [Double]] = [:]
    /// `apply_patch` calls seen in this file, by day. `CodexSessionCache`
    /// dedups on `CodexPatchEvent.id` across a session's files.
    var patchEventsByDay: [String: [CodexPatchEvent]] = [:]
    /// Every event's timestamp in this file, floored to the minute and
    /// grouped by day, for `CodexSessionCache`'s cross-file active-time merge.
    /// Minute resolution instead of every raw timestamp keeps this bounded —
    /// one real session replayed ~117k timestamped events in a single day
    /// across its files, which storing verbatim would multiply by file count.
    var activeMinuteBucketsByDay: [String: [Int]] = [:]
    /// Newest `rate_limits` block seen in this file, for the offline fallback.
    var latestSnapshot: CodexRateLimitSnapshot?
    /// Timestamp of the newest event, used to pick the freshest file's snapshot.
    var latestEventAt: Double = 0
    var mtime: Double = 0
}
