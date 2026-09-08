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
}
