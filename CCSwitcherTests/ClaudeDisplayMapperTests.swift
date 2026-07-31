import XCTest
import SwiftUI
@testable import CCSwitcher

final class ClaudeDisplayMapperTests: XCTestCase {

    /// Shape returned by /api/oauth/usage: fixed session and weekly windows,
    /// a model-scoped weekly limit, and the extra-usage pool.
    private func decodeUsage(_ json: String) throws -> UsageAPIResponse {
        try JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
    }

    private let fullUsageJSON = """
    {
      "five_hour": { "utilization": 65, "resets_at": "2026-07-31T14:00:00.000Z" },
      "seven_day": { "utilization": 34, "resets_at": "2026-08-04T13:59:00.000Z" },
      "extra_usage": { "is_enabled": false, "monthly_limit": 100, "used_credits": 0, "utilization": 0 },
      "limits": [
        { "kind": "session", "percent": 65, "resets_at": "2026-07-31T14:00:00.000Z" },
        { "kind": "weekly_all", "percent": 34, "resets_at": "2026-08-04T13:59:00.000Z" },
        { "kind": "weekly_scoped", "percent": 5, "resets_at": "2026-08-04T14:00:00.000Z",
          "scope": { "model": { "id": "claude-fable-5", "display_name": "Fable" } } }
      ]
    }
    """

    private func account(active: Bool = true, label: String? = nil) -> Account {
        Account(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            email: "dan@gradient.photo",
            displayName: "Gradient",
            provider: .claudeCode,
            orgName: "Gradient",
            subscriptionType: "team",
            isActive: active,
            lastUsed: nil,
            customLabel: label
        )
    }

