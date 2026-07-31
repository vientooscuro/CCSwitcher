import XCTest
@testable import CCSwitcher

final class UsageWindowModelTests: XCTestCase {
    func testFiveHourWindowClassifiesAsSession() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 5 * 3600), .session)
    }

    func testThreeHundredMinuteCodexWindowClassifiesAsSession() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 300 * 60), .session)
    }

    func testSevenDayWindowClassifiesAsWeekly() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 604_800), .weekly)
    }

    func testTenThousandEightyMinuteCodexWindowClassifiesAsWeekly() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 10_080 * 60), .weekly)
    }

    func testMonthlyWindowClassifiesAsOther() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 30 * 86_400), .other(seconds: 30 * 86_400))
    }

    func testBoundaryAtSixHoursIsSession() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 6 * 3600), .session)
    }

    func testJustOverSixHoursIsWeekly() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 6 * 3600 + 1), .weekly)
    }

    func testElapsedPercentIsHalfwayThroughWindow() {
        let window = UsageWindowModel(
            kind: .session,
            utilization: 10,
            resetsAt: Date().addingTimeInterval(2.5 * 3600),
            windowSeconds: 5 * 3600
        )
        let elapsed = window.elapsedPercent
        XCTAssertNotNil(elapsed)
        XCTAssertEqual(elapsed!, 50, accuracy: 1)
    }

    func testElapsedPercentIsNilWithoutResetDate() {
        let window = UsageWindowModel(kind: .weekly, utilization: 10, resetsAt: nil, windowSeconds: 604_800)
        XCTAssertNil(window.elapsedPercent)
    }

    func testElapsedPercentClampsWhenResetIsInThePast() {
        let window = UsageWindowModel(
            kind: .session,
            utilization: 10,
            resetsAt: Date().addingTimeInterval(-3600),
            windowSeconds: 5 * 3600
        )
        XCTAssertEqual(window.elapsedPercent!, 100, accuracy: 0.001)
    }

    func testResetTextUsesMinutesUnderAnHour() {
        let text = UsageWindowFormat.resetText(until: Date().addingTimeInterval(25 * 60))
        XCTAssertEqual(text, "25 min")
    }

    func testResetTextUsesHoursAndMinutes() {
        let text = UsageWindowFormat.resetText(until: Date().addingTimeInterval(2 * 3600 + 14 * 60))
        XCTAssertEqual(text, "2 hr 14 min")
    }

    func testResetTextIsNowWhenElapsed() {
        XCTAssertEqual(UsageWindowFormat.resetText(until: Date().addingTimeInterval(-5)), "now")
    }

    func testCompactResetTextUsesDaysAndHours() {
        let text = UsageWindowFormat.compactResetText(until: Date().addingTimeInterval(4 * 86_400 + 6 * 3600))
        XCTAssertEqual(text, "4d 6h")
    }

    func testDurationTextForNonStandardWindow() {
        XCTAssertEqual(UsageWindowFormat.durationText(seconds: 30 * 86_400), "30d")
        XCTAssertEqual(UsageWindowFormat.durationText(seconds: 3 * 3600), "3h")
    }
}
