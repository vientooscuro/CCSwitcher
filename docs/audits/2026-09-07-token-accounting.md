# Token and cost accounting audit

Date: 2026-09-07. Scope: current repository, local pricing snapshots, local Codex/Claude caches, and XCTest. Product code was not changed.

## Verdict

Token arithmetic is consistent with the observed Codex schema, including Astra. Cost estimates are incomplete and must not be interpreted as actual subscription charges. The existing tests do not establish that every historical request is counted exactly once.

## Confirmed findings

### P1: Astra pricing is discarded

`CCSwitcher/Services/PricingService.swift:436` admits only GPT-5, codex, o3 and o4 families. The downloaded `litellm-pricing-fresh.json` contains an exact `gpt-6-astra` row, but `providerModels` discards it. The bundled snapshot has no Astra row either. `CodexSessionCache.swift:180` then assigns zero cost and includes Astra in `unpricedModels`; the detail view warns that the estimate is incomplete.

The current version-7 all-profile cache contained 3,119 files. Replaying the current two-stage merge algorithm over that snapshot retained these Astra counters:

| Counter | Tokens |
| --- | ---: |
| Input, including cached input | 430,781,815 |
| Cached input | 419,761,280 |
| Cache writes | 0 |
| Output, including reasoning | 1,395,717 |
| Total | 432,177,532 |

Using the downloaded table's base rates ($10/M fresh input, $1/M cached input, $50/M output), these counters imply $599.75248 of omitted standard-rate estimate. This is a snapshot calculation, not an invoice reconciliation or proof that the merge's request identities are perfect. Logs were being appended during the audit.

Fix: accept supported model families without a GPT-5 generation restriction, update the bundled fallback, and test Astra resolution through the actual loader.

### P1: OpenAI request pricing modifiers are lost

`PricingService.swift:68` applies only base rates. Its decoder ignores `*_above_272k_tokens`, `*_priority` and `*_flex` fields that are present in the local pricing source for GPT-5.4, Sol, Terra and Astra. `CodexSessionCache.costSeries()` prices daily model totals, so the original per-request context threshold cannot be recovered at pricing time. Usage events also do not retain the service tier.

Fix: price deduplicated requests before daily aggregation, preserve request pricing metadata, decode the relevant rate variants, and explicitly label unknown service tiers. Merely admitting Astra into the table is insufficient for general pricing correctness. The September 7 sample contained no changed token snapshots with last-request input above 272,000 and no nonzero cache-write counts; therefore this audit does not quantify a local long-context surcharge loss. The sampled turn contexts did not expose a service tier.

### P2: Fuzzy matching silently prices Spark as another model

`PricingService.swift:257` permits prefix matches in either direction. With the downloaded table, `gpt-5.3-codex-spark` resolves to `gpt-5.3-codex`. This is an unverified substitution between distinct models, and the missing-rate warning is suppressed because a price was returned. The version-7 snapshot retained 115,736,699 Spark tokens.

Fix: exact model IDs and explicit, verified aliases; restrict suffix stripping to known date formats. An unknown model should remain visibly unpriced.

### P2: Additional unpriced usage exists

The same merged snapshot retained 46,304,626 tokens under `unknown` and 193,421,297 under `codex-auto-review`. Neither resolves to a price in the downloaded table. Their dollar contribution is also zero. Do not invent rates or relabel these tokens without evidence about the originating model.

## Token accounting checks

- In a read-only sample of 62 September 7 rollout files, 5,571 token-count snapshots satisfied `total_tokens == input_tokens + output_tokens`; none had cached input exceeding input. The earlier model inventory included 1,448 Astra snapshots. Counts can change while active sessions append events.
- `CodexTokenTotals.totalBillableTokens` correctly avoids adding cached input twice. Reasoning output is not added again.
- The Codex display splits inclusive input into fresh input and cached input, so `DailyCostEntry.totalTokens` reconstructs input plus output for the observed zero-cache-write schema.
- Model names are open-ended in the rollout parser. Astra usage is not rejected by the token parser or the merge.
- Existing regressions cover repeated snapshots, independent agent turns, timestamp-rewritten replays, archived files, copied profiles, and preservation of unpriced-model tokens.
- Claude totals include fresh input, output, cache creation and cache reads. Its current cost path uses globally deduplicated entries and keeps the largest output snapshot.

## Limits and follow-up cases

- First partial Codex snapshots intentionally establish a baseline and contribute no usage unless last usage equals cumulative usage (`CodexRolloutParser.swift:125`). If the original history is absent, some historical usage is unrecoverable from this policy. This behavior already has a test; it is not evidence of complete billing coverage.
- Equal cumulative snapshots are treated as duplicates without considering a new turn before that decision. A counter reset to an identical value across a new turn, without a new session metadata event, needs a regression fixture before claiming universal correctness.
- The merge's second key is session + turn + cumulative + delta. Two real requests with an identical key after a reset can collapse. No local incident was established in this audit.
- Conflicting known model labels are resolved lexicographically rather than by provenance. This makes the result deterministic, not necessarily semantically correct.
- Claude's `tiered()` is marginal per token category, rather than choosing a request-level long-context rate. Executing the actual Swift pricing struct with 100k fresh input, 150k cache reads and 1k output at the stored Sonnet 4.5 rates returned $0.36, using base rates for every category despite 250k combined input. Its 1h-cache/200k interaction also lacks the separate combined rate present in the downloaded Sonnet 4.5 entry. No affected long-context row was found in the inspected 175,267-row Claude cache before deduplication. Historical premium rules need dedicated tests and date-aware policy. [Current Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing) states that Claude 4.6 and later have standard pricing across the full context window; avoid applying a legacy premium universally.
- All historical days are repriced with the current table. These are current-price equivalents, not historical invoices.
- Activity duration is an idle-gap heuristic. It is not exact working time, and retimestamped replay can affect activity counts even when token counts deduplicate.
- Local logs cannot establish usage from missing/deleted logs or other devices. No comparison against provider billing records was performed.

## Validation

`xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug -destination 'platform=macOS' test -quiet`

The result bundle reports **181 passed, 1 skipped, 0 failures**. The skipped case is the opt-in live-history audit. The build log contains an anomalous compiler diagnostic saying a command failed with exit code zero, but the structured XCTest result is Passed; test success was verified from the result bundle rather than inferred from shell exit status.

The live-history test was additionally invoked with `TEST_RUNNER_CCSWITCHER_VERIFY_CODEX_HISTORY=1`. A cold parse of all profiles did not complete within ten minutes and was interrupted. This additional run is **not counted as passed**. The live quantitative findings above come from a separately inspected version-7 cache and the September 7 raw-log sample, not from a completed full-history test or independent billing reconciliation.

No product fixes, deployment, credentials changes, or live cache rewrites were part of this audit. Only this report is committed.
