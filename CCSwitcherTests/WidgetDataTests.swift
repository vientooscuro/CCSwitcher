import XCTest
@testable import CCSwitcher

final class WidgetDataTests: XCTestCase {

    // MARK: - Backward compatibility: an older build's snapshot has no "provider" key

    /// `provider` was added after `WidgetData` shipped. A snapshot written by
    /// an older build on disk has no such key at all — this pins that the
    /// synthesized `Codable` conformance (no custom `init(from:)`) decodes
    /// that as nil rather than failing the whole decode.
    func testDecodesSnapshotMissingProviderKey() throws {
        let current = WidgetData(
            accounts: [],
            todayCost: 1.23,
            conversationTurns: 4,
            activeCodingTime: "1h 30m",
            linesWritten: 10,
            modelUsage: ["Sonnet": 3],
            lastUpdated: Date(),
            provider: "Claude Code"
        )
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
        )
        XCTAssertNotNil(json["provider"], "sanity check: the key is present before we strip it")
        json.removeValue(forKey: "provider")

        let strippedData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(WidgetData.self, from: strippedData)

        XCTAssertNil(decoded.provider)
        XCTAssertEqual(decoded.todayCost, 1.23)
        XCTAssertEqual(decoded.conversationTurns, 4)
        XCTAssertEqual(decoded.modelUsage, ["Sonnet": 3])
    }

    func testDecodesSnapshotWithProviderKeyPresent() throws {
        let current = WidgetData(
            accounts: [], todayCost: 0, conversationTurns: 0, activeCodingTime: "0m",
            linesWritten: 0, modelUsage: [:], lastUpdated: Date(), provider: "Codex"
        )
        let decoded = try JSONDecoder().decode(WidgetData.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(decoded.provider, "Codex")
    }

    func testInitDefaultsProviderToNilForExistingCallSites() {
        let data = WidgetData(
            accounts: [], todayCost: 0, conversationTurns: 0, activeCodingTime: "0m",
            linesWritten: 0, modelUsage: [:], lastUpdated: Date()
        )
        XCTAssertNil(data.provider)
    }
}
