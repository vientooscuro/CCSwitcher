import XCTest
@testable import CCSwitcher

final class CredentialAnchorTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: CredentialAnchorStore!

    override func setUp() {
        suiteName = "CredentialAnchorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = CredentialAnchorStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFirstReadTrustsTheIdentityBlock() {
        XCTAssertEqual(store.resolveOwner(accessToken: "t1", claimedAccountId: a), .owned(a))
    }

    func testFirstReadPrefersTheBackupHoldingThisExactToken() {
        let owner = store.resolveOwner(accessToken: "t1", claimedAccountId: b) { $0 == "t1" ? self.a : nil }
        XCTAssertEqual(owner, .desynced(claimed: b, credential: a))
    }

    func testIdentityBlockFlipDoesNotMoveAnUnchangedCredential() {
        store.anchor(accountId: a, accessToken: "t1")
        XCTAssertEqual(store.resolveOwner(accessToken: "t1", claimedAccountId: b), .desynced(claimed: b, credential: a))
    }

    func testDesyncIsStickyWhileTheCredentialIsUnchanged() {
        store.anchor(accountId: a, accessToken: "t1")
        _ = store.resolveOwner(accessToken: "t1", claimedAccountId: b)
        XCTAssertEqual(store.resolveOwner(accessToken: "t1", claimedAccountId: a), .desynced(claimed: a, credential: a))
    }

    func testRotationDuringADesyncLeavesTheOwnerUnknown() {
        store.anchor(accountId: a, accessToken: "t1")
        _ = store.resolveOwner(accessToken: "t1", claimedAccountId: b)
        XCTAssertEqual(store.resolveOwner(accessToken: "t2", claimedAccountId: b), .unknown)
    }

    func testCredentialAndIdentityChangingTogetherIsAnExternalLogin() {
        store.anchor(accountId: a, accessToken: "t1")
        XCTAssertEqual(store.resolveOwner(accessToken: "t2", claimedAccountId: b), .owned(b))
    }

    func testAnchoringIsTheWayOutOfADesync() {
        store.anchor(accountId: a, accessToken: "t1")
        _ = store.resolveOwner(accessToken: "t1", claimedAccountId: b)
        store.anchor(accountId: b, accessToken: "t2")
        XCTAssertEqual(store.resolveOwner(accessToken: "t2", claimedAccountId: b), .owned(b))
    }

    func testMissingCredentialHasNoOwner() {
        XCTAssertEqual(store.resolveOwner(accessToken: nil, claimedAccountId: a), .unknown)
    }

    func testForgetOnlyDropsTheMatchingAccount() {
        store.anchor(accountId: a, accessToken: "t1")
        store.forget(accountId: b)
        XCTAssertEqual(store.resolveOwner(accessToken: "t1", claimedAccountId: a), .owned(a))
        store.forget(accountId: a)
        XCTAssertEqual(store.resolveOwner(accessToken: "t1", claimedAccountId: b), .owned(b))
    }
}
