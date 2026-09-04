import Foundation

private let log = FileLog("CodexRollout")

/// Parses one `rollout-*.jsonl` file. Pure: no actor state, no side effects, so
/// it can run concurrently across files and be unit-tested from a fixture.
enum CodexRolloutParser {

    /// Idle gap above which time stops counting as active. Matches the Claude
    /// parser's threshold so the two providers' "Active" figures are comparable.
    private static let idleGapSeconds: TimeInterval = 10 * 60

    static func parse(contentsOf path: String, relativePath: String, mtime: Double) -> CodexRolloutAggregate? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            log.debug("parse: unreadable \(relativePath)")
            return nil
        }

        var aggregate = CodexRolloutAggregate()
        aggregate.mtime = mtime

        // Nil until the first `turn_context`. A resumed session emits
        // `token_count` before its first `turn_context`, so usage seen while
        // this is nil is buffered in `pendingByDate` and attributed to the
        // first model the file names — attributing it to a placeholder instead
        // put an "unknown" row in the UI and priced those tokens at zero.
        var currentModel: String?
        var pendingByDate: [String: CodexTokenTotals] = [:]
        // Cumulative snapshots suppress streaming duplicates. Last-request
        // usage stays valid across independent agent counters and resets.
        var previous: CodexTokenTotals?
        var previousTimestamp: Double?
        var requestScope: String?
        var pendingUsage: [CodexUsageEvent] = []
        var timestampsByDate: [String: [Date]] = [:]
        var turnTimestampsByDay: [String: [Double]] = [:]
        var patchEventsByDay: [String: [CodexPatchEvent]] = [:]
        var activeMinuteBucketsByDay: [String: [Int]] = [:]

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue   // a partially written or corrupt line must not abort the file
            }

            let payload = event["payload"] as? [String: Any]
            let timestamp = (event["timestamp"] as? String).flatMap(parseTimestamp)

            if let timestamp {
                let day = Formatters.isoDay.string(from: timestamp)
                timestampsByDate[day, default: []].append(timestamp)
                activeMinuteBucketsByDay[day, default: []].append(Int((timestamp.timeIntervalSince1970 / 60).rounded(.down)))
                aggregate.latestEventAt = max(aggregate.latestEventAt, timestamp.timeIntervalSince1970)
            }

            switch event["type"] as? String {
            case "session_meta":
                previous = nil
                previousTimestamp = nil
                currentModel = nil
                requestScope = (payload?["id"] as? String) ?? (payload?["session_id"] as? String)
                if let sessionId = (payload?["session_id"] as? String) ?? (payload?["id"] as? String) {
                    aggregate.sessionId = sessionId
                }

            case "turn_context":
                if let turnID = payload?["turn_id"] as? String { requestScope = turnID }
                if let model = payload?["model"] as? String, !model.isEmpty {
                    if currentModel == nil, !pendingByDate.isEmpty {
                        for (day, buffered) in pendingByDate {
                            var models = aggregate.tokens[day] ?? [:]
                            models[model] = (models[model] ?? CodexTokenTotals()) + buffered
                            aggregate.tokens[day] = models
                        }
                        pendingByDate = [:]
                    }
                    currentModel = model
                    if !pendingUsage.isEmpty {
                        aggregate.usageEvents += pendingUsage.map { event in
                            var event = event
                            event.model = model
                            return event
                        }
                        pendingUsage = []
                    }
                }

            case "event_msg":
                guard let payload else { break }
                switch payload["type"] as? String {
                case "task_started":
                    if let timestamp {
                        let day = Formatters.isoDay.string(from: timestamp)
                        aggregate.turns[day, default: 0] += 1
                        turnTimestampsByDay[day, default: []].append(timestamp.timeIntervalSince1970)
                    }

                case "token_count":
                    if let limits = payload["rate_limits"] as? [String: Any],
                       let snapshot = snapshot(fromRolloutLimits: limits) {
                        // Last one wins: the newest block in the file is current.
                        aggregate.latestSnapshot = snapshot
                    }
                    // `info` is null on many events; those carry limits only.
                    guard let info = payload["info"] as? [String: Any],
                          let raw = info["total_token_usage"] as? [String: Any],
                          let timestamp else { break }
                    let cumulative = totals(fromTotalUsage: raw)
                    let day = Formatters.isoDay.string(from: timestamp)
                    defer {
                        previous = cumulative
                        previousTimestamp = timestamp.timeIntervalSince1970
                    }
                    if cumulative == previous, previousTimestamp == timestamp.timeIntervalSince1970 { break }
                    // A first/reset event can carry real usage. A repeated
                    // cumulative snapshot is still zero, even when last usage repeats.
                    let lastUsage = (info["last_token_usage"] as? [String: Any]).map(totals(fromTotalUsage:))
                    let delta: CodexTokenTotals?
                    if cumulative == previous {
                        // Keep proof of a repeated snapshot: another partial
                        // replay may begin here and mistake it for a first request.
                        delta = CodexTokenTotals()
                    } else if previous == nil {
                        delta = lastUsage == cumulative ? lastUsage : nil
                    } else {
                        delta = lastUsage ?? previous.flatMap { difference(cumulative, minus: $0) }
                    }
                    guard let delta else { break }
                    let usage = CodexUsageEvent(
                        timestamp: timestamp.timeIntervalSince1970, day: day,
                        model: currentModel ?? "unknown", cumulative: cumulative, delta: delta, requestScope: requestScope
                    )
                    if currentModel != nil {
                        aggregate.usageEvents.append(usage)
                    } else {
                        pendingUsage.append(usage)
                    }
                    guard delta.totalBillableTokens > 0 else { break }
                    guard let currentModel else {
                        pendingByDate[day] = (pendingByDate[day] ?? CodexTokenTotals()) + delta
                        break
                    }
                    var models = aggregate.tokens[day] ?? [:]
                    models[currentModel] = (models[currentModel] ?? CodexTokenTotals()) + delta
                    aggregate.tokens[day] = models

                default:
                    break
                }

            // Tool calls are wrapped: the envelope's `type` is `response_item`
            // and the tool kind lives in `payload.type`. Matching
            // `custom_tool_call` at the envelope level silently never fires,
            // which is exactly how this shipped as `linesWritten: 0` on real
            // data while a fixture that encoded the wrong shape stayed green.
            case "response_item":
                guard let payload,
                      payload["type"] as? String == "custom_tool_call",
                      payload["name"] as? String == "apply_patch",
                      let input = payload["input"] as? String,
                      let timestamp else { break }
                let day = Formatters.isoDay.string(from: timestamp)
                let lines = addedLineCount(inPatch: input)
                aggregate.linesAdded[day, default: 0] += lines
                let id = (payload["call_id"] as? String) ?? "\(timestamp.timeIntervalSince1970)_\(lines)"
                patchEventsByDay[day, default: []].append(CodexPatchEvent(id: id, lines: lines))

            default:
                break
            }
        }

        // Unknown pricing must not erase real token usage.
        aggregate.usageEvents += pendingUsage

        for (day, stamps) in timestampsByDate {
            aggregate.activeMinutes[day] = activeMinutes(stamps)
        }

        aggregate.turnTimestampsByDay = turnTimestampsByDay
        aggregate.patchEventsByDay = patchEventsByDay
        // Dedup within the file: a replay-heavy session only needs the union
        // of these sets across files, not one entry per raw event.
        aggregate.activeMinuteBucketsByDay = activeMinuteBucketsByDay.mapValues { Array(Set($0)).sorted() }

        return aggregate
    }

    // MARK: - Helpers

    static func addedLineCount(inPatch patch: String) -> Int {
        patch.split(separator: "\n", omittingEmptySubsequences: false).reduce(into: 0) { count, line in
            // `+++` is a unified-diff file header, not an added line.
            if line.hasPrefix("+") && !line.hasPrefix("+++") { count += 1 }
        }
    }

    /// Sum of gaps between consecutive events, excluding gaps longer than
    /// `idleGapSeconds`. Rounded up so any activity at all reads as one minute.
    static func activeMinutes(_ timestamps: [Date]) -> Int {
        guard timestamps.count > 1 else { return timestamps.isEmpty ? 0 : 1 }
        let sorted = timestamps.sorted()
        var seconds: TimeInterval = 0
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            let gap = next.timeIntervalSince(previous)
            if gap > 0, gap <= idleGapSeconds { seconds += gap }
        }
        return max(Int((seconds / 60).rounded()), 1)
    }

    private static func totals(fromTotalUsage raw: [String: Any]) -> CodexTokenTotals {
        CodexTokenTotals(
            inputTokens: raw["input_tokens"] as? Int ?? 0,
            cachedInputTokens: raw["cached_input_tokens"] as? Int ?? 0,
            cacheWriteTokens: raw["cache_write_input_tokens"] as? Int ?? 0,
            outputTokens: raw["output_tokens"] as? Int ?? 0
        )
    }

    /// Nil when any counter went backwards, which means the session's counter
    /// restarted. The caller rebases instead of recording negative usage.
    /// Not private: `CodexSessionCache` reuses it for its cross-file merge.
    static func difference(_ current: CodexTokenTotals, minus base: CodexTokenTotals) -> CodexTokenTotals? {
        guard current.inputTokens >= base.inputTokens,
              current.cachedInputTokens >= base.cachedInputTokens,
              current.cacheWriteTokens >= base.cacheWriteTokens,
              current.outputTokens >= base.outputTokens else { return nil }
        return CodexTokenTotals(
            inputTokens: current.inputTokens - base.inputTokens,
            cachedInputTokens: current.cachedInputTokens - base.cachedInputTokens,
            cacheWriteTokens: current.cacheWriteTokens - base.cacheWriteTokens,
            outputTokens: current.outputTokens - base.outputTokens
        )
    }

    /// Rollout files express window length in minutes and use `primary` /
    /// `secondary` keys, unlike the endpoint's seconds and `*_window` keys.
    static func snapshot(fromRolloutLimits limits: [String: Any]) -> CodexRateLimitSnapshot? {
        func window(_ key: String) -> CodexRateLimitSnapshot.Window? {
            guard let raw = limits[key] as? [String: Any],
                  let minutes = raw["window_minutes"] as? Double else { return nil }
            return CodexRateLimitSnapshot.Window(
                usedPercent: raw["used_percent"] as? Double ?? 0,
                windowSeconds: minutes * 60,
                resetAt: (raw["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            )
        }

        let windows = [window("secondary"), window("primary")]
            .compactMap { $0 }
            .sorted { $0.windowSeconds < $1.windowSeconds }
        guard !windows.isEmpty else { return nil }

        let credits = limits["credits"] as? [String: Any]
        let hasCredits = credits?["has_credits"] as? Bool ?? false
        let unlimited = credits?["unlimited"] as? Bool ?? false

        return CodexRateLimitSnapshot(
            windows: windows,
            scoped: [],   // rollout blocks carry no per-model limits; only the endpoint does
            planType: limits["plan_type"] as? String,
            creditsBalance: (hasCredits && !unlimited) ? credits?["balance"] as? String : nil,
            hasCredits: hasCredits,
            unlimitedCredits: unlimited,
            reachedType: limits["rate_limit_reached_type"] as? String,
            spendControlReached: (limits["spend_control_reached"] as? Bool) ?? false
        )
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        Formatters.isoFractional.date(from: raw) ?? Formatters.iso.date(from: raw)
    }
}
