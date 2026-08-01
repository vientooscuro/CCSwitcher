import XCTest
@testable import CCSwitcher

/// `CodexSessionCache.mergedTokensByDayAndModel` is a pure static function, so
/// these tests exercise it directly with parsed fixtures and hand-built
/// aggregates instead of touching the on-disk cache.
final class CodexSessionCacheTests: XCTestCase {

    private func parseFixture(_ name: String) throws -> CodexRolloutAggregate {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "jsonl") else {
            XCTFail("\(name).jsonl fixture not found in the test bundle")
            throw CocoaError(.fileNoSuchFile)
        }
        guard let aggregate = CodexRolloutParser.parse(contentsOf: url.path, relativePath: "\(name).jsonl", mtime: 1) else {
            XCTFail("parser returned nil for a valid fixture")
            throw CocoaError(.fileReadCorruptFile)
        }
        return aggregate
    }

    private func naiveSum(_ aggregates: [CodexRolloutAggregate]) -> Int {
        aggregates.reduce(0) { total, aggregate in
            total + aggregate.tokens.values.reduce(0) { sum, models in
                sum + models.values.reduce(0) { $0 + $1.totalBillableTokens }
            }
        }
    }

    /// Old, buggy behavior for `turns`/`linesAdded`/`activeMinutes`: each
    /// file's own per-file count summed across files.
    private func naiveActivitySum(_ aggregates: [CodexRolloutAggregate], key: KeyPath<CodexRolloutAggregate, [String: Int]>) -> Int {
        aggregates.reduce(0) { $0 + $1[keyPath: key].values.reduce(0, +) }
    }

    /// `codex-rollout-resumed.jsonl` shares `session_id` "s1" with
    /// `codex-rollout.jsonl` and replays its `token_count` events before
    /// adding a new tail on 2026-08-01. Summing each file's own per-file
    /// totals (the old behavior) counts the shared history twice; the merge
    /// must not.
    func testSharedPrefixIsNotDoubleCountedAcrossResumedSessionFiles() throws {
        let original = try parseFixture("codex-rollout")
        let resumed = try parseFixture("codex-rollout-resumed")
        XCTAssertEqual(original.sessionId, "s1")
        XCTAssertEqual(resumed.sessionId, "s1")

        let merged = CodexSessionCache.mergedTokensByDayAndModel(from: [original, resumed])
        let mergedTotal = merged.values.reduce(0) { total, models in
            total + models.values.reduce(0) { $0 + $1.totalBillableTokens }
        }

        // The old, buggy behavior: each file's own per-file delta view summed
        // across files. It double-counts every shared event.
        XCTAssertLessThan(mergedTotal, naiveSum([original, resumed]))
    }

    /// The new tail unique to the resumed file lands on its own day and model,
    /// proving per-day/per-model attribution survives the cross-file merge.
    func testPerDayAttributionSurvivesDedup() throws {
        let original = try parseFixture("codex-rollout")
        let resumed = try parseFixture("codex-rollout-resumed")
        let merged = CodexSessionCache.mergedTokensByDayAndModel(from: [original, resumed])

        let tail = try XCTUnwrap(merged["2026-08-01"]?["gpt-5.6-echo"])
        // 4300/3200/0/500 -> 4800/3400/0/650, i.e. two new deltas of
        // (300,200,0,100) and (300,200,0,150), unique to the resumed file.
        XCTAssertEqual(tail.inputTokens, 600)
        XCTAssertEqual(tail.cachedInputTokens, 400)
        XCTAssertEqual(tail.outputTokens, 250)

        // 2026-07-31 is untouched by the resumed file's new tail: the delta
        // there comes entirely from history both files agree on.
        let day31 = try XCTUnwrap(merged["2026-07-31"]?["gpt-5.6-luna"])
        XCTAssertEqual(day31.inputTokens, 50)
        XCTAssertEqual(day31.outputTokens, 15)
    }

    /// A subagent file's cumulative counter starts mid-curve — matching an
    /// observation the main thread's file already recorded — then climbs past
    /// where the main file stopped. Only the unique tail beyond the shared
    /// point should be attributed to the subagent.
    func testSubagentStartingMidCurveContributesOnlyItsUniqueTail() {
        let main = CodexRolloutAggregate(
            sessionId: "sub-session",
            tokenObservationRuns: [
                CodexTokenObservationRun(day: "2026-07-30", model: "gpt-5.6-sol", cumulatives: [
                    CodexTokenTotals(inputTokens: 100, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 10),
                    CodexTokenTotals(inputTokens: 300, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 30),
                    CodexTokenTotals(inputTokens: 600, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 60),
                ]),
            ]
        )
        let subagent = CodexRolloutAggregate(
            sessionId: "sub-session",
            tokenObservationRuns: [
                // Starts exactly at the main file's second observation.
                CodexTokenObservationRun(day: "2026-07-30", model: "gpt-5.6-sol", cumulatives: [
                    CodexTokenTotals(inputTokens: 300, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 30),
                ]),
                CodexTokenObservationRun(day: "2026-07-30", model: "gpt-5.6-sub", cumulatives: [
                    CodexTokenTotals(inputTokens: 700, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 70),
                    CodexTokenTotals(inputTokens: 900, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 90),
                ]),
            ]
        )

        let merged = CodexSessionCache.mergedTokensByDayAndModel(from: [main, subagent])

        // Main file's own deltas: 100->300 and 300->600.
        let sol = merged["2026-07-30"]?["gpt-5.6-sol"]
        XCTAssertEqual(sol?.inputTokens, 500)   // (300-100) + (600-300)
        XCTAssertEqual(sol?.outputTokens, 50)

        // Subagent's unique tail: 600->700 and 700->900, not 300->700.
        let sub = merged["2026-07-30"]?["gpt-5.6-sub"]
        XCTAssertEqual(sub?.inputTokens, 300)   // (700-600) + (900-700)
        XCTAssertEqual(sub?.outputTokens, 30)
    }

    /// Two files with different session_ids must not have their observations
    /// merged, even if their cumulative snapshots happen to coincide.
    func testDifferentSessionIdsSumIndependently() {
        let sessionA = CodexRolloutAggregate(
            sessionId: "session-a",
            tokenObservationRuns: [
                CodexTokenObservationRun(day: "2026-09-01", model: "gpt-5.6-sol", cumulatives: [
                    CodexTokenTotals(inputTokens: 1000, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 0),
                    CodexTokenTotals(inputTokens: 1400, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 0),
                ]),
            ]
        )
        // Same day, same model, and (crucially) the same cumulative values as
        // session A — a coincidence that must not fool the merge into
        // deduplicating across sessions.
        let sessionB = CodexRolloutAggregate(
            sessionId: "session-b",
            tokenObservationRuns: [
                CodexTokenObservationRun(day: "2026-09-01", model: "gpt-5.6-sol", cumulatives: [
                    CodexTokenTotals(inputTokens: 1000, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 0),
                    CodexTokenTotals(inputTokens: 1400, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 0),
                ]),
            ]
        )

        let merged = CodexSessionCache.mergedTokensByDayAndModel(from: [sessionA, sessionB])

        // If sessions were merged before dedup, this would read 400: the
        // identical snapshots would collapse into one. Two independent
        // sessions must each contribute their own 400 delta.
        XCTAssertEqual(merged["2026-09-01"]?["gpt-5.6-sol"]?.inputTokens, 800)
    }

    // MARK: - Activity (turns / linesAdded / activeMinutes)

    /// `codex-rollout-resumed.jsonl` also replays `codex-rollout.jsonl`'s
    /// `task_started` and `apply_patch` events verbatim before adding a new
    /// tail on 2026-08-01 — the same fixture used for the token dedup tests.
    func testTurnsSharedPrefixIsNotDoubleCountedAcrossResumedSessionFiles() throws {
        let original = try parseFixture("codex-rollout")
        let resumed = try parseFixture("codex-rollout-resumed")

        let merged = CodexSessionCache.mergedActivityByDay(from: [original, resumed])
        let mergedTurns = merged.values.reduce(0) { $0 + $1.turns }

        XCTAssertLessThan(mergedTurns, naiveActivitySum([original, resumed], key: \.turns))
        // 2 shared turns on the 30th + 1 shared on the 31st + 1 new on the 1st.
        XCTAssertEqual(mergedTurns, 4)
    }

    func testLinesAddedSharedPrefixIsNotDoubleCountedAcrossResumedSessionFiles() throws {
        let original = try parseFixture("codex-rollout")
        let resumed = try parseFixture("codex-rollout-resumed")

        let merged = CodexSessionCache.mergedActivityByDay(from: [original, resumed])
        let mergedLines = merged.values.reduce(0) { $0 + $1.linesAdded }

        XCTAssertLessThan(mergedLines, naiveActivitySum([original, resumed], key: \.linesAdded))
        // 2 shared lines (call_id "c1") on the 30th + 1 new line (call_id "c2") on the 1st.
        XCTAssertEqual(mergedLines, 3)
    }

    func testActiveMinutesSharedPrefixIsNotDoubleCountedAcrossResumedSessionFiles() throws {
        let original = try parseFixture("codex-rollout")
        let resumed = try parseFixture("codex-rollout-resumed")

        let merged = CodexSessionCache.mergedActivityByDay(from: [original, resumed])
        let mergedMinutes = merged.values.reduce(0) { $0 + $1.activeMinutes }

        XCTAssertLessThan(mergedMinutes, naiveActivitySum([original, resumed], key: \.activeMinutes))
    }

    /// The new tail unique to the resumed file lands on its own day, and the
    /// shared history's per-day totals are unaffected by having two files
    /// agree on them.
    func testActivityPerDayAttributionSurvivesDedup() throws {
        let original = try parseFixture("codex-rollout")
        let resumed = try parseFixture("codex-rollout-resumed")
        let merged = CodexSessionCache.mergedActivityByDay(from: [original, resumed])

        let day30 = try XCTUnwrap(merged["2026-07-30"])
        XCTAssertEqual(day30.turns, 2)
        XCTAssertEqual(day30.linesAdded, 2)
        XCTAssertEqual(day30.activeMinutes, 8)

        let day31 = try XCTUnwrap(merged["2026-07-31"])
        XCTAssertEqual(day31.turns, 1)
        XCTAssertEqual(day31.activeMinutes, 1)

        let day01 = try XCTUnwrap(merged["2026-08-01"])
        XCTAssertEqual(day01.turns, 1)
        XCTAssertEqual(day01.linesAdded, 1)
        XCTAssertEqual(day01.activeMinutes, 5)
    }

    /// Two files with different session_ids must not have their turns/patches
    /// merged, even when their dedup keys coincidentally collide.
    func testActivityDifferentSessionIdsSumIndependently() {
        let sessionA = CodexRolloutAggregate(
            sessionId: "session-a",
            turnTimestampsByDay: ["2026-09-01": [1000, 1300]],
            patchEventsByDay: ["2026-09-01": [CodexPatchEvent(id: "shared-id", lines: 10)]],
            activeMinuteBucketsByDay: ["2026-09-01": [100, 101]]
        )
        // Same day and coincidentally identical dedup keys as session A — must
        // not be folded into session A's counts.
        let sessionB = CodexRolloutAggregate(
            sessionId: "session-b",
            turnTimestampsByDay: ["2026-09-01": [1000, 1300]],
            patchEventsByDay: ["2026-09-01": [CodexPatchEvent(id: "shared-id", lines: 10)]],
            activeMinuteBucketsByDay: ["2026-09-01": [100, 101]]
        )

        let merged = CodexSessionCache.mergedActivityByDay(from: [sessionA, sessionB])

        // If sessions were merged before dedup, turns would read 2 and lines
        // 10 — the coincidental collisions would collapse into one.
        XCTAssertEqual(merged["2026-09-01"]?.turns, 4)
        XCTAssertEqual(merged["2026-09-01"]?.linesAdded, 20)
    }
}