    func testWindowsAreSessionThenWeekly() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let windows = ClaudeDisplayMapper.windows(from: usage)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].kind, .session)
        XCTAssertEqual(windows[0].utilization, 65)
        XCTAssertEqual(windows[0].windowSeconds, 5 * 3600)
        XCTAssertEqual(windows[1].kind, .weekly)
        XCTAssertEqual(windows[1].utilization, 34)
        XCTAssertEqual(windows[1].windowSeconds, 7 * 86_400)
    }

    func testMissingWindowsAreOmittedRatherThanZeroed() throws {
        let usage = try decodeUsage(#"{ "seven_day": { "utilization": 12, "resets_at": null } }"#)
        let windows = ClaudeDisplayMapper.windows(from: usage)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].kind, .weekly)
        XCTAssertNil(windows[0].resetsAt)
    }

    func testScopedLimitIsMappedWithModelTint() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let scoped = ClaudeDisplayMapper.scopedLimits(from: usage)
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped[0].modelName, "Fable")
        XCTAssertEqual(scoped[0].utilization, 5)
        XCTAssertEqual(scoped[0].tint, Color.purple)
    }

    func testExtraUsageBecomesDisabledCreditPool() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let credits = ClaudeDisplayMapper.credits(from: usage)
        XCTAssertNotNil(credits)
        XCTAssertFalse(credits!.isEnabled)
        XCTAssertFalse(credits!.isUnlimited)
    }

    func testAbsentExtraUsageYieldsNoCreditPool() throws {
        let usage = try decodeUsage(#"{ "five_hour": { "utilization": 1, "resets_at": null } }"#)
        XCTAssertNil(ClaudeDisplayMapper.credits(from: usage))
    }

    func testCardObfuscatesEmailWhenRequested() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let card = ClaudeDisplayMapper.card(account: account(), usage: usage, error: nil, obfuscate: true)
        XCTAssertEqual(card.subtitle, "dan@gradient.photo".obfuscatedEmail())
        XCTAssertNotEqual(card.subtitle, "dan@gradient.photo")
    }

    func testCardShowsFullEmailWhenNotObfuscating() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let card = ClaudeDisplayMapper.card(account: account(), usage: usage, error: nil, obfuscate: false)
        XCTAssertEqual(card.subtitle, "dan@gradient.photo")
    }

    func testCardCapitalizesSubscriptionBadge() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let card = ClaudeDisplayMapper.card(account: account(), usage: usage, error: nil, obfuscate: false)
        XCTAssertEqual(card.planBadge, "Team")
    }

    func testCardWithoutUsageAndWithoutErrorIsEmpty() {
        let card = ClaudeDisplayMapper.card(account: account(), usage: nil, error: nil, obfuscate: false)
        XCTAssertTrue(card.isEmpty)
        XCTAssertTrue(card.windows.isEmpty)
    }

    func testCardCarriesErrorWhenPresent() {
        let error = ProviderErrorModel(message: "Session expired.", needsReauth: true, isRateLimited: false)
        let card = ClaudeDisplayMapper.card(account: account(), usage: nil, error: error, obfuscate: false)
        XCTAssertFalse(card.isEmpty)
        XCTAssertEqual(card.error?.message, "Session expired.")
        XCTAssertTrue(card.error!.needsReauth)
    }

    func testRateLimitedCardKeepsPreviouslyFetchedWindows() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let error = ProviderErrorModel(message: "API rate-limited.", needsReauth: false, isRateLimited: true)
        let card = ClaudeDisplayMapper.card(account: account(), usage: usage, error: error, obfuscate: false)
        XCTAssertEqual(card.windows.count, 2)
        XCTAssertTrue(card.error!.isRateLimited)
    }

    func testCustomLabelWinsOverDisplayName() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let card = ClaudeDisplayMapper.card(account: account(label: "Work"), usage: usage, error: nil, obfuscate: true)
        XCTAssertEqual(card.title, "Work")
    }

    func testActivityMapsAllFourClaudeModelsInFixedOrder() {
        var stats = ActivityStats()
        stats.conversationTurns = 37
        stats.activeCodingMinutes = 278
        stats.linesWritten = 2396
        stats.modelUsage = ["Opus": 611, "Sonnet": 0]

        let model = ClaudeDisplayMapper.activity(stats)
        XCTAssertEqual(model.turns, 37)
        XCTAssertEqual(model.activeTimeText, "4h 38m")
        XCTAssertEqual(model.linesWritten, 2396)
        XCTAssertEqual(model.perModel.map(\.displayName), ["Fable", "Opus", "Sonnet", "Haiku"])
        XCTAssertEqual(model.perModel.map(\.count), [0, 611, 0, 0])
    }

    func testCostMapsTodayAndDailySeries() {
        let summary = CostSummary(
            todayCost: 319.57,
            dailyCosts: [
                DailyCost(date: "2026-07-31", totalCost: 319.57, modelBreakdown: ["claude-opus-4-8": 319.57],
                          sessionCount: 3, inputTokens: 10, outputTokens: 20,
                          cacheWriteTokens: 30, cacheReadTokens: 40)
            ]
        )
        let model = ClaudeDisplayMapper.cost(summary)
        XCTAssertEqual(model.todayCost, 319.57, accuracy: 0.0001)
        XCTAssertEqual(model.daily.count, 1)
        XCTAssertEqual(model.daily[0].totalTokens, 100)
        XCTAssertEqual(model.totalCost, 319.57, accuracy: 0.0001)
    }

    func testHeaderUsesEffectiveNameAndBadge() {
        let header = ClaudeDisplayMapper.header(account: account(label: "Work"), obfuscate: true)
        XCTAssertEqual(header.title, "Work")
        XCTAssertEqual(header.planBadge, "Team")
    }

    func testRowReportsMissingCredentials() {
        let row = ClaudeDisplayMapper.row(account: account(), hasStoredCredentials: false, obfuscate: false)
        XCTAssertFalse(row.hasStoredCredentials)
        XCTAssertEqual(row.email, "dan@gradient.photo")
        XCTAssertTrue(row.isActive)
    }
}
