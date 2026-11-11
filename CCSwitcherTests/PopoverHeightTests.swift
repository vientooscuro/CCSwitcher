import XCTest
@testable import CCSwitcher

@MainActor
final class PopoverHeightTests: XCTestCase {
    func testCostsUseAvailableScreenHeightInsteadOfUsageHeight() {
        XCTAssertEqual(MainMenuView.popoverHeight(tab: .costs, screenHeight: 1200, chromeHeight: 180, usageHeight: 420), 720)
        XCTAssertEqual(MainMenuView.popoverHeight(tab: .costs, screenHeight: 700, chromeHeight: 180, usageHeight: 420), 420)
    }

    func testOtherTabsKeepMeasuredHeightAndScreenCap() {
        XCTAssertEqual(MainMenuView.popoverHeight(tab: .usage, screenHeight: 1200, chromeHeight: 180, usageHeight: 420), 601)
        XCTAssertEqual(MainMenuView.popoverHeight(tab: .accounts, screenHeight: 700, chromeHeight: 180, usageHeight: 900), 600)
    }
}
