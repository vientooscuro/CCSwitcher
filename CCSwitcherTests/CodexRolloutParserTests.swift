import XCTest
@testable import CCSwitcher

final class CodexRolloutParserTests: XCTestCase {
    func testTokenEventPreservesRequestServiceTier() throws {
        let text = """
        {"type":"session_meta","payload":{"id":"session"}}
        {"type":"turn_context","payload":{"turn_id":"turn","model":"gpt-5.4"}}
        {"timestamp":"2026-09-07T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"service_tier":"priority","total_token_usage":{"input_tokens":300000,"cached_input_tokens":200000,"output_tokens":1000},"last_token_usage":{"input_tokens":300000,"cached_input_tokens":200000,"output_tokens":1000}}}}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try text.write(to: url, atomically: true, encoding: .utf8)
        let aggregate = try XCTUnwrap(CodexRolloutParser.parse(contentsOf: url.path, relativePath: "tier.jsonl", mtime: 1))
        XCTAssertEqual(aggregate.usageEvents.first?.serviceTier, .priority)
    }

    private func parseFixture() throws -> CodexRolloutAggregate {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "codex-rollout", withExtension: "jsonl", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "codex-rollout", withExtension: "jsonl") else {
            XCTFail("codex-rollout.jsonl fixture not found in the test bundle")
            throw CocoaError(.fileNoSuchFile)
        }
        guard let aggregate = CodexRolloutParser.parse(contentsOf: url.path, relativePath: "codex-rollout.jsonl", mtime: 1) else {
            XCTFail("parser returned nil for a valid fixture")
            throw CocoaError(.fileReadCorruptFile)
        }
        return aggregate
    }

    /// Without last-request usage, a partial file's initial cumulative value
    /// is only a baseline. Real first-request events are covered separately.
    func testFirstEventEstablishesBaseline() throws {
        let totals = try parseFixture().tokens["2026-07-30"]!["gpt-5.6-sol"]!
        // 1000 -> 3000 is the only sol delta on the 30th: +2000 input, +1700 cached, +200 output.
        XCTAssertEqual(totals.inputTokens, 2000)
        XCTAssertEqual(totals.cachedInputTokens, 1700)
        XCTAssertEqual(totals.outputTokens, 200)
    }

    /// The delta after a `turn_context` switch belongs to the new model.
    func testDeltaAfterModelSwitchIsAttributedToNewModel() throws {
        let totals = try parseFixture().tokens["2026-07-30"]!["gpt-5.6-luna"]!
        // 3000 -> 4000 lands on luna: +1000 input, +500 cached, +100 output.
        XCTAssertEqual(totals.inputTokens, 1000)
        XCTAssertEqual(totals.cachedInputTokens, 500)
        XCTAssertEqual(totals.outputTokens, 100)
    }

    /// A regression means the counter restarted; it must rebase, not go negative.
    func testCounterRegressionRebasesWithoutNegativeTokens() throws {
        let aggregate = try parseFixture()
        for (_, models) in aggregate.tokens {
            for (model, totals) in models {
                XCTAssertGreaterThanOrEqual(totals.inputTokens, 0, "negative input for \(model)")
                XCTAssertGreaterThanOrEqual(totals.outputTokens, 0, "negative output for \(model)")
                XCTAssertGreaterThanOrEqual(totals.cachedInputTokens, 0, "negative cached for \(model)")
            }
        }
    }

    /// Deltas are attributed to the local date of the event that carried them,
    /// so a session spanning midnight splits across two days.
    func testDeltasSplitAcrossDayBoundary() throws {
        let aggregate = try parseFixture()
        XCTAssertNotNil(aggregate.tokens["2026-07-30"])
        XCTAssertNotNil(aggregate.tokens["2026-07-31"])
        // After the rebase to 10, the 31st sees 10 -> 60: +50 input, +15 output.
        let day31 = aggregate.tokens["2026-07-31"]!["gpt-5.6-luna"]!
        XCTAssertEqual(day31.inputTokens, 50)
        XCTAssertEqual(day31.outputTokens, 15)
        XCTAssertEqual(day31.cachedInputTokens, 10)
    }

    func testTurnsAreCountedPerDay() throws {
        let aggregate = try parseFixture()
        XCTAssertEqual(aggregate.turns["2026-07-30"], 2)
        XCTAssertEqual(aggregate.turns["2026-07-31"], 1)
    }

    /// Only `+` lines count, and the `+++` header line of a unified diff is not
    /// an added line.
    func testAddedLinesAreCountedFromApplyPatch() throws {
        XCTAssertEqual(try parseFixture().linesAdded["2026-07-30"], 2)
    }

    func testNullInfoTokenCountIsIgnoredForCost() throws {
        // The null-info event carries rate limits but no usage; if it were
        // treated as a zero baseline the following delta would be inflated.
        let totals = try parseFixture().tokens["2026-07-30"]!["gpt-5.6-sol"]!
        XCTAssertEqual(totals.inputTokens, 2000)
    }

    func testMalformedLineDoesNotAbortTheParse() throws {
        // The fixture contains a line of plain text after the last usage event.
        // Reaching the assertions at all proves the parser skipped it.
        XCTAssertNotNil(try parseFixture().latestSnapshot)
    }

    /// The newest `rate_limits` block in the file is the offline fallback.
    func testLatestRateLimitSnapshotIsTakenFromTheLastBlock() throws {
        let snapshot = try parseFixture().latestSnapshot!
        XCTAssertEqual(snapshot.planType, "prolite")
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 65)
        XCTAssertEqual(snapshot.windows[0].windowSeconds, 10_080 * 60)
        XCTAssertEqual(snapshot.windows[0].resetAt, Date(timeIntervalSince1970: 1_786_033_302))
    }

    func testActiveMinutesExcludeLongIdleGaps() throws {
        let aggregate = try parseFixture()
        // The 30th spans 10:00:00 to 10:08:00 with no gap above ten minutes.
        XCTAssertEqual(aggregate.activeMinutes["2026-07-30"], 8)
        // The 31st has events one minute apart.
        XCTAssertEqual(aggregate.activeMinutes["2026-07-31"], 1)
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(CodexRolloutParser.parse(contentsOf: "/nonexistent/rollout.jsonl", relativePath: "x", mtime: 1))
    }
}
