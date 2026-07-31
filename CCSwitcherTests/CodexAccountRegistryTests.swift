import XCTest
@testable import CCSwitcher

final class CodexAccountRegistryTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "codex-registry-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func account(_ email: String, active: Bool = false) -> Account {
        Account(email: email, displayName: email, provider: .codex, isActive: active)
    }

    func testStartsEmpty() {
        XCTAssertTrue(CodexAccountRegistry.load(from: defaults).isEmpty)
    }

    func testRoundTripsAccounts() {
        let accounts = [account("a@b.c", active: true), account("d@e.f")]
        CodexAccountRegistry.save(accounts, to: defaults)
        let loaded = CodexAccountRegistry.load(from: defaults)
        XCTAssertEqual(loaded.map(\.email), ["a@b.c", "d@e.f"])
        XCTAssertTrue(loaded[0].isActive)
        XCTAssertFalse(loaded[1].isActive)
    }

    func testEveryStoredAccountIsCodex() {
        CodexAccountRegistry.save([account("a@b.c")], to: defaults)
        XCTAssertEqual(CodexAccountRegistry.load(from: defaults).map(\.provider), [.codex])
    }

    /// The Claude key must be untouched — reading or writing it would let Codex
    /// rows leak into `AppState`, which assumes every account is Claude.
    func testDoesNotUseTheClaudeKey() {
        CodexAccountRegistry.save([account("a@b.c")], to: defaults)
        XCTAssertNil(defaults.data(forKey: "com.ccswitcher.accounts"))
        XCTAssertNotNil(defaults.data(forKey: CodexAccountRegistry.storageKey))
    }

    func testMarkActiveMovesTheFlag() {
        let a = account("a@b.c", active: true)
        let b = account("d@e.f")
        let updated = CodexAccountRegistry.markActive(id: b.id, in: [a, b])
        XCTAssertFalse(updated[0].isActive)
        XCTAssertTrue(updated[1].isActive)
    }

    func testMarkActiveWithUnknownIdClearsEveryFlag() {
        let updated = CodexAccountRegistry.markActive(id: UUID(), in: [account("a@b.c", active: true)])
        XCTAssertFalse(updated[0].isActive)
    }

    func testCorruptPayloadLoadsEmptyRatherThanCrashing() {
        defaults.set(Data("garbage".utf8), forKey: CodexAccountRegistry.storageKey)
        XCTAssertTrue(CodexAccountRegistry.load(from: defaults).isEmpty)
    }
}
