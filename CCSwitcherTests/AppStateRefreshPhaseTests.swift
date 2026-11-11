import XCTest
@testable import CCSwitcher

@MainActor
final class AppStateRefreshPhaseTests: XCTestCase {
    func testStatisticsPhaseUnblocksAccountActionsUntilStatisticsFinish() {
        let state = AppState()
        state.isLoading = true

        let generation = state.beginStatisticsRefresh(force: true)

        XCTAssertNotNil(generation)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.isStatisticsLoading)

        state.finishStatisticsRefresh(generation: try! XCTUnwrap(generation))
        XCTAssertFalse(state.isStatisticsLoading)
    }

    func testAutomaticRefreshBuildsMissingStatisticsSnapshot() {
        let state = AppState()
        state.isLoading = true

        let generation = state.beginStatisticsRefresh(force: false)

        XCTAssertNotNil(generation)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.isStatisticsLoading)
        state.finishStatisticsRefresh(generation: try! XCTUnwrap(generation))
    }

    func testClaudeStatisticsRefreshExpiresAndForceBypassesInterval() throws {
        let state = AppState()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try XCTUnwrap(state.beginStatisticsRefresh(force: false, now: start))
        state.finishStatisticsRefresh(generation: first, snapshotAt: start)

        XCTAssertNil(state.beginStatisticsRefresh(force: false, now: start.addingTimeInterval(59)))
        let forced = try XCTUnwrap(state.beginStatisticsRefresh(force: true, now: start.addingTimeInterval(59)))
        state.finishStatisticsRefresh(generation: forced, snapshotAt: start.addingTimeInterval(59))
        XCTAssertNotNil(state.beginStatisticsRefresh(force: false, now: start.addingTimeInterval(119)))
    }

    func testClaudeStatisticsRefreshExpiresAtDayBoundary() throws {
        let state = AppState()
        let day = Calendar.current.startOfDay(for: Date())
        let previousDay = day.addingTimeInterval(-1)
        let first = try XCTUnwrap(state.beginStatisticsRefresh(force: false, now: previousDay))
        state.finishStatisticsRefresh(generation: first, snapshotAt: previousDay)

        XCTAssertNotNil(state.beginStatisticsRefresh(force: false, now: day))
    }

    func testCodexStatisticsRefreshExpiresAndScopeInvalidatesSnapshot() throws {
        let suite = "CodexStatisticsFreshnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = CodexState(defaults: defaults, loadWidgetData: { _ in nil })
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try XCTUnwrap(state.beginStatisticsRefreshIfIdle())
        state.finishStatisticsRefresh(generation: first, snapshotAt: start)

        XCTAssertFalse(state.shouldRefreshStatistics(force: false, now: start.addingTimeInterval(59)))
        XCTAssertTrue(state.shouldRefreshStatistics(force: true, now: start.addingTimeInterval(59)))
        XCTAssertTrue(state.shouldRefreshStatistics(force: false, now: start.addingTimeInterval(60)))
        state.statisticsScope = .currentAccount
        XCTAssertTrue(state.needsInitialStatisticsRefresh)
        XCTAssertTrue(state.shouldRefreshStatistics(force: false, now: start.addingTimeInterval(1)))
    }

    func testCodexStatisticsRefreshExpiresAtDayBoundary() throws {
        let suite = "CodexStatisticsDayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = CodexState(defaults: defaults, loadWidgetData: { _ in nil })
        let day = Calendar.current.startOfDay(for: Date())
        let first = try XCTUnwrap(state.beginStatisticsRefreshIfIdle())
        state.finishStatisticsRefresh(generation: first, snapshotAt: day.addingTimeInterval(-1))

        XCTAssertTrue(state.shouldRefreshStatistics(force: false, now: day))
    }

    func testCodexDiscardedScopeRefreshCannotReplaceCurrentSnapshot() throws {
        let suite = "CodexStatisticsScopeRaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = CodexState(defaults: defaults, loadWidgetData: { _ in nil })
        let stale = try XCTUnwrap(state.beginStatisticsRefreshIfIdle())
        state.statisticsScope = .currentAccount
        let current = try XCTUnwrap(state.beginStatisticsRefreshIfIdle())

        state.finishStatisticsRefresh(generation: stale, snapshotAt: Date())
        XCTAssertTrue(state.isStatisticsLoading)
        XCTAssertFalse(state.hasStatisticsSnapshot)
        state.finishStatisticsRefresh(generation: current, snapshotAt: Date())
        XCTAssertTrue(state.hasStatisticsSnapshot)
        XCTAssertFalse(state.isStatisticsLoading)
    }

    func testCodexStatisticsPhaseRejectsOverlappingRefreshes() {
        let suite = "CodexStatisticsPhaseTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = CodexState(defaults: defaults)

        let first = state.beginStatisticsRefreshIfIdle()
        let overlapping = state.beginStatisticsRefreshIfIdle()

        XCTAssertNotNil(first)
        XCTAssertNil(overlapping)
        state.finishStatisticsRefresh(generation: try! XCTUnwrap(first))
        XCTAssertFalse(state.isStatisticsLoading)
    }

    func testCodexDoesNotAttributeUnscopedWidgetSnapshotToSelectedScope() {
        let suite = "CodexStatisticsRestoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = WidgetData(
            accounts: [], todayCost: 7.5, conversationTurns: 12, activeCodingTime: "45m",
            linesWritten: 34, modelUsage: ["gpt-6-astra": 56], lastUpdated: Date(), provider: "Codex"
        )

        let state = CodexState(defaults: defaults, loadWidgetData: { provider in
            provider == "Codex" ? snapshot : nil
        })

        XCTAssertEqual(state.cost.todayCost, 0)
        XCTAssertEqual(state.activity.turns, 0)
        XCTAssertNil(state.activity.linesWritten)
        XCTAssertFalse(state.hasStatisticsSnapshot)
        XCTAssertTrue(state.needsInitialStatisticsRefresh)
    }

    func testCodexRequestsOneInitialStatisticsRefreshWithoutSnapshot() {
        let suite = "CodexStatisticsMissingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = CodexState(defaults: defaults, loadWidgetData: { _ in nil })

        XCTAssertTrue(state.needsInitialStatisticsRefresh)
    }

    func testProcessWaiterTerminatesHungCommandAtDeadline() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        let start = Date()

        let completed = ProcessWaiter.waitUntilExit(process, timeout: 0.05)

        XCTAssertFalse(completed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(process.isRunning)
    }

    func testProcessWaiterDrainsCapturedOutputBeforeProcessExit() throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "dd if=/dev/zero bs=1024 count=128 2>/dev/null"]
        process.standardOutput = pipe
        try process.run()

        let result = ProcessWaiter.waitUntilExit(process, capturing: pipe, timeout: 1)

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.output.count, 128 * 1024)
    }

    func testActiveTokenRefreshUsesNonInteractiveEmptyPrintTrigger() {
        XCTAssertEqual(ClaudeService.activeTokenRefreshArguments, ["-p", ""])
    }

    func testPeriodicClaudeRefreshDoesNotOverlapInFlightRefresh() {
        let state = AppState()
        let first = state.beginAccountRefresh(force: false)
        let overlapping = state.beginAccountRefresh(force: false)

        XCTAssertNotNil(first)
        XCTAssertNil(overlapping)
        state.finishAccountRefresh(generation: try! XCTUnwrap(first))
        XCTAssertFalse(state.isLoading)
    }

    func testForcedClaudeRefreshSupersedesInFlightRefresh() {
        let state = AppState()
        let first = state.beginAccountRefresh(force: false)
        let forced = state.beginAccountRefresh(force: true)

        XCTAssertNotNil(first)
        XCTAssertNotNil(forced)
        state.finishAccountRefresh(generation: try! XCTUnwrap(first))
        XCTAssertTrue(state.isLoading)
        state.finishAccountRefresh(generation: try! XCTUnwrap(forced))
        XCTAssertFalse(state.isLoading)
    }

    func testVerifiedAccountSwitchRefreshSupersedesSwitchLoadingState() {
        let state = AppState()
        state.isLoading = true

        let generation = state.beginAccountRefresh(force: false, hasKnownStatus: true)

        XCTAssertNotNil(generation)
        state.finishAccountRefresh(generation: try! XCTUnwrap(generation))
        XCTAssertFalse(state.isLoading)
    }

    func testActivityDurationRestoresMinutesFromWidgetText() {
        XCTAssertEqual(ActivityStats.minutes(from: "48h 16m"), 2_896)
        XCTAssertEqual(ActivityStats.minutes(from: "45m"), 45)
        XCTAssertEqual(ActivityStats.minutes(from: "2h"), 120)
    }
}
