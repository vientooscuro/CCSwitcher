import XCTest
@testable import CCSwitcher

final class SessionParseCacheV2Tests: XCTestCase {
    func testReleasedClaudeCacheReloadsPersistedEntriesWithoutChangingTotals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = project.appendingPathComponent("session.jsonl")
        let cacheURL = root.appendingPathComponent("cache.json")
        let row = #"{"timestamp":"2026-09-08T12:00:00.000Z","sessionId":"session-1","requestId":"request-1","type":"assistant","message":{"id":"message-1","model":"claude-opus-4-6","usage":{"input_tokens":10,"output_tokens":5},"content":[]}}"#
        try row.write(to: source, atomically: true, encoding: .utf8)
        let cache = SessionParseCacheV2(projectsDir: root.path, cacheURL: cacheURL)

        await cache.refreshFromFilesystem()
        let before = await cache.costSummary()
        let residentBeforeRelease = await cache.residentFileCount()
        XCTAssertEqual(residentBeforeRelease, 1)

        await cache.releaseResidentData()
        let residentAfterRelease = await cache.residentFileCount()
        XCTAssertEqual(residentAfterRelease, 0)

        await cache.refreshFromFilesystem()
        let after = await cache.costSummary()
        let residentAfterReload = await cache.residentFileCount()
        XCTAssertEqual(residentAfterReload, 1)
        XCTAssertEqual(before.dailyCosts.first?.totalTokens, 15)
        XCTAssertEqual(after.dailyCosts.first?.totalTokens, before.dailyCosts.first?.totalTokens)
    }
}
