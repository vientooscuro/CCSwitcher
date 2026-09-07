import XCTest
@testable import CCSwitcher

final class CodexAccountingRegressionTests: XCTestCase {
    private func rollout(id: String, day: String = "2026-09-01", values: [Int], times: [Int]? = nil) -> String {
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"shared-root\",\"id\":\"\(id)\"}}"
        let context = "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"\(id)-turn\",\"model\":\"gpt-5.4\"}}"
        var previous = 0
        let events = values.enumerated().map { index, value in
            let last = value >= previous ? value - previous : value
            previous = value
            let seconds = String(format: "%02d", times?[index] ?? index)
            return "{\"timestamp\":\"\(day)T12:00:\(seconds).000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(value),\"cached_input_tokens\":\(value / 2),\"output_tokens\":0},\"last_token_usage\":{\"input_tokens\":\(last),\"cached_input_tokens\":\(last / 2),\"output_tokens\":0}}}}"
        }
        return ([meta, context] + events).joined(separator: "\n")
    }

    private func parse(_ text: String) throws -> CodexRolloutAggregate {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try text.write(to: file, atomically: true, encoding: .utf8)
        return try XCTUnwrap(CodexRolloutParser.parse(contentsOf: file.path, relativePath: file.lastPathComponent, mtime: 1))
    }

    func testFirstRequestAndRepeatedSnapshotAreCountedExactlyOnce() throws {
        let aggregate = try parse(rollout(id: "one", values: [100, 100, 300]))
        let totals = CodexSessionCache.mergedTokensByDayAndModel(from: [aggregate])
        XCTAssertEqual(totals["2026-09-01"]?["gpt-5.4"]?.inputTokens, 300)
    }

    func testIndependentAgentsSharingSessionDoNotShareCounterBaseline() throws {
        let one = try parse(rollout(id: "one", values: [100, 300], times: [0, 1]))
        let two = try parse(rollout(id: "two", values: [200, 500], times: [2, 3]))
        let totals = CodexSessionCache.mergedTokensByDayAndModel(from: [one, two])
        XCTAssertEqual(totals["2026-09-01"]?["gpt-5.4"]?.inputTokens, 800)
    }

    func testReplayedPrefixAndCounterResetKeepOriginalDays() throws {
        let prefix = rollout(id: "one", day: "2026-08-31", values: [100, 300])
        let original = try parse(prefix)
        let resumed = try parse(prefix + "\n" + rollout(id: "two", values: [20, 80], times: [2, 3]))
        let totals = CodexSessionCache.mergedTokensByDayAndModel(from: [original, resumed])
        XCTAssertEqual(totals["2026-08-31"]?["gpt-5.4"]?.inputTokens, 300)
        XCTAssertEqual(totals["2026-09-01"]?["gpt-5.4"]?.inputTokens, 80)
    }

    func testNewStreamMetadataDoesNotSuppressEqualCounters() throws {
        let first = rollout(id: "one", values: [100], times: [0])
        let second = rollout(id: "two", values: [100], times: [2])
        let aggregate = try parse(first + "\n" + second)
        let totals = CodexSessionCache.mergedTokensByDayAndModel(from: [aggregate])
        XCTAssertEqual(totals["2026-09-01"]?["gpt-5.4"]?.inputTokens, 200)
    }

    func testKnownModelWinsOverUnknownReplayInEitherOrder() throws {
        let known = try parse(rollout(id: "one", values: [100]))
        var unknown = known
        unknown.usageEvents = known.usageEvents.map {
            var event = $0
            event.model = "unknown"
            return event
        }
        for files in [[known, unknown], [unknown, known]] {
            let totals = CodexSessionCache.mergedTokensByDayAndModel(from: files)
            XCTAssertEqual(totals["2026-09-01"]?["gpt-5.4"]?.inputTokens, 100)
            XCTAssertNil(totals["2026-09-01"]?["unknown"])
        }
    }

