import XCTest
@testable import CCSwitcher

final class ClaudePricingTests: XCTestCase {
    private func pricing(includeLongOneHourRate: Bool = true) throws -> LiteLLMModelPricing {
        var row: [String: Double] = [
            "input_cost_per_token": 1e-7,
            "output_cost_per_token": 5e-7,
            "cache_creation_input_token_cost": 1.25e-7,
            "cache_creation_input_token_cost_above_1hr": 2e-7,
            "cache_read_input_token_cost": 1e-8,
            "input_cost_per_token_above_100k_tokens": 5e-7,
            "output_cost_per_token_above_100k_tokens": 2.5e-6,
            "cache_creation_input_token_cost_above_100k_tokens": 6.25e-7,
            "cache_read_input_token_cost_above_100k_tokens": 5e-8,
        ]
        if includeLongOneHourRate {
            row["cache_creation_input_token_cost_above_1hr_above_100k_tokens"] = 1e-6
        }
        let data = try JSONSerialization.data(withJSONObject: row)
        let entry = try JSONDecoder().decode(PricingService.LiteLLMEntry.self, from: data)
        return try XCTUnwrap(entry.toPricing())
    }

    func testThresholdIncludesCacheAndExcludesOutput() throws {
        let price = try pricing()
        let belowLimit = price.cost(input: 19_999, output: 1_000, cacheCreate: 30_000, cacheCreate1h: 10_000, cacheRead: 50_000, isFast: false)
        let expectedBelow = 19_999 * 1e-7 + 1_000 * 5e-7 + 20_000 * 1.25e-7 + 10_000 * 2e-7 + 50_000 * 1e-8
        XCTAssertEqual(belowLimit, expectedBelow, accuracy: 1e-12)
        let atLimit = price.cost(input: 20_000, output: 100_001, cacheCreate: 30_000, cacheCreate1h: 10_000, cacheRead: 50_000, isFast: false)
        let expected = 20_000 * 1e-7 + 100_001 * 5e-7 + 20_000 * 1.25e-7 + 10_000 * 2e-7 + 50_000 * 1e-8
        XCTAssertEqual(atLimit, expected, accuracy: 1e-12)
    }

    func testAboveThresholdAppliesEveryLongRateToEntireRequest() throws {
        let price = try pricing()
        let cost = price.cost(input: 20_001, output: 1_000, cacheCreate: 30_000, cacheCreate1h: 10_000, cacheRead: 50_000, isFast: false)
        let expected = 20_001 * 5e-7 + 1_000 * 2.5e-6 + 20_000 * 6.25e-7 + 10_000 * 1e-6 + 50_000 * 5e-8
        XCTAssertEqual(cost, expected, accuracy: 1e-12)
    }

    func testLongOneHourRateFallsBackToTwiceLongInputRate() throws {
        let price = try pricing(includeLongOneHourRate: false)
        let cost = price.cost(input: 100_001, output: 0, cacheCreate: 10, cacheCreate1h: 10, cacheRead: 0, isFast: false)
        XCTAssertEqual(cost, 100_001 * 5e-7 + 10 * 1e-6, accuracy: 1e-12)
    }

    func testExplicitLongOneHourRateOverridesFallback() throws {
        let data = Data("""
        {"input_cost_per_token": 0.0000001,
         "input_cost_per_token_above_100k_tokens": 0.0000005,
         "cache_creation_input_token_cost_above_1hr_above_100k_tokens": 0.0000012}
        """.utf8)
        let price = try XCTUnwrap(JSONDecoder().decode(PricingService.LiteLLMEntry.self, from: data).toPricing())
        let cost = price.cost(input: 100_001, output: 0, cacheCreate: 10, cacheCreate1h: 10, cacheRead: 0, isFast: false)
        XCTAssertEqual(cost, 100_001 * 5e-7 + 10 * 1.2e-6, accuracy: 1e-12)
    }

    func testExisting200kTierAndOneHourRateRemainUnchanged() throws {
        let data = Data("""
        {"input_cost_per_token": 0.000003, "output_cost_per_token": 0.000015,
         "cache_creation_input_token_cost": 0.00000375, "cache_read_input_token_cost": 0.0000003,
         "input_cost_per_token_above_200k_tokens": 0.000006}
        """.utf8)
        let price = try XCTUnwrap(JSONDecoder().decode(PricingService.LiteLLMEntry.self, from: data).toPricing())
        let cost = price.cost(input: 200_001, output: 0, cacheCreate: 10, cacheCreate1h: 10, cacheRead: 0, isFast: false)
        XCTAssertEqual(cost, 200_000 * 3e-6 + 6e-6 + 10 * 6e-6, accuracy: 1e-12)
    }
}
