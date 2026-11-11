import XCTest
@testable import CCSwitcher

/// Pins the two pure decisions inside `CodexState` that do not require a
/// running actor, the Keychain, or the filesystem: the duplicate-email guard
/// on import, and the fingerprint-mismatch decision behind the desync guard.
@MainActor
final class CodexStateTests: XCTestCase {

    func testDesktopAccountsCanBeAddedWithoutReplacingDefaultCredentials() {
        XCTAssertTrue(CodexState().capabilities.canLoginNewAccount)
    }

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
    func testSnapshotsRestoreForExactScopeAndSurviveRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let suite = "CodexStateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = CodexDesktopProfiles(userHome: root, defaults: defaults)
        let state = CodexState(defaults: defaults, profiles: profiles, loadWidgetData: { _ in nil })
        await state.refreshCostAndActivity()
        while state.isStatisticsLoading { await Task.yield() }
        XCTAssertEqual(state.statisticsCompleteness, .complete)
        state.statisticsScope = .currentAccount
        XCTAssertEqual(state.statisticsCompleteness, .loading)
        XCTAssertFalse(state.hasStatisticsSnapshot)
        await state.refreshCostAndActivity()
        while state.isStatisticsLoading { await Task.yield() }
        state.statisticsScope = .allProfiles
        XCTAssertEqual(state.statisticsCompleteness, .verifying)
        XCTAssertTrue(state.hasStatisticsSnapshot)
        XCTAssertTrue(state.needsInitialStatisticsRefresh)
        let restored = CodexState(defaults: defaults, profiles: profiles, loadWidgetData: { _ in nil })
        XCTAssertEqual(restored.statisticsCompleteness, .verifying)
        XCTAssertTrue(restored.hasStatisticsSnapshot)
        let other = CodexState(defaults: defaults,
            profiles: CodexDesktopProfiles(userHome: root.appendingPathComponent("other"), defaults: defaults),
            loadWidgetData: { _ in nil })
        XCTAssertEqual(other.statisticsCompleteness, .loading)
        XCTAssertFalse(other.hasStatisticsSnapshot)
    }

    func testPartialSnapshotSurvivesSwitchAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let suite = "CodexStatePartialTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = CodexDesktopProfiles(userHome: root, defaults: defaults)
        let state = CodexState(defaults: defaults, profiles: profiles, loadWidgetData: { _ in nil })
        await state.refreshCostAndActivity()
        XCTAssertEqual(state.statisticsCompleteness, .partial)
        state.statisticsScope = .currentAccount
        XCTAssertFalse(state.hasStatisticsSnapshot)
        state.statisticsScope = .allProfiles
        XCTAssertTrue(state.hasStatisticsSnapshot)
        XCTAssertEqual(state.statisticsCompleteness, .partial)
        let restored = CodexState(defaults: defaults, profiles: profiles, loadWidgetData: { _ in nil })
        XCTAssertTrue(restored.hasStatisticsSnapshot)
        XCTAssertEqual(restored.statisticsCompleteness, .partial)
        XCTAssertTrue(restored.needsInitialStatisticsRefresh)
    }

}
