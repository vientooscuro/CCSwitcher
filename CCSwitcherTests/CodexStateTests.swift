import XCTest
@testable import CCSwitcher

/// Pins the two pure decisions inside `CodexState` that do not require a
/// running actor, the Keychain, or the filesystem: the duplicate-email guard
/// on import, and the fingerprint-mismatch decision behind the desync guard.
@MainActor
final class CodexStateTests: XCTestCase {

    private func account(_ email: String) -> Account {
        Account(email: email, displayName: email, provider: .codex)
    }

    // MARK: - wouldDuplicate

    func testWouldDuplicateIsTrueForExistingEmail() {
        XCTAssertTrue(CodexState.wouldDuplicate(email: "a@b.c", in: [account("a@b.c")]))
    }

    func testWouldDuplicateIsFalseForNewEmail() {
        XCTAssertFalse(CodexState.wouldDuplicate(email: "new@b.c", in: [account("a@b.c")]))
    }

    func testWouldDuplicateIsFalseForEmptyAccounts() {
        XCTAssertFalse(CodexState.wouldDuplicate(email: "a@b.c", in: []))
    }

    // MARK: - desyncDecision

    func testDesyncDecisionMatchesWhenLiveFingerprintEqualsActiveAccountBackup() {
        let activeId = UUID()
        let decision = CodexState.desyncDecision(
            liveFingerprint: "acct-1|a@b.c",
            activeAccountId: activeId,
            knownFingerprints: [activeId: "acct-1|a@b.c"]
        )
        XCTAssertEqual(decision, .matches)
    }

    func testDesyncDecisionAdoptsAKnownOtherAccount() {
        let activeId = UUID()
        let otherId = UUID()
        let decision = CodexState.desyncDecision(
            liveFingerprint: "acct-2|d@e.f",
            activeAccountId: activeId,
            knownFingerprints: [activeId: "acct-1|a@b.c", otherId: "acct-2|d@e.f"]
        )
        XCTAssertEqual(decision, .adopt(otherId))
    }

    func testDesyncDecisionIsUnknownWhenNoBackupMatches() {
        let activeId = UUID()
        let decision = CodexState.desyncDecision(
            liveFingerprint: "acct-3|nobody@x.y",
            activeAccountId: activeId,
            knownFingerprints: [activeId: "acct-1|a@b.c"]
        )
        XCTAssertEqual(decision, .unknown)
    }

    func testDesyncDecisionIsUnknownWhenActiveAccountHasNoBackup() {
        let activeId = UUID()
        let decision = CodexState.desyncDecision(
            liveFingerprint: "acct-1|a@b.c",
            activeAccountId: activeId,
            knownFingerprints: [:]
        )
        XCTAssertEqual(decision, .unknown)
    }
}
