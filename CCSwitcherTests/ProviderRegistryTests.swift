import XCTest
@testable import CCSwitcher

final class ProviderRegistryTests: XCTestCase {

    func testClaudeOnlyWhenCodexConfigIsAbsent() {
        let available = ProviderRegistry.detect(
            claudeInstalled: true,
            fileExists: { _ in false }
        )
        XCTAssertEqual(available, [.claudeCode])
    }

    func testCodexAppearsWhenAuthFileExists() {
        let available = ProviderRegistry.detect(
            claudeInstalled: true,
            fileExists: { $0.hasSuffix("/.codex/auth.json") }
        )
        XCTAssertEqual(available, [.claudeCode, .codex])
    }

    func testCodexOnlyWhenClaudeIsMissing() {
        let available = ProviderRegistry.detect(
            claudeInstalled: false,
            fileExists: { $0.hasSuffix("/.codex/auth.json") }
        )
        XCTAssertEqual(available, [.codex])
    }

    /// A machine with neither provider must still yield one entry, otherwise the
    /// hub has no surface to show and the popover renders blank.
    func testFallsBackToClaudeWhenNothingIsDetected() {
        let available = ProviderRegistry.detect(claudeInstalled: false, fileExists: { _ in false })
        XCTAssertEqual(available, [.claudeCode])
    }

    func testResolvePrefersPersistedProviderWhenAvailable() {
        let resolved = ProviderRegistry.resolveActive(persisted: "Codex", available: [.claudeCode, .codex])
        XCTAssertEqual(resolved, .codex)
    }

    func testResolveFallsBackWhenPersistedProviderVanished() {
        let resolved = ProviderRegistry.resolveActive(persisted: "Codex", available: [.claudeCode])
        XCTAssertEqual(resolved, .claudeCode)
    }

    func testResolveFallsBackOnUnknownPersistedValue() {
        let resolved = ProviderRegistry.resolveActive(persisted: "Copilot", available: [.claudeCode, .codex])
        XCTAssertEqual(resolved, .claudeCode)
    }

    func testResolveFallsBackOnNoPersistedValue() {
        let resolved = ProviderRegistry.resolveActive(persisted: nil, available: [.codex])
        XCTAssertEqual(resolved, .codex)
    }
}
