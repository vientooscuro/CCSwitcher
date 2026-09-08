import XCTest
@testable import CCSwitcher

@MainActor
final class CodexDesktopProfilesTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var profiles: CodexDesktopProfiles!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "CodexProfilesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        profiles = CodexDesktopProfiles(userHome: root, defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testPreparingSecondAccountDoesNotSeedOrReplaceCredentials() throws {
        let first = UUID(), second = UUID()
        profiles.bindDefault(to: first)
        let primary = profiles.profile(for: first)
        try FileManager.default.createDirectory(at: primary.home, withIntermediateDirectories: true)
        try Data("primary-session-sentinel".utf8).write(to: primary.authURL)

        let isolated = profiles.profile(for: second)
        try profiles.prepare(isolated)

        XCTAssertEqual(try String(contentsOf: primary.authURL, encoding: .utf8), "primary-session-sentinel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolated.authURL.path))
        XCTAssertNotEqual(primary.home, isolated.home)
        XCTAssertNotEqual(primary.userData, isolated.userData)
        XCTAssertEqual(profiles.profile(for: second), isolated)
        XCTAssertTrue(try String(contentsOf: isolated.home.appendingPathComponent("config.toml"), encoding: .utf8)
            .contains("cli_auth_credentials_store = \"file\""))
        let permissions = try FileManager.default.attributesOfItem(atPath: isolated.home.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
    }

    func testDefaultBindingSurvivesRelaunchAndCannotBeReassigned() {
        let first = UUID()
        profiles.bindDefault(to: first)
        profiles.bindDefault(to: UUID())
        let reloaded = CodexDesktopProfiles(userHome: root, defaults: defaults)
        XCTAssertTrue(reloaded.profile(for: first).isDefault)
        XCTAssertEqual(reloaded.profile(for: first).home.path, root.appendingPathComponent(".codex").path)
    }

    func testLaunchEnvironmentDoesNotInheritAgentControlOrAPIKeys() {
        let profile = profiles.profile(for: UUID())
        let environment = profile.environment(inheriting: [
            "PATH": "/usr/bin", "HOME": root.path,
            "CODEX_HOME": "/wrong", "CODEX_THREAD_ID": "parent",
            "OPENAI_API_KEY": "test-only", "CODEX_ELECTRON_USER_DATA_PATH": "/wrong"
        ])
        XCTAssertEqual(environment["CODEX_HOME"], profile.home.path)
        XCTAssertEqual(environment["CODEX_ELECTRON_USER_DATA_PATH"], profile.userData.path)
        XCTAssertNil(environment["CODEX_THREAD_ID"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertEqual(environment["HOME"], root.path)
        XCTAssertEqual(profile.launchArguments, ["--user-data-dir=\(profile.userData.path)"])
    }

    func testPrepareNeverOverwritesRefreshedAuthOrExistingConfig() throws {
        let profile = profiles.profile(for: UUID())
        try profiles.prepare(profile)
        try Data("rotated-session-sentinel".utf8).write(to: profile.authURL)
        let config = profile.home.appendingPathComponent("config.toml")
        let original = try Data(contentsOf: config)
        try profiles.prepare(profile)
        XCTAssertEqual(try String(contentsOf: profile.authURL, encoding: .utf8), "rotated-session-sentinel")
        XCTAssertEqual(try Data(contentsOf: config), original)
    }

    func testPrepareRejectsSymlinkedHome() throws {
        let profile = profiles.profile(for: UUID())
        try FileManager.default.createDirectory(at: profile.home.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: profile.home, withDestinationURL: root)
        XCTAssertThrowsError(try profiles.prepare(profile))
    }

    private func writeAuth(email: String, to url: URL) throws {
        let payload = try JSONSerialization.data(withJSONObject: ["email": email]).base64EncodedString()
        let json: [String: Any] = ["auth_mode": "chatgpt", "tokens": [
            "id_token": "header.\(payload).signature", "access_token": "test-only", "account_id": email
        ]]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    func testRefreshReportsMissingCredentialsForInactiveAccount() async {
        let first = Account(email: "first@example.com", displayName: "First", provider: .codex, isActive: true)
        let second = Account(email: "second@example.com", displayName: "Second", provider: .codex)
        CodexAccountRegistry.save([first, second], to: defaults)
        let state = CodexState(defaults: defaults, profiles: profiles, openDesktop: { _ in
            XCTFail("Refreshing limits must not open or switch a desktop profile")
        })

        await state.refresh(force: true)

        XCTAssertNotNil(state.accountCards.first { $0.id == second.id }?.error)
        XCTAssertEqual(state.accounts.first(where: \.isActive)?.id, first.id)
    }

    private func usage(_ percent: Double, plan: String = "pro") -> CodexUsageService.Result {
        let snapshot = CodexRateLimitSnapshot(
            windows: [.init(usedPercent: percent, windowSeconds: 604800, resetAt: nil)],
            scoped: [], planType: plan, creditsBalance: nil, hasCredits: false,
            unlimitedCredits: false, reachedType: nil, spendControlReached: false
        )
        return .init(snapshot: snapshot, email: nil, isStale: false, observedAt: Date())
    }

    private func signedInAccounts() throws -> (Account, Account) {
        let first = Account(email: "first@example.com", displayName: "First", provider: .codex, isActive: true)
        let second = Account(email: "second@example.com", displayName: "Second", provider: .codex)
        profiles.bindDefault(to: first.id)
        CodexAccountRegistry.save([first, second], to: defaults)
        try writeAuth(email: first.email, to: profiles.profile(for: first.id).authURL)
        try writeAuth(email: second.email, to: profiles.profile(for: second.id).authURL)
        return (first, second)
    }

    func testActivatingCLIAccountPreservesCurrentCredentialsAndWritesSelectedProfile() async throws {
        let (first, second) = try signedInAccounts()
        let firstAuth = try String(contentsOf: profiles.defaultProfile.authURL, encoding: .utf8)
        let secondAuth = try String(contentsOf: profiles.profile(for: second.id).authURL, encoding: .utf8)
        var backups: [String: String] = [:]
        let state = CodexState(
            defaults: defaults,
            profiles: profiles,
            openDesktop: { _ in XCTFail("CLI activation must not open Codex Desktop") },
            loadCLIBackup: { backups[$0] },
            saveCLIBackup: { contents, accountID in
                backups[accountID] = contents
                return true
            }
        )

        await state.activateCLI(accountId: second.id)

        XCTAssertEqual(try String(contentsOf: profiles.defaultProfile.authURL, encoding: .utf8), secondAuth)
        XCTAssertEqual(backups[first.id.uuidString], firstAuth)
        XCTAssertEqual(state.accounts.first(where: \.isActive)?.id, second.id)
        XCTAssertNil(state.errorMessage)
    }

    func testActivatingCLIAccountRejectsMismatchedCredentialsWithoutChangingDefault() async throws {
        let (first, second) = try signedInAccounts()
        try writeAuth(email: first.email, to: profiles.profile(for: second.id).authURL)
        let original = try Data(contentsOf: profiles.defaultProfile.authURL)
        let state = CodexState(
            defaults: defaults,
            profiles: profiles,
            loadCLIBackup: { _ in nil },
            saveCLIBackup: { _, _ in true }
        )

        await state.activateCLI(accountId: second.id)

        XCTAssertEqual(try Data(contentsOf: profiles.defaultProfile.authURL), original)
        XCTAssertEqual(state.accounts.first(where: \.isActive)?.id, first.id)
        XCTAssertNotNil(state.errorMessage)
    }

    func testRefreshFetchesEachLiveProfileWithoutSwitchingOrWritingCredentials() async throws {
        let (first, second) = try signedInAccounts()
        let originalAuth = try [first, second].map { try Data(contentsOf: profiles.profile(for: $0.id).authURL) }
        let state = CodexState(defaults: defaults, profiles: profiles, openDesktop: { _ in
            XCTFail("Refresh must not open desktop windows")
        }, fetchUsage: { auth, id in
            XCTAssertEqual(auth.tokens.accountId, id == first.id ? first.email : second.email)
            return self.usage(id == first.id ? 86 : 25, plan: id == first.id ? "team" : "pro")
        }, cachedUsage: { _ in nil })

        await state.refresh(force: true)

        XCTAssertEqual(state.accountCards.first { $0.id == first.id }?.windows.first?.utilization, 86)
        XCTAssertEqual(state.accountCards.first { $0.id == second.id }?.windows.first?.utilization, 25)
        XCTAssertNil(state.accountCards.first { $0.id == second.id }?.notice)
        XCTAssertEqual(state.accounts.first { $0.id == second.id }?.subscriptionType, "pro")
        XCTAssertEqual(state.accounts.first(where: \.isActive)?.id, first.id)
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: profiles.profile(for: $0.id).authURL) }, originalAuth)
    }

    func testRefreshBackoffAndErrorsAreIsolatedPerProfile() async throws {
        let (first, second) = try signedInAccounts()
        var calls: [UUID: Int] = [:]
        let state = CodexState(defaults: defaults, profiles: profiles, fetchUsage: { _, id in
            calls[id, default: 0] += 1
            if id == first.id { throw CodexUsageService.UsageError.rateLimited(retryAfter: 600) }
            return self.usage(25)
        }, cachedUsage: { id in id == first.id ? self.usage(86) : nil })

        await state.refresh(force: true)
        await state.refresh(force: false)

        XCTAssertEqual(calls[first.id], 1)
        XCTAssertEqual(calls[second.id], 2)
        XCTAssertEqual(state.accountCards.first { $0.id == first.id }?.error?.isRateLimited, true)
        XCTAssertEqual(state.accountCards.first { $0.id == first.id }?.windows.first?.utilization, 86)
        XCTAssertNil(state.accountCards.first { $0.id == second.id }?.error)
        XCTAssertEqual(state.accountCards.first { $0.id == second.id }?.windows.first?.utilization, 25)

        await state.refresh(force: true)
        XCTAssertEqual(calls[first.id], 2)
        XCTAssertEqual(calls[second.id], 3)
    }

    func testInactiveProfileUsesItsOwnCacheWhenLiveFetchFails() async throws {
        let (first, second) = try signedInAccounts()
        let state = CodexState(defaults: defaults, profiles: profiles, fetchUsage: { _, id in
            if id == second.id { throw CodexUsageService.UsageError.needsReauth }
            return self.usage(86)
        }, cachedUsage: { id in id == second.id ? self.usage(25) : nil })

        await state.refresh(force: true)

        XCTAssertEqual(state.accountCards.first { $0.id == first.id }?.windows.first?.utilization, 86)
        XCTAssertEqual(state.accountCards.first { $0.id == second.id }?.windows.first?.utilization, 25)
        XCTAssertEqual(state.accountCards.first { $0.id == second.id }?.error?.needsReauth, true)
        XCTAssertNotNil(state.accountCards.first { $0.id == second.id }?.notice)
    }

    func testMismatchedInactiveProfileIsNotFetchedOrShownAsAnotherAccount() async throws {
        let (first, second) = try signedInAccounts()
        try writeAuth(email: first.email, to: profiles.profile(for: second.id).authURL)
        let state = CodexState(defaults: defaults, profiles: profiles, fetchUsage: { _, id in
            XCTAssertEqual(id, first.id)
            return self.usage(86)
        }, cachedUsage: { _ in self.usage(25) })

        await state.refresh(force: true)

        XCTAssertEqual(state.accountCards.first { $0.id == second.id }?.error?.needsReauth, true)
        XCTAssertEqual(state.accountCards.first { $0.id == second.id }?.windows.count, 0)
    }

    func testSwitchingLegacyAccountOpensEmptyProfileAndPreservesDefault() async throws {
        let first = Account(email: "first@example.com", displayName: "First", provider: .codex, isActive: true)
        let second = Account(email: "second@example.com", displayName: "Second", provider: .codex)
        CodexAccountRegistry.save([first, second], to: defaults)
        try writeAuth(email: first.email, to: profiles.defaultProfile.authURL)
        let original = try Data(contentsOf: profiles.defaultProfile.authURL)
        var opened: CodexDesktopProfile?
        let state = CodexState(defaults: defaults, profiles: profiles, openDesktop: { opened = $0 })
        await state.switchTo(accountId: second.id)
        state.cancelLogin()
        XCTAssertEqual(opened, profiles.profile(for: second.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened!.authURL.path))
        XCTAssertEqual(try Data(contentsOf: profiles.defaultProfile.authURL), original)
        XCTAssertEqual(state.accounts.first(where: \.isActive)?.id, first.id)
    }

    func testNewLoginRegistersOnlyTheProfileThatCompletedAuthentication() async throws {
        var opened: CodexDesktopProfile?
        let state = CodexState(defaults: defaults, profiles: profiles, openDesktop: { opened = $0 })
        await state.loginNewAccount()
        state.cancelLogin()
        let id = try XCTUnwrap(state.pendingLoginID)
        XCTAssertFalse(state.acceptLoginIfReady(id: id))
        try writeAuth(email: "second@example.com", to: try XCTUnwrap(opened).authURL)
        XCTAssertTrue(state.acceptLoginIfReady(id: id))
        XCTAssertEqual(state.accounts.first?.email, "second@example.com")
        XCTAssertEqual(state.selectedProfile, opened)
        XCTAssertNil(state.pendingLoginID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profiles.defaultProfile.authURL.path))
    }

    func testWrongAccountCannotReplaceExpectedAccount() async throws {
        let expected = Account(email: "expected@example.com", displayName: "Expected", provider: .codex)
        CodexAccountRegistry.save([expected], to: defaults)
        let state = CodexState(defaults: defaults, profiles: profiles, openDesktop: { _ in })
        try writeAuth(email: "wrong@example.com", to: profiles.profile(for: expected.id).authURL)
        XCTAssertFalse(state.acceptLoginIfReady(id: expected.id))
        XCTAssertEqual(state.accounts.first?.email, expected.email)
        XCTAssertFalse(state.accounts.first!.isActive)
        XCTAssertTrue(state.errorMessage?.contains(expected.email) == true)
    }

    func testFailedDesktopLaunchDoesNotSelectTargetOrWriteAuth() async throws {
        let target = Account(email: "second@example.com", displayName: "Second", provider: .codex)
        CodexAccountRegistry.save([target], to: defaults)
        let state = CodexState(defaults: defaults, profiles: profiles, openDesktop: { _ in throw CocoaError(.fileNoSuchFile) })
        await state.switchTo(accountId: target.id)
        XCTAssertFalse(state.isLoading)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertFalse(state.accounts.first!.isActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profiles.profile(for: target.id).authURL.path))
    }

    func testDefaultAccountCanBeReimportedAfterRemovingItsRow() throws {
        try writeAuth(email: "first@example.com", to: profiles.defaultProfile.authURL)
        let state = CodexState(defaults: defaults, profiles: profiles, openDesktop: { _ in })
        state.reconcileDefaultProfile()
        let id = try XCTUnwrap(state.accounts.first?.id)
        state.removeAccount(id: id)
        state.reconcileDefaultProfile()
        XCTAssertEqual(state.accounts.first?.id, id)
        XCTAssertTrue(profiles.profile(for: id).isDefault)
    }

    func testReauthenticationDoesNotReuseDefaultForNewLogin() async throws {
        try writeAuth(email: "first@example.com", to: profiles.defaultProfile.authURL)
        var opened: [CodexDesktopProfile] = []
        let state = CodexState(defaults: defaults, profiles: profiles, openDesktop: { opened.append($0) })
        state.reconcileDefaultProfile()
        let id = try XCTUnwrap(state.accounts.first?.id)
        await state.reauthenticate(id: id)
        XCTAssertNil(state.pendingLoginID)
        await state.loginNewAccount()
        state.cancelLogin()
        XCTAssertFalse(try XCTUnwrap(opened.last).isDefault)
        XCTAssertNotEqual(state.pendingLoginID, id)
    }

    func testUsageCacheIsPartitionedByProfile() {
        let cache = CodexUsageDiskCache(root: root.appendingPathComponent("usage"))
        let first = UUID(), second = UUID()
        cache.save(.init(snapshot: .empty, email: "second@example.com", isStale: false, observedAt: Date()), profileID: second)
        XCTAssertNil(cache.load(profileID: first))
        XCTAssertEqual(cache.load(profileID: second)?.email, "second@example.com")
        XCTAssertTrue(cache.load(profileID: second)?.isStale == true)
    }

    func testStopWaitingPersistsPauseAcrossRelaunch() async {
        let state = CodexState(defaults: defaults, profiles: profiles, openDesktop: { _ in })
        await state.loginNewAccount()
        state.cancelLogin()
        XCTAssertFalse(state.isAuthenticating)
        XCTAssertTrue(defaults.bool(forKey: "codexDesktopPendingLoginPaused"))
        let reloaded = CodexState(defaults: defaults, profiles: profiles, openDesktop: { _ in })
        XCTAssertEqual(reloaded.pendingLoginID, state.pendingLoginID)
        XCTAssertFalse(reloaded.isAuthenticating)
    }

    func testSessionCachesReadOnlyTheirOwnProfile() async throws {
        let firstRoot = root.appendingPathComponent("first-sessions")
        let secondRoot = root.appendingPathComponent("second-sessions")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "codex-rollout", withExtension: "jsonl", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: firstRoot.appendingPathComponent("rollout-example.jsonl"))
        let first = CodexSessionCache(sessionsRoot: firstRoot.path, cacheURL: root.appendingPathComponent("first-cache.json"))
        let second = CodexSessionCache(sessionsRoot: secondRoot.path, cacheURL: root.appendingPathComponent("second-cache.json"))
        await first.refreshFromFilesystem()
        await second.refreshFromFilesystem()
        let firstSnapshot = await first.latestLocalSnapshot()
        let secondSnapshot = await second.latestLocalSnapshot()
        XCTAssertNotNil(firstSnapshot)
        XCTAssertNil(secondSnapshot)
    }

    func testCancelDuringLaunchDoesNotRestartWaiting() async {
        var continuation: CheckedContinuation<Void, Never>?
        let state = CodexState(defaults: defaults, profiles: profiles, openDesktop: { _ in
            await withCheckedContinuation { continuation = $0 }
        })
        let launch = Task { await state.loginNewAccount() }
        while continuation == nil { await Task.yield() }
        state.cancelLogin()
        continuation?.resume()
        await launch.value
        XCTAssertFalse(state.isAuthenticating)
        XCTAssertTrue(defaults.bool(forKey: "codexDesktopPendingLoginPaused"))
        state.cancelLogin()
    }

    func testLateDefaultLoginDoesNotRebindAnExistingIsolatedProfile() async throws {
        let account = Account(email: "second@example.com", displayName: "Second", provider: .codex, isActive: true)
        CodexAccountRegistry.save([account], to: defaults)
        let isolated = profiles.profile(for: account.id)
        try profiles.prepare(isolated)
        try writeAuth(email: account.email, to: isolated.authURL)
        try writeAuth(email: account.email, to: profiles.defaultProfile.authURL)
        let state = CodexState(defaults: defaults, profiles: profiles, openDesktop: { _ in })
        state.reconcileDefaultProfile()
        XCTAssertNil(profiles.defaultAccountID)
        XCTAssertEqual(state.selectedProfile, isolated)
    }

    func testWindowProbeRequiresAnOnScreenLayerZeroWindowForTheExactProcess() {
        let hidden: [String: Any] = [
            kCGWindowOwnerPID as String: 42,
            kCGWindowLayer as String: 0,
            kCGWindowIsOnscreen as String: false,
            kCGWindowAlpha as String: 1.0
        ]
        let otherProcess: [String: Any] = [
            kCGWindowOwnerPID as String: 7,
            kCGWindowLayer as String: 0,
            kCGWindowIsOnscreen as String: true,
            kCGWindowAlpha as String: 1.0
        ]
        let visible: [String: Any] = [
            kCGWindowOwnerPID as String: 42,
            kCGWindowLayer as String: 0,
            kCGWindowIsOnscreen as String: true,
            kCGWindowAlpha as String: 1.0
        ]

        XCTAssertFalse(CodexWindowVisibility.hasVisibleWindow(in: [hidden, otherProcess], processIdentifier: 42))
        XCTAssertTrue(CodexWindowVisibility.hasVisibleWindow(in: [hidden, visible], processIdentifier: 42))
    }
}