    func testKnownServiceTierWinsOverUnknownReplayInEitherOrder() throws {
        let unknown = try parse(rollout(id: "one", values: [100]))
        var known = unknown
        known.usageEvents = unknown.usageEvents.map {
            var event = $0
            event.serviceTier = .priority
            return event
        }
        for files in [[known, unknown], [unknown, known]] {
            let events = CodexSessionCache.mergedUsageEvents(from: files)
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?.serviceTier, .priority)
        }
    }

    func testLongContextPricingUsesIndividualRequestsBeforeDailyAggregation() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try rollout(id: "two-requests", values: [200_000, 400_000])
            .write(to: home.appendingPathComponent("rollout-two-requests.jsonl"), atomically: true, encoding: .utf8)
        let cache = CodexSessionCache(sessionRoots: [home.path], cacheURL: home.appendingPathComponent("cache.json"))
        await cache.refreshFromFilesystem()
        let series = await cache.costSeries()
        XCTAssertEqual(series.totalCost, 0.55, accuracy: 1e-9)
    }

    func testRepeatedFirstSnapshotOfPartialReplayIsNotAnotherRequest() throws {
        let first = rollout(id: "one", values: [100], times: [0])
        let repeated = rollout(id: "one", values: [100], times: [2])
            .split(separator: "\n").last.map(String.init)!
        let full = try parse(first + "\n" + repeated)
        let partial = try parse(rollout(id: "one", values: [100], times: [2]))
        for files in [[full, partial], [partial, full]] {
            let totals = CodexSessionCache.mergedTokensByDayAndModel(from: files)
            XCTAssertEqual(totals["2026-09-01"]?["gpt-5.4"]?.inputTokens, 100)
        }
    }

    func testMidSessionInitialSnapshotOnlyEstablishesBaseline() throws {
        let text = rollout(id: "one", values: [100, 300, 500])
        let lines = text.split(separator: "\n").map(String.init)
        let partial = try parse((Array(lines.prefix(2)) + Array(lines.suffix(2))).joined(separator: "\n"))
        let totals = CodexSessionCache.mergedTokensByDayAndModel(from: [partial])
        XCTAssertEqual(totals["2026-09-01"]?["gpt-5.4"]?.inputTokens, 200)
    }

    func testExactDuplicateLineDoesNotEraseRealRequest() throws {
        let first = rollout(id: "one", values: [100])
        let duplicate = String(first.split(separator: "\n").last!)
        let aggregate = try parse(first + "\n" + duplicate)
        let totals = CodexSessionCache.mergedTokensByDayAndModel(from: [aggregate])
        XCTAssertEqual(totals["2026-09-01"]?["gpt-5.4"]?.inputTokens, 100)
    }

    func testReplayWithRewrittenTimestampsRetainsOriginalDayAndOnlyAddsNewTail() throws {
        let original = try parse(rollout(id: "same", day: "2026-08-31", values: [100, 300]))
        let replay = try parse(rollout(id: "same", values: [100, 300, 400]))
        for files in [[original, replay], [replay, original]] {
            let totals = CodexSessionCache.mergedTokensByDayAndModel(from: files)
            XCTAssertEqual(totals["2026-08-31"]?["gpt-5.4"]?.inputTokens, 300)
            XCTAssertEqual(totals["2026-09-01"]?["gpt-5.4"]?.inputTokens, 100)
        }
    }

    func testIndependentTurnsWithIdenticalCountersAreNotDeduplicated() throws {
        let one = try parse(rollout(id: "one", values: [100], times: [0]))
        let two = try parse(rollout(id: "two", values: [100], times: [2]))
        let totals = CodexSessionCache.mergedTokensByDayAndModel(from: [one, two])
        XCTAssertEqual(totals["2026-09-01"]?["gpt-5.4"]?.inputTokens, 200)
    }

    @MainActor
    func testScopeChangeClearsOldTotalsAndStandaloneRefreshNotifiesWidget() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CodexScope-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: home)
            defaults.removePersistentDomain(forName: suite)
        }
        let profiles = CodexDesktopProfiles(userHome: home, defaults: defaults)
        let sessions = profiles.defaultProfile.home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try rollout(id: "one", values: [100]).write(to: sessions.appendingPathComponent("rollout-one.jsonl"), atomically: true, encoding: .utf8)
        let state = CodexState(defaults: defaults, profiles: profiles)
        var notifications = 0
        state.didRefresh = { notifications += 1 }
        await state.refreshCostAndActivity()
        XCTAssertGreaterThan(state.cost.totalCost, 0)
        XCTAssertEqual(notifications, 1)
        state.statisticsScope = .currentAccount
        XCTAssertTrue(state.cost.daily.isEmpty)
        await state.refreshCostAndActivity()
        XCTAssertEqual(notifications, 2)
    }

    func testArchivesSurviveMoveAndCodexDisplayDoesNotDoubleCountCache() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent("sessions")
        let archive = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-example.jsonl")
        try rollout(id: "one", values: [100, 300]).write(to: file, atomically: true, encoding: .utf8)
        let cache = CodexSessionCache(sessionsRoot: sessions.path, cacheURL: home.appendingPathComponent("cache.json"))
        await cache.refreshFromFilesystem()
        let before = await cache.costSeries()
        XCTAssertEqual(before.daily.first?.totalTokens, 300)
        XCTAssertEqual(before.daily.first?.inputTokens, 150)
        XCTAssertEqual(before.daily.first?.cacheReadTokens, 150)
        XCTAssertGreaterThan(before.totalCost, 0)
        try FileManager.default.moveItem(at: file, to: archive.appendingPathComponent(file.lastPathComponent))
        await cache.refreshFromFilesystem()
        let after = await cache.costSeries()
        XCTAssertEqual(after.daily.first?.totalTokens, 300)
        XCTAssertEqual(after.totalCost, before.totalCost)
    }

    func testMultipleProfilesIncludeOlderDaysAndDeduplicateCopiedRollouts() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let roots = [home.appendingPathComponent("one"), home.appendingPathComponent("two")]
        for root in roots { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        for root in roots {
            try rollout(id: "old", day: "2026-01-21", values: [100, 300])
                .write(to: root.appendingPathComponent("rollout-old.jsonl"), atomically: true, encoding: .utf8)
        }
        try rollout(id: "new", values: [200, 600])
            .write(to: roots[1].appendingPathComponent("rollout-new.jsonl"), atomically: true, encoding: .utf8)
        let cache = CodexSessionCache(sessionRoots: roots.map(\.path), cacheURL: home.appendingPathComponent("cache.json"))
        await cache.refreshFromFilesystem()
        let series = await cache.costSeries()
        XCTAssertEqual(series.daily.map(\.date), ["2026-09-01", "2026-01-21"])
        XCTAssertEqual(series.daily.map(\.totalTokens), [600, 300])
        let restored = CodexSessionCache(sessionRoots: roots.map(\.path), cacheURL: home.appendingPathComponent("cache.json"))
        let restoredSeries = await restored.costSeries()
        XCTAssertEqual(restoredSeries.daily.map(\.totalTokens), [600, 300])
    }

    func testUnpricedModelKeepsTokensAndReportsIncompleteCost() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try rollout(id: "unknown", values: [100]).replacingOccurrences(of: "gpt-5.4", with: "unpriced-model")
            .write(to: home.appendingPathComponent("rollout-unknown.jsonl"), atomically: true, encoding: .utf8)
        let cache = CodexSessionCache(sessionRoots: [home.path], cacheURL: home.appendingPathComponent("cache.json"))
        await cache.refreshFromFilesystem()
        let series = await cache.costSeries()
        XCTAssertEqual(series.daily.first?.totalTokens, 100)
        XCTAssertEqual(series.unpricedModels, ["unpriced-model"])
    }

    func testMissingServiceTierMarksEstimateIncomplete() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try rollout(id: "unknown-tier", values: [100])
            .write(to: home.appendingPathComponent("rollout-unknown-tier.jsonl"), atomically: true, encoding: .utf8)
        let cache = CodexSessionCache(sessionRoots: [home.path], cacheURL: home.appendingPathComponent("cache.json"))
        await cache.refreshFromFilesystem()
        let series = await cache.costSeries()
        XCTAssertTrue(series.hasUnknownServiceTiers)
        XCTAssertEqual(series.daily.first?.totalTokens, 100)
    }

    @MainActor
    func testLiveHistoryAuditWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CCSWITCHER_VERIFY_CODEX_HISTORY"] == "1" else {
            throw XCTSkip("Opt-in read-only audit of local Codex logs")
        }
        let roots = CodexDesktopProfiles().statisticsHomes.flatMap {
            [$0.appendingPathComponent("sessions").path, $0.appendingPathComponent("archived_sessions").path]
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cacheURL = ProcessInfo.processInfo.environment["CCSWITCHER_AUDIT_CACHE_PATH"]
            .map { URL(fileURLWithPath: $0) } ?? folder.appendingPathComponent("audit.json")
        let cache = CodexSessionCache(sessionRoots: roots, cacheURL: cacheURL)
        await cache.refreshFromFilesystem()
        let series = await cache.costSeries()
        print("CODEX_AUDIT days=\(series.daily.count) oldest=\(series.daily.last?.date ?? "none") tokens=\(series.daily.reduce(0) { $0 + $1.totalTokens }) estimate=\(series.totalCost) unpriced=\(series.unpricedModels)")
        for day in series.daily.prefix(5) {
            print("CODEX_AUDIT day=\(day.date) tokens=\(day.totalTokens) estimate=\(day.cost)")
        }
        XCTAssertGreaterThan(series.daily.count, 1)
        XCTAssertGreaterThan(series.totalCost, 0)
    }

    @MainActor
    func testStatisticsScopeDefaultsToAllProfilesAndPersistsSelection() throws {
        let name = "CodexAccounting-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = CodexState(defaults: defaults)
        XCTAssertEqual(state.statisticsScope, .allProfiles)
        state.statisticsScope = .currentAccount
        XCTAssertEqual(CodexState(defaults: defaults).statisticsScope, .currentAccount)
    }

    @MainActor
    func testAllHomesIncludeRetainedProfilesWithoutCopyingCredentials() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let profiles = CodexDesktopProfiles(userHome: home)
        let extra = profiles.profile(for: UUID())
        try FileManager.default.createDirectory(at: extra.home, withIntermediateDirectories: true)
        XCTAssertEqual(Set(profiles.statisticsHomes.map { $0.resolvingSymlinksInPath().path }),
                       Set([profiles.defaultProfile.home, extra.home].map { $0.resolvingSymlinksInPath().path }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extra.authURL.path))
    }
}
