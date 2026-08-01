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
        // Baseline for delta accounting. `total_token_usage` is cumulative per
        // session and was strictly monotonic across 23063 real events, so
        // differencing it is exact. Summing `last_token_usage` instead
        // overshoots by roughly 6% because streaming repeats events.
        var previous: CodexTokenTotals?
        var timestampsByDate: [String: [Date]] = [:]
        // Raw cumulative snapshots, buffered the same way as `pendingByDate`
        // until the model is known, then flushed. Kept independent of the
        // delta bookkeeping above because cross-file dedup (CodexSessionCache)
        // needs the cumulative value itself, not this file's own delta.
        var pendingObservations: [(day: String, cumulative: CodexTokenTotals)] = []
        var runs: [CodexTokenObservationRun] = []
        var turnTimestampsByDay: [String: [Double]] = [:]
        var patchEventsByDay: [String: [CodexPatchEvent]] = [:]
        var activeMinuteBucketsByDay: [String: [Int]] = [:]
        // Collapses consecutive same-day/same-model snapshots into one run
        // instead of one entry per event — see `CodexTokenObservationRun`.
        func recordObservation(day: String, model: String, cumulative: CodexTokenTotals) {
            if let last = runs.indices.last, runs[last].day == day, runs[last].model == model {
                runs[last].cumulatives.append(cumulative)
            } else {
                runs.append(CodexTokenObservationRun(day: day, model: model, cumulatives: [cumulative]))
            }
        }

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
                if let sessionId = payload?["session_id"] as? String {
                    aggregate.sessionId = sessionId
                }

            case "turn_context":
                if let model = payload?["model"] as? String, !model.isEmpty {
                    if currentModel == nil, !pendingByDate.isEmpty {
                        for (day, buffered) in pendingByDate {
                            var models = aggregate.tokens[day] ?? [:]
                            models[model] = (models[model] ?? CodexTokenTotals()) + buffered
                            aggregate.tokens[day] = models
                        }
                        pendingByDate = [:]
                    }
                    if currentModel == nil, !pendingObservations.isEmpty {
                        for pending in pendingObservations {
                            recordObservation(day: pending.day, model: model, cumulative: pending.cumulative)
                        }
                        pendingObservations = []
                    }
                    currentModel = model
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
                    // Record the raw snapshot regardless of delta bookkeeping —
                    // even the event that sets this file's own baseline may be
                    // mid-session from the session's point of view.
                    if let currentModel {
                        recordObservation(day: day, model: currentModel, cumulative: cumulative)
                    } else {
                        pendingObservations.append((day: day, cumulative: cumulative))
                    }
                    defer { previous = cumulative }
                    guard let base = previous else { break }   // first event only sets the baseline
                    let delta = difference(cumulative, minus: base)
                    guard let delta else { break }             // regression: rebase silently
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

        if !pendingByDate.isEmpty {
            // No `turn_context` anywhere in the file, so the model is genuinely
            // unknowable and the tokens cannot be priced. Dropping them is
            // better than inventing a model or surfacing an "unknown" row.
            let dropped = pendingByDate.values.reduce(0) { $0 + $1.totalBillableTokens }
            log.warning("parse: \(relativePath) has no turn_context, dropping \(dropped) unattributable tokens")
        }

        for (day, stamps) in timestampsByDate {
            aggregate.activeMinutes[day] = activeMinutes(stamps)
        }

        // pendingObservations left over here shares the same fate as
        // pendingByDate above: no turn_context ever appeared, so it's dropped.
        aggregate.tokenObservationRuns = runs
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
