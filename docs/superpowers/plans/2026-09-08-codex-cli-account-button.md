# Codex CLI Account Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a separate account-card button that makes the selected Codex account the credential source for new CLI sessions without opening or changing its isolated Codex Desktop window.

**Architecture:** Keep `switchTo(accountId:)` dedicated to Codex Desktop. Add `activateCLI(accountId:)` to `CodexState`; it resolves and validates the selected profile credentials, preserves the currently live default credential in the existing Keychain backup store, and atomically replaces the default `~/.codex/auth.json` through `CodexAuthWriter`. The SwiftUI card exposes this as a standalone terminal-icon button.

**Tech Stack:** Swift 6, SwiftUI, XCTest, XcodeGen, macOS 14.

## Global Constraints

- `project.yml` remains the only Xcode project source of truth; do not edit `.pbxproj` or generated `Info.plist` files.
- Keep Codex Desktop profile launching and CLI credential activation as separate actions.
- Never persist credentials outside the existing profile files, default `auth.json`, and Keychain backup store.
- Use an atomic owner-only write for the default CLI credential file.

---

### Task 1: Restore standalone Codex CLI activation

**Files:**
- Modify: `CCSwitcher/Codex/CodexState.swift`
- Modify: `CCSwitcher/Views/AccountSwitcherView.swift`
- Test: `CCSwitcherTests/CodexDesktopProfilesTests.swift`

**Interfaces:**
- Consumes: `CodexDesktopProfiles.profile(for:)`, `CodexDesktopProfiles.defaultProfile`, `CodexAuthService.decode(authJSON:)`, `CodexAuthWriter.write(_:to:)`, and `CodexAccountStore` backups.
- Produces: `@MainActor func activateCLI(accountId: UUID) async` on `CodexState` and a standalone terminal-icon action in Codex account cards.

- [ ] **Step 1: Write failing state tests**

Add tests that construct two signed-in profiles, inject in-memory backup load/save closures, call `activateCLI(accountId:)`, and assert that the default `auth.json` now contains the selected account while the previous default credential was saved under its account ID. Add a second test proving that corrupt or mismatched target credentials leave the default file unchanged and surface `errorMessage`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/CodexDesktopProfilesTests
```

Expected: compilation fails because `CodexState.activateCLI(accountId:)` and its injectable backup operations do not exist.

- [ ] **Step 3: Implement minimal CLI activation**

Extend `CodexState` with injectable async backup load/save closures whose defaults delegate to `CodexAccountStore.shared`. Implement `activateCLI(accountId:)` to:

1. Resolve credentials from the target profile when they belong to the requested email, otherwise from its Keychain backup.
2. Validate the target credential before any write.
3. Decode the live default credential, associate it by email with a known account, and require a successful Keychain backup before replacement.
4. Write the target credential using `CodexAuthWriter.write(_:to:)`.
5. Mark the requested account active and refresh state only after the write succeeds.
6. Set a concrete `errorMessage` and preserve the live file on every precondition or write failure.

- [ ] **Step 4: Verify GREEN for focused tests**

Run the focused `xcodebuild test` command from Step 2. Expected: all `CodexDesktopProfilesTests` pass with zero failures.

- [ ] **Step 5: Add the separate account-card button**

In `AccountSwitcherView.accountActions(_:)`, add a Codex-only plain button with the `terminal` SF Symbol and help text `Use in Codex CLI`. Its action casts the provider surface to `CodexState` and awaits `activateCLI(accountId:)`. Disable it while authentication or loading is in progress, independently of the existing `Open Codex` button.

- [ ] **Step 6: Run full verification**

Run:

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS'
xcodebuild build -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug -destination 'platform=macOS'
```

Expected: test and build commands exit 0 with zero test failures.

- [ ] **Step 7: Commit**

```bash
git add CCSwitcher/Codex/CodexState.swift CCSwitcher/Views/AccountSwitcherView.swift CCSwitcherTests/CodexDesktopProfilesTests.swift docs/superpowers/plans/2026-09-08-codex-cli-account-button.md
git commit -m "Restore Codex CLI account switching"
```
