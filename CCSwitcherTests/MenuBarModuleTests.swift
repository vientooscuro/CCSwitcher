import XCTest
@testable import CCSwitcher

final class MenuBarModuleTests: XCTestCase {

    // MARK: - Label derivation

    func testSessionWindowLabelsAsHours() {
        let window = UsageWindowModel(kind: .session, utilization: 5, resetsAt: nil, windowSeconds: 5 * 3600)
        XCTAssertEqual(MenuBarModule.compactLabel(for: window), "5H")
    }

    func testThreeHundredMinuteWindowAlsoLabelsAsFiveHours() {
        let window = UsageWindowModel(kind: .session, utilization: 5, resetsAt: nil, windowSeconds: 300 * 60)
        XCTAssertEqual(MenuBarModule.compactLabel(for: window), "5H")
    }

    func testWeeklyWindowLabelsAsDays() {
        let window = UsageWindowModel(kind: .weekly, utilization: 5, resetsAt: nil, windowSeconds: 604_800)
        XCTAssertEqual(MenuBarModule.compactLabel(for: window), "7D")
    }

    func testNonStandardWindowLabelsFromItsLength() {
        let window = UsageWindowModel(kind: .other(seconds: 30 * 86_400), utilization: 5,
                                      resetsAt: nil, windowSeconds: 30 * 86_400)
        XCTAssertEqual(MenuBarModule.compactLabel(for: window), "30D")
    }

    /// A three-hour session window must not be mislabelled "5H".
    func testThreeHourWindowLabelsAsThreeHours() {
        let window = UsageWindowModel(kind: .session, utilization: 5, resetsAt: nil, windowSeconds: 3 * 3600)
        XCTAssertEqual(MenuBarModule.compactLabel(for: window), "3H")
    }

    // MARK: - Per-provider storage

    func testClaudeKeepsTheLegacyKey() {
        XCTAssertEqual(MenuBarModuleStore.storageKey(for: .claudeCode), "menuBarModules")
    }

    func testCodexUsesItsOwnKey() {
        XCTAssertEqual(MenuBarModuleStore.storageKey(for: .codex), "menuBarModules.codex")
    }

    func testEachProviderGetsADistinctKey() {
        let keys = Set(AIProviderType.allCases.map(MenuBarModuleStore.storageKey(for:)))
        XCTAssertEqual(keys.count, AIProviderType.allCases.count)
    }

    // MARK: - Resilient decoding, unchanged behaviour

    func testUnknownRawValuesAreDroppedNotFatal() throws {
        let data = try JSONEncoder().encode(["account", "notAModule", "weeklyBar"])
        XCTAssertEqual(MenuBarModuleStore.decode(data), [.account, .weeklyBar])
    }

    func testScopedLimitBarDecodes() throws {
        let data = try JSONEncoder().encode(["scopedLimitBar"])
        XCTAssertEqual(MenuBarModuleStore.decode(data), [.scopedLimitBar])
    }

    func testEveryCaseHasADisplayName() {
        for module in MenuBarModule.allCases {
            XCTAssertFalse(module.localizedDisplayName.isEmpty, "\(module) has no display name")
        }
    }
}
