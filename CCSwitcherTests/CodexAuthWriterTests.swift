import XCTest
@testable import CCSwitcher

final class CodexAuthWriterTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var target: String { dir.appendingPathComponent("auth.json").path }

    func testWritesContentToANewFile() throws {
        let ok = CodexAuthWriter.write(#"{"a":1}"#, to: target)
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), #"{"a":1}"#)
    }

    func testFileIsOwnerReadWriteOnly() throws {
        XCTAssertTrue(CodexAuthWriter.write("{}", to: target))
        let attrs = try FileManager.default.attributesOfItem(atPath: target)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value
        XCTAssertEqual(perms, 0o600)
    }

    func testOverwriteReplacesContentEntirely() throws {
        XCTAssertTrue(CodexAuthWriter.write(#"{"long":"previous content"}"#, to: target))
        XCTAssertTrue(CodexAuthWriter.write(#"{"s":1}"#, to: target))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), #"{"s":1}"#)
    }

    func testOverwriteKeepsPermissions() throws {
        XCTAssertTrue(CodexAuthWriter.write("{}", to: target))
        XCTAssertTrue(CodexAuthWriter.write(#"{"b":2}"#, to: target))
        let attrs = try FileManager.default.attributesOfItem(atPath: target)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testNoTemporaryFileIsLeftBehind() throws {
        XCTAssertTrue(CodexAuthWriter.write("{}", to: target))
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(contents, ["auth.json"])
    }

    func testWriteToUnwritableDirectoryFails() {
        XCTAssertFalse(CodexAuthWriter.write("{}", to: "/System/nope/auth.json"))
    }

    func testReadReturnsNilForMissingFile() {
        XCTAssertNil(CodexAuthWriter.read(at: dir.appendingPathComponent("absent.json").path))
    }

    func testReadRoundTripsWhatWasWritten() throws {
        XCTAssertTrue(CodexAuthWriter.write(#"{"r":1}"#, to: target))
        XCTAssertEqual(CodexAuthWriter.read(at: target), #"{"r":1}"#)
    }
}
