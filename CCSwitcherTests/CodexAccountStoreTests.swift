import XCTest
@testable import CCSwitcher

final class CodexAccountStoreTests: XCTestCase {

    func testRoundTripsOneEntry() throws {
        let store = ["abc": #"{"auth_mode":"chatgpt"}"#]
        let encoded = try CodexAccountStore.encode(store)
        XCTAssertEqual(try CodexAccountStore.decode(encoded), store)
    }

    func testRoundTripsMultipleEntries() throws {
        let store = ["a": "{\"x\":1}", "b": "{\"y\":2}"]
        let encoded = try CodexAccountStore.encode(store)
        XCTAssertEqual(try CodexAccountStore.decode(encoded), store)
    }

    func testEmptyStoreRoundTrips() throws {
        let encoded = try CodexAccountStore.encode([:])
        XCTAssertEqual(try CodexAccountStore.decode(encoded), [:])
    }

    /// A corrupt or foreign payload must yield an empty store rather than
    /// throwing, so one bad Keychain item cannot brick account switching.
    func testGarbageDecodesToEmpty() {
        XCTAssertEqual(CodexAccountStore.decodeLenient(Data("not json".utf8)), [:])
    }

    func testDecodeLenientPreservesGoodData() throws {
        let encoded = try CodexAccountStore.encode(["k": "v"])
        XCTAssertEqual(CodexAccountStore.decodeLenient(encoded), ["k": "v"])
    }
}
