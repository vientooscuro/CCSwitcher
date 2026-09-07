### More accurate Codex cost estimates

- Add GPT-6 Astra pricing while preserving its full token usage.
- Apply long-context, Priority and Flex rates per request before daily aggregation.
- Keep models without verified prices visibly unpriced instead of substituting another model's rate.
- Preserve service-tier information across replayed sessions and mark estimates incomplete when that information is missing.
- Improve replay deduplication so input order does not change the result.

Costs remain estimates based on local usage and current model prices, not subscription invoices. Existing history is refreshed on first launch; large histories can take several minutes.

Validation: 191 tests passed, one opt-in full-history test skipped.

**Full Changelog**: https://github.com/vientooscuro/CCSwitcher/compare/v1.13.1...v1.13.2
