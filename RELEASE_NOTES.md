### New models: Opus 5.5, GPT-6 Sol and GPT-6 Luna

- Price Claude Opus 5.5 (`claude-opus-5-5`) and Codex GPT-6 Sol / GPT-6 Luna (`gpt-6-sol`, `gpt-6-luna`) in cost estimates; sessions on these models no longer count as $0.
- Refresh the bundled LiteLLM pricing snapshot, now including every GPT-6 family model.
- Keep bundled rates available when a previously downloaded pricing table predates this build, so newly released models are priced immediately.
- Keep family colours for versioned model-scoped limits such as “Opus 5.5”.

### Account refresh fixes

- Refresh an expired token of the active Claude account automatically.
- Fix usage refresh right after switching accounts.
- Avoid a stall while reading keychain items with large output.

Costs remain estimates based on local usage and current model prices, not subscription invoices.

**Full Changelog**: https://github.com/vientooscuro/CCSwitcher/compare/v1.13.3...v1.13.4
