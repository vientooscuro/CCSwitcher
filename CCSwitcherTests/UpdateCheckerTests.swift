import XCTest
@testable import CCSwitcher

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testManualCheckRespectsUpdaterAvailability() {
        let driver = FakeUpdateDriver()
        let checker = UpdateChecker(driver: driver)

        checker.checkForUpdates()
        XCTAssertEqual(driver.checkCount, 0)

        driver.canCheckForUpdates = true
        driver.onStateChange?()
        XCTAssertTrue(checker.canCheckForUpdates)
        checker.checkForUpdates()
        XCTAssertEqual(driver.checkCount, 1)

        driver.canCheckForUpdates = false
        checker.checkForUpdates()
        XCTAssertEqual(driver.checkCount, 1)
    }

    func testAutomaticChecksReflectAndUpdateDriverPreference() {
        let driver = FakeUpdateDriver()
        let checker = UpdateChecker(driver: driver)
        XCTAssertFalse(checker.automaticallyChecksForUpdates)

        checker.setAutomaticallyChecksForUpdates(true)
        XCTAssertTrue(driver.automaticallyChecksForUpdates)
        XCTAssertTrue(checker.automaticallyChecksForUpdates)

        driver.automaticallyChecksForUpdates = false
        driver.onStateChange?()
        XCTAssertFalse(checker.automaticallyChecksForUpdates)
    }
}

@MainActor
private final class FakeUpdateDriver: UpdateDriving {
    var canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    var onStateChange: (() -> Void)?
    private(set) var checkCount = 0

    func checkForUpdates() { checkCount += 1 }
}
