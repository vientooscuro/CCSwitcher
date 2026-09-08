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

    func testAutomaticRefreshSkipsHeavyStatisticsPhase() {
        let state = AppState()
        state.isLoading = true

        let generation = state.beginStatisticsRefresh(force: false)

        XCTAssertNil(generation)
        XCTAssertFalse(state.isLoading)
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

    func testCodexRestoresItsOwnStatisticsSnapshot() {
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

        XCTAssertEqual(state.cost.todayCost, 7.5)
        XCTAssertEqual(state.activity.turns, 12)
        XCTAssertEqual(state.activity.linesWritten, 34)
        XCTAssertFalse(state.needsInitialStatisticsRefresh)
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

    func testActivityDurationRestoresMinutesFromWidgetText() {
        XCTAssertEqual(ActivityStats.minutes(from: "48h 16m"), 2_896)
        XCTAssertEqual(ActivityStats.minutes(from: "45m"), 45)
        XCTAssertEqual(ActivityStats.minutes(from: "2h"), 120)
    }
}
