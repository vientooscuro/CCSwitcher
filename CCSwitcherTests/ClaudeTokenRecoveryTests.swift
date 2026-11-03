import XCTest
@testable import CCSwitcher

final class ClaudeTokenRecoveryTests: XCTestCase {
    private func token(sub: String, expiresAt: Double? = nil, refresh: String = "rt") -> String {
        let exp = expiresAt.map { ",\"expiresAt\":\($0)" } ?? ""
        return "{\"claudeAiOauth\":{\"accessToken\":\"at\",\"refreshToken\":\"\(refresh)\",\"subscriptionType\":\"\(sub)\"\(exp)}}"
    }

    // MARK: - Salvage target

    func testForeignLiveTokenIsSavedToTheAccountWithTheMatchingPlan() {
        let target = ClaudeService.salvageTargetId(
            liveToken: token(sub: "team", expiresAt: 2_000),
            restoringToken: token(sub: "max"),
            otherBackups: [(id: "team-account", token: token(sub: "team", expiresAt: 1_000))]
        )
        XCTAssertEqual(target, "team-account")
    }

    func testLiveTokenOfTheRestoredAccountIsNotSalvaged() {
        let target = ClaudeService.salvageTargetId(
            liveToken: token(sub: "max"),
            restoringToken: token(sub: "max"),
            otherBackups: [(id: "other", token: token(sub: "team"))]
        )
        XCTAssertNil(target)
    }

    func testAmbiguousPlanIsNotSalvaged() {
        let target = ClaudeService.salvageTargetId(
            liveToken: token(sub: "team"),
            restoringToken: token(sub: "max"),
            otherBackups: [(id: "a", token: token(sub: "team")), (id: "b", token: token(sub: "team"))]
        )
        XCTAssertNil(target)
    }

    func testOlderLiveTokenDoesNotReplaceANewerBackup() {
        let target = ClaudeService.salvageTargetId(
            liveToken: token(sub: "team", expiresAt: 1_000),
            restoringToken: token(sub: "max"),
            otherBackups: [(id: "team-account", token: token(sub: "team", expiresAt: 2_000))]
        )
        XCTAssertNil(target)
    }

    // MARK: - Backup store loading

    func testValidStoreIsLoaded() {
        let raw = #"{"account-id":{"token":"t","oauthAccount":{"emailAddress":"a@b.c"}}}"#
        guard case .loaded(let store) = KeychainService.parseBackupStore(.value(raw)) else {
            return XCTFail("expected a loaded store")
        }
        XCTAssertEqual(store["account-id"]?.token, "t")
    }

    func testOnlyAMissingItemMeansThereAreNoBackups() {
        guard case .absent = KeychainService.parseBackupStore(.notFound) else {
            return XCTFail("expected absent")
        }
    }

    func testReadFailureIsNotTreatedAsAnEmptyStore() {
        guard case .failed = KeychainService.parseBackupStore(.failed) else {
            return XCTFail("a timed-out read must not look like an empty store")
        }
    }

    func testUndecodableStoreIsNotTreatedAsAnEmptyStore() {
        guard case .failed = KeychainService.parseBackupStore(.value("not json")) else {
            return XCTFail("an unreadable item must not be overwritten as if it were empty")
        }
    }

    // MARK: - Refresh error classification

    func testOnlyInvalidGrantMeansTheTokenIsDead() {
        let invalidGrant = Data(#"{"error":"invalid_grant","error_description":"Refresh token not found or invalid"}"#.utf8)
        XCTAssertTrue(ClaudeService.isInvalidGrant(status: 400, body: invalidGrant))
        XCTAssertFalse(ClaudeService.isInvalidGrant(status: 429, body: Data(#"{"error":"rate_limited"}"#.utf8)))
        XCTAssertFalse(ClaudeService.isInvalidGrant(status: 403, body: Data("<html>blocked</html>".utf8)))
        XCTAssertFalse(ClaudeService.isInvalidGrant(status: 500, body: invalidGrant))
    }
}
