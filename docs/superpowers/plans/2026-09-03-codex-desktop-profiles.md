# Codex Desktop Profiles Implementation Plan

> Execute sequentially with test-driven-development and verification-before-completion.

**Goal:** Open independent Codex desktop accounts without replacing the default account's credentials.

**Architecture:** Bind the existing default home to its current account. Give every additional account a persistent home and Electron user-data directory under Application Support/CCSwitcher/CodexProfiles. Codex owns login and token refresh; CCSwitcher reads live identity and never restores credential snapshots.

**Tech Stack:** Swift 6, AppKit NSWorkspace, SwiftUI, XCTest, XcodeGen.

## Constraints

- Preserve default Codex auth, existing sessions, and legacy Keychain backups.
- Do not clone credentials, symlink homes, call logout, or terminate Codex.
- New profiles use file credentials in their own home, private directory permissions, and independent Electron storage.
- Read credentials only for normal account identity/usage operations; never log credentials.
- Generate project changes through project.yml/XcodeGen.

## Task 1: Reproduce missing desktop account management

- [x] Add a regression asserting Codex exposes new-account login.
- [x] Run `xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/CodexStateTests test`; verify the capability assertion fails.

## Task 2: Isolated profile lifecycle

Files: `CCSwitcher/Codex/Services/CodexDesktopProfiles.swift`, `CCSwitcherTests/CodexDesktopProfilesTests.swift`.

- [x] Test deterministic account paths, default binding, private directory permissions, no default file writes, no credential seeding, and launch-environment isolation.
- [x] Implement profile preparation, persistent default-account binding, and launching/focusing the corresponding Codex instance with NSWorkspace.
- [x] Launch with `--user-data-dir`, `CODEX_HOME` and `CODEX_ELECTRON_USER_DATA_PATH` set only for that instance; inherit no Codex controller/IPC variables.

## Task 3: Replace credential switching

Files: `CCSwitcher/Codex/CodexState.swift`, `CCSwitcher/Views/AccountSwitcherView.swift`, `CCSwitcher/Providers/ProviderRegistry.swift`.

- [x] Test default account adoption and switching to a second account without overwriting either credential file.
- [x] Read selected-profile credentials for identity/limits; disable default-account fallback for isolated profiles.
- [x] Replace snapshot restore with opening the account's desktop profile. Keep existing backup storage unchanged but unused for login.
- [x] Enable desktop login with persisted pending profile, cancellable bounded observation, expected-email validation, and duplicate detection.
- [x] Show Open Codex on every Codex row; keep Claude controls unchanged. Clarify that other windows/terminal sessions stay on their profiles.

## Task 4: Verify and install

- [x] Run all XCTest tests and a Release build using standard DerivedData.
- [x] Review diff, check absence of credential writes in account switching, and commit.
- [x] Replace only CCSwitcher.app with a recoverable previous bundle backup; relaunch CCSwitcher, not Codex.
- [x] Open the second Codex profile and verify separate live processes, SingletonLock, home, and storage; confirm the original auth checksum is unchanged.
- [ ] User completes browser authentication in the new window; UI automation is not permitted to control Codex, so login success is not claimed.

## Verification outcome

158 XCTest tests passed; Release build and installed app code-signature verification passed. Read-only review defects were reproduced with failing tests and corrected. Live testing against ChatGPT.app 26.901.22334 confirmed that the Chromium command-line argument is required in addition to environment overrides. Two app processes remain live with distinct profile locks; the original auth.json checksum is unchanged. Previous CCSwitcher.app is retained under Application Support/CCSwitcher/AppBackups/2026-09-03-before-desktop-profiles.
