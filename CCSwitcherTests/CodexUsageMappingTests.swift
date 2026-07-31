import XCTest
import SwiftUI
@testable import CCSwitcher

final class CodexUsageMappingTests: XCTestCase {

    private func loadFixture() throws -> CodexUsageResponse {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "codex-usage", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "codex-usage", withExtension: "json") else {
            XCTFail("codex-usage.json fixture not found in the test bundle")
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(CodexUsageResponse.self, from: Data(contentsOf: url))
    }

    func testDecodesLiveFixture() throws {
        let usage = try loadFixture()
        XCTAssertEqual(usage.planType, "pro")
        XCTAssertEqual(usage.email, "user@example.com")
        XCTAssertEqual(usage.rateLimit?.primaryWindow?.usedPercent, 65)
        XCTAssertNil(usage.rateLimit?.secondaryWindow)
        XCTAssertEqual(usage.additionalRateLimits?.count, 1)
    }

    /// The 7-day window arrived in the `primary` slot on the real account, so
    /// classification must key off duration, never off slot name.
    func testPrimarySevenDayWindowMapsToWeekly() throws {
        let windows = CodexDisplayMapper.windows(from: try loadFixture())
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].kind, .weekly)
        XCTAssertEqual(windows[0].utilization, 65)
        XCTAssertEqual(windows[0].windowSeconds, 604_800)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_786_033_302))
    }

    func testBothWindowsMapAndSortSessionFirst() throws {
        let json = """
        { "rate_limit": { "primary_window": { "used_percent": 10, "limit_window_seconds": 604800, "reset_at": 100 },
                          "secondary_window": { "used_percent": 2, "limit_window_seconds": 18000, "reset_at": 50 } } }
        """
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        let windows = CodexDisplayMapper.windows(from: usage)
        XCTAssertEqual(windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(windows[0].utilization, 2)
        XCTAssertEqual(windows[1].utilization, 10)
    }

    func testAdditionalRateLimitBecomesScopedLimit() throws {
        let scoped = CodexDisplayMapper.scopedLimits(from: try loadFixture())
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped[0].modelName, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(scoped[0].utilization, 12)
        XCTAssertEqual(scoped[0].resetsAt, Date(timeIntervalSince1970: 1_786_099_073))
    }

    func testAdditionalLimitWithoutWindowIsSkipped() throws {
        let json = """
        { "additional_rate_limits": [ { "limit_name": "Ghost", "rate_limit": { "primary_window": null } } ] }
        """
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        XCTAssertTrue(CodexDisplayMapper.scopedLimits(from: usage).isEmpty)
    }

    func testCreditsWithZeroBalanceIsDisabled() throws {
        let credits = CodexDisplayMapper.credits(from: try loadFixture())
        XCTAssertNotNil(credits)
        XCTAssertFalse(credits!.isEnabled)
        XCTAssertFalse(credits!.isUnlimited)
    }

    func testUnlimitedCreditsAreReportedAsUnlimited() throws {
        let json = #"{ "credits": { "has_credits": true, "unlimited": true, "balance": "0" } }"#
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        let credits = CodexDisplayMapper.credits(from: usage)
        XCTAssertTrue(credits!.isUnlimited)
        XCTAssertTrue(credits!.isEnabled)
    }

    func testPositiveBalanceIsSurfacedAsText() throws {
        let json = #"{ "credits": { "has_credits": true, "unlimited": false, "balance": "12.50" } }"#
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(CodexDisplayMapper.credits(from: usage)?.balanceText, "12.50")
    }

    func testNoticeIsNilWhenNothingIsWrong() throws {
        XCTAssertNil(CodexDisplayMapper.notice(from: try loadFixture(), isStale: false))
    }

    func testStaleSnapshotProducesNotice() throws {
        XCTAssertNotNil(CodexDisplayMapper.notice(from: try loadFixture(), isStale: true))
    }

    func testSpendControlReachedProducesNotice() throws {
        let json = #"{ "spend_control": { "reached": true, "individual_limit": 50 } }"#
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(CodexDisplayMapper.notice(from: usage, isStale: false))
    }

    func testRateLimitReachedTypeProducesNotice() throws {
        let json = #"{ "rate_limit_reached_type": "weekly" }"#
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(CodexDisplayMapper.notice(from: usage, isStale: false))
    }

    func testPlanBadgeIsCapitalized() {
        XCTAssertEqual(CodexDisplayMapper.planBadge(from: "pro"), "Pro")
        XCTAssertEqual(CodexDisplayMapper.planBadge(from: "prolite"), "Prolite")
        XCTAssertNil(CodexDisplayMapper.planBadge(from: nil))
    }

    /// Rollout files carry window lengths in minutes rather than seconds.
    func testLocalSnapshotConvertsWindowMinutes() {
        let snapshot = CodexRateLimitSnapshot(
            windows: [.init(usedPercent: 2, windowSeconds: 300 * 60, resetAt: Date(timeIntervalSince1970: 42))],
            scoped: [],
            planType: "plus",
            creditsBalance: nil,
            hasCredits: false,
            unlimitedCredits: false,
            reachedType: nil,
            spendControlReached: false
        )
        let windows = CodexDisplayMapper.windows(from: snapshot)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].kind, .session)
        XCTAssertEqual(windows[0].windowSeconds, 18_000)
    }
}
