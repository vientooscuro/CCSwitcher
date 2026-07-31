import XCTest
@testable import CCSwitcher

final class PricePerMillionTokensTests: XCTestCase {

    /// claude-opus-4-8 input rate from LiteLLM: $5.00 per million tokens.
    func testWholeDollarRateShowsTwoDecimals() {
        XCTAssertEqual(Formatters.pricePerMillionTokens(5e-06), "$5.00")
    }

    /// gpt-5.1-codex-max cache-read rate: $0.125 per million. Two decimals
    /// would round this to $0.13, losing the distinction from $0.13 proper.
    func testSubDollarRateShowsThreeDecimals() {
        XCTAssertEqual(Formatters.pricePerMillionTokens(1.25e-07), "$0.125")
    }

    func testZeroRate() {
        XCTAssertEqual(Formatters.pricePerMillionTokens(0), "$0.000")
    }
}
