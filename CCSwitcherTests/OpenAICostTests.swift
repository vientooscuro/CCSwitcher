import XCTest
@testable import CCSwitcher

final class OpenAICostTests: XCTestCase {

    func testDefaultTierMapsToStandardAndAutoStaysUnknown() {
        XCTAssertEqual(OpenAIServiceTier(rawValueOrUnknown: "default"), .standard)
        XCTAssertEqual(OpenAIServiceTier(rawValueOrUnknown: "auto"), .unknown)
    }

    /// gpt-5.6-sol rates from LiteLLM, in dollars per token.
    private let sol = LiteLLMModelPricing(
        inputPerToken: 5e-06,
        outputPerToken: 3e-05,
        cacheCreatePerToken: 0,
        cacheCreate1hPerToken: nil,
        cacheReadPerToken: 5e-07,
        inputAbove200k: nil,
        outputAbove200k: nil,
        cacheCreateAbove200k: nil,
        cacheReadAbove200k: nil,
        fastMultiplier: nil,
        openAI: .init(
            longContextThreshold: 272_000,
            standardLongContext: .init(input: 8e-06, output: 3e-05, cacheCreate: 1e-05, cacheRead: 8e-07),
            priority: .init(input: 8e-06, output: 4e-05, cacheCreate: 1e-05, cacheRead: 8e-07),
            priorityLongContext: .init(input: 16e-06, output: 6e-05, cacheCreate: 2e-05, cacheRead: 1.6e-06),
            flex: .init(input: 2e-06, output: 1e-05, cacheCreate: 2.5e-06, cacheRead: 2e-07),
            flexLongContext: .init(input: 4e-06, output: 1.5e-05, cacheCreate: 5e-06, cacheRead: 4e-07)
        )
    )

    /// OpenAI reports `input_tokens` inclusive of `cached_input_tokens`, so the
    /// cached part must be subtracted before applying the fresh-input rate.
    /// Charging the full input at the fresh rate would overstate cost roughly
    /// tenfold on a cache-heavy Codex session, where 97% of input is cached.
    func testCachedInputIsSubtractedFromFreshInput() {
        let cost = sol.openAICost(inputTokens: 1000, cachedInputTokens: 900, cacheWriteTokens: 0, outputTokens: 0)
        XCTAssertEqual(cost, 100 * 5e-06 + 900 * 5e-07, accuracy: 1e-12)
    }

    func testFullyCachedInputBillsOnlyAtCacheReadRate() {
        let cost = sol.openAICost(inputTokens: 500, cachedInputTokens: 500, cacheWriteTokens: 0, outputTokens: 0)
        XCTAssertEqual(cost, 500 * 5e-07, accuracy: 1e-12)
    }

    /// A malformed payload where cached exceeds input must not produce negative cost.
    func testCachedExceedingInputClampsToZeroFreshInput() {
        let cost = sol.openAICost(inputTokens: 100, cachedInputTokens: 500, cacheWriteTokens: 0, outputTokens: 0)
        XCTAssertEqual(cost, 100 * 5e-07, accuracy: 1e-12)
    }

    /// `output_tokens` already contains `reasoning_output_tokens`; the caller must
    /// not add reasoning again, and this method must not either.
    func testOutputIsBilledOnceIncludingReasoning() {
        let cost = sol.openAICost(inputTokens: 0, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 308)
        XCTAssertEqual(cost, 308 * 3e-05, accuracy: 1e-12)
    }

    /// OpenAI does not charge for cache writes and reports the counter as zero.
    func testZeroCacheWriteCostsNothing() {
        let cost = sol.openAICost(inputTokens: 0, cachedInputTokens: 0, cacheWriteTokens: 1000, outputTokens: 0)
        XCTAssertEqual(cost, 0, accuracy: 1e-12)
    }

    func testRealSessionTotalsMatchHandCalculation() {
        // Observed totals from one rollout file.
        let cost = sol.openAICost(
            inputTokens: 54_774_121,
            cachedInputTokens: 52_989_696,
            cacheWriteTokens: 0,
            outputTokens: 213_171
        )
        let expected = Double(54_774_121 - 52_989_696) * 8e-06
            + 52_989_696 * 8e-07
            + 213_171 * 3e-05
        XCTAssertEqual(cost, expected, accuracy: 1e-9)
    }

    func testLongContextRateAppliesToEntireRequest() {
        let cost = sol.openAICost(
            inputTokens: 300_000, cachedInputTokens: 200_000,
            cacheWriteTokens: 0, outputTokens: 1_000, serviceTier: .standard
        )
        XCTAssertEqual(cost, 100_000 * 8e-06 + 200_000 * 8e-07 + 1_000 * 3e-05, accuracy: 1e-12)
    }

    func testPriorityAndFlexUseRequestTierRates() {
        let priority = sol.openAICost(
            inputTokens: 1_000, cachedInputTokens: 500,
            cacheWriteTokens: 0, outputTokens: 100, serviceTier: .priority
        )
        let flex = sol.openAICost(
            inputTokens: 1_000, cachedInputTokens: 500,
            cacheWriteTokens: 0, outputTokens: 100, serviceTier: .flex
        )
        XCTAssertEqual(priority, 500 * 8e-06 + 500 * 8e-07 + 100 * 4e-05, accuracy: 1e-12)
        XCTAssertEqual(flex, 500 * 2e-06 + 500 * 2e-07 + 100 * 1e-05, accuracy: 1e-12)
    }

    // MARK: - Model resolution

    func testBundledTableResolvesCodexModels() async {
        let service = PricingService.shared
        await service.ensureLoaded()
        for model in ["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.3-codex", "gpt-5.1-codex-max"] {
            let pricing = await service.pricing(for: model)
            XCTAssertNotNil(pricing, "no pricing row for \(model)")
            XCTAssertGreaterThan(pricing?.inputPerToken ?? 0, 0, "zero input rate for \(model)")
        }
    }

    func testBundledTableResolvesAstraExactly() async {
        let pricing = await PricingService.shared.pricing(for: "gpt-6-astra")
        XCTAssertEqual(pricing?.inputPerToken, 10e-06)
        XCTAssertEqual(pricing?.outputPerToken, 50e-06)
    }

    func testSparkDoesNotFuzzyResolveToCodex() async {
        let pricing = await PricingService.shared.pricing(for: "gpt-5.3-codex-spark")
        XCTAssertNil(pricing)
    }

    func testBundledTableStillResolvesClaudeModels() async {
        let service = PricingService.shared
        await service.ensureLoaded()
        let pricing = await service.pricing(for: "claude-opus-4-8")
        XCTAssertNotNil(pricing)
        XCTAssertGreaterThan(pricing?.outputPerToken ?? 0, 0)
    }

    func testOpenAIRouterPrefixResolves() async {
        let service = PricingService.shared
        await service.ensureLoaded()
        let pricing = await service.pricing(for: "gpt-5.6")
        XCTAssertNotNil(pricing)
    }
}
