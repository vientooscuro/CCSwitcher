# Release Session Cache Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Release decoded Claude and Codex per-session cache objects after their UI summaries have been published, while keeping account switching available during independent statistics work.

**Architecture:** Both cache actors keep their existing JSON persistence and reload semantics. Add an explicit residency boundary that clears decoded `files` and resets `loaded`; the next explicit statistics refresh reloads the same disk cache before scanning mtimes. Automatic startup and periodic refreshes update only credentials and limits, avoiding a multi-gigabyte history decode on launch. Split account and statistics state for both providers so credential work still blocks switching, while history processing has its own non-blocking, overlap-safe phase.

**Tech Stack:** Swift 6 actors, Foundation JSON persistence, XCTest, XcodeGen, macOS `footprint` and `ps` verification.

## Global Constraints

- Preserve calculated cost, activity, deduplication, and incremental refresh behavior.
- Do not delete or invalidate user cache files.
- Keep the change limited to cache residency and its call sites.
- Account switching must remain blocked during credential work and become available before history parsing starts.
- Verify both automated behavior and cold-launch process memory.

---

### Task 1: Add explicit cache residency boundaries

**Files:**
- Modify: `CCSwitcher/Services/SessionParseCacheV2.swift`
- Modify: `CCSwitcher/Codex/Services/CodexSessionCache.swift`
- Modify: `CCSwitcher/AppState.swift`
- Modify: `CCSwitcher/Codex/CodexState.swift`
- Create: `CCSwitcherTests/SessionParseCacheV2Tests.swift`
- Create: `CCSwitcherTests/AppStateRefreshPhaseTests.swift`
- Test: `CCSwitcherTests/CodexAccountingRegressionTests.swift`

**Interfaces:**
- Produces: `releaseResidentData()` and `residentFileCount()` actor methods on both cache types, plus an explicit Claude statistics phase boundary.
- Consumes: existing `refreshFromFilesystem()`, `costSummary()` / `costSeries()`, and activity aggregation methods.

- [x] **Step 1: Write failing residency tests**

For each cache actor, create a temporary source tree and cache file, refresh once, assert one resident file, record the calculated token totals, release resident data, assert zero resident files, refresh again, and assert the same totals are restored from the persisted cache.

- [x] **Step 2: Verify RED**

Run:

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/SessionParseCacheV2Tests -only-testing:CCSwitcherTests/CodexAccountingRegressionTests
```

Expected: compilation fails because the configurable Claude-cache initializer and residency methods do not yet exist.

- [x] **Step 3: Implement residency release**

Make the Claude cache initializer internal with default production paths for test injection. On both actors, implement `releaseResidentData()` by replacing `files` with an empty dictionary and setting `loaded = false`; implement `residentFileCount()` as a diagnostic count. Do not alter the persisted JSON cache.

- [x] **Step 4: Verify GREEN for cache tests**

Run the focused test command from Step 2. Expected: both cache test suites pass with zero failures and the before/after summaries match.

- [x] **Step 5: Release data after publishing summaries**

In `AppState.refresh`, call the Claude cache residency boundary after assigning `costSummary` and `activityStats`. In `CodexState.refreshCostAndActivity`, call the selected Codex cache residency boundary after calculating local `cost` and `activity` and before any generation guard can return.

- [x] **Step 6: Make statistics non-blocking for account actions**

Add explicit statistics-phase transitions to both provider states. Automatic refreshes must stop after account/limit work; only forced or statistics-specific refreshes decode history. The transition must clear the account-loading flag, reject overlapping statistics work, and clear the statistics flag only for the current generation. Add unit tests for the account-action boundary, automatic-refresh skip, and Codex overlap guard.

- [x] **Step 7: Run full tests and build**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS'
xcodebuild build -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Release -destination 'platform=macOS'
```

Expected: both commands exit 0 with zero test failures.

- [x] **Step 8: Measure the release build**

Launch the built app from a clean process and sample RSS throughout startup. With Codex/all-profiles selected and its 355-MB history cache present, compare against the reproduced 3.4-GiB startup peak. The verified on-demand build peaked at 92 MiB RSS and settled at 92 MiB during the same window.

- [x] **Step 9: Commit**

```bash
git add CCSwitcher/Services/SessionParseCacheV2.swift CCSwitcher/Codex/Services/CodexSessionCache.swift CCSwitcher/AppState.swift CCSwitcher/Codex/CodexState.swift CCSwitcherTests/SessionParseCacheV2Tests.swift CCSwitcherTests/AppStateRefreshPhaseTests.swift CCSwitcherTests/CodexAccountingRegressionTests.swift docs/superpowers/plans/2026-09-08-release-session-cache-memory.md
git commit -m "Release session caches after refresh"
```
