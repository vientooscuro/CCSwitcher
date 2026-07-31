# Codex Provider — Stage 3: Account Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user keep several ChatGPT accounts and switch Codex between them from CCSwitcher, without a terminal.

**Architecture:** Codex credentials live in one plaintext file, `~/.codex/auth.json`. Switching is therefore a file swap, not the Keychain dance Claude needs. CCSwitcher keeps a per-account copy of that file in its own Keychain entry, writes the target copy atomically at mode `0600`, and delegates login to `codex login`.

**Tech Stack:** Swift 6 (`SWIFT_STRICT_CONCURRENCY: targeted`), SwiftUI, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-31-codex-provider-design.md`
**Prerequisites:** Stages 1 and 2 complete. 84 tests passing.

---

## Ground Rules For Every Task

- `project.yml` is the ONLY source of truth. **Never hand-edit `project.pbxproj` or `Info.plist`.** Run `xcodegen generate` after adding files.
- Standard DerivedData only. No `-derivedDataPath`, never `/tmp`.
- Build: `xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5`
- Test: `xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' 2>&1 | tail -6`
- Run `xcodebuild` in the FOREGROUND with a timeout up to 600000 ms.
- Commit messages: ONE imperative line, English, no body, no backticks, **never** `Co-Authored-By`.
- The editor's language server emits spurious `Cannot find X in scope` errors after `xcodegen generate`. Trust `xcodebuild`.

## Safety Rules Specific To This Stage

This is the first stage that **writes** to `~/.codex`, and it writes a file holding live credentials. Three rules are absolute:

1. **Never write `auth.json` without having first backed up what is currently there.** A lost `auth.json` means the user must re-run `codex login` for that account.
2. **Never issue an OAuth refresh grant.** Unchanged from Stage 2: the access token lives 10 days and the Codex CLI owns refreshing it.
3. **Write atomically at mode `0600`** — temp file in the same directory, `chmod`, then `rename`. A half-written `auth.json` would break Codex entirely, and a world-readable one would leak a refresh token.

During development, take a manual copy before the first write:

```bash
cp ~/.codex/auth.json ~/codex-auth-backup-$(date +%s).json
```

Tell the user the path in your report so they can restore it if anything goes wrong.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `CCSwitcher/Codex/Services/CodexAccountStore.swift` | Per-account `auth.json` copies in the Keychain |
| `CCSwitcher/Codex/Services/CodexCLIService.swift` | `codex` binary discovery, `login`, `logout`, `--version` |
| `CCSwitcher/Codex/Services/CodexAuthWriter.swift` | Atomic `0600` write of `auth.json` |
| `CCSwitcher/Codex/CodexAccountRegistry.swift` | Persisted `[Account]` for Codex |
| `CCSwitcher/Views/CodexCLITabView.swift` | Settings tab: binary path, version, login status |
| `CCSwitcherTests/CodexAccountStoreTests.swift` | Store serialization |
| `CCSwitcherTests/CodexAccountRegistryTests.swift` | Persistence and active-account bookkeeping |
| `CCSwitcherTests/CodexAuthWriterTests.swift` | Atomic write, permissions, backup-before-overwrite |

**Modified:**

| Path | Change |
|---|---|
| `CCSwitcher/Codex/CodexState.swift` | Real account list, real actions, capabilities on |
| `CCSwitcher/Views/SettingsView.swift` | Add the Codex CLI tab |

---

### Task 1: Codex account store

**Files:**
- Create: `CCSwitcher/Codex/Services/CodexAccountStore.swift`
- Test: `CCSwitcherTests/CodexAccountStoreTests.swift`

Read `CCSwitcher/Services/KeychainService.swift` first. It already implements exactly this pattern for Claude: a single Keychain generic-password item under service `com.vientooscuro.ccswitcher.backups`, account `all-accounts`, holding a JSON dictionary keyed by account id, with an in-memory `backupCache`. Follow that shape — including the cache, the `SecItemAdd`/`SecItemUpdate` fallback, and the logging style.

Differences for Codex:

- Service name: `com.vientooscuro.ccswitcher.codex.backups`, same `all-accounts` account.
- The stored value per account is the **entire `auth.json` text**, a `String` — not the `AccountBackup` struct, which is Claude-shaped (token plus `oauthAccount`).

- [ ] **Step 1: Write the failing test**

The Keychain itself is not unit-testable without touching the real keychain, so test the pure serialization boundary. Create `CCSwitcherTests/CodexAccountStoreTests.swift`:

```swift
import XCTest
@testable import CCSwitcher

final class CodexAccountStoreTests: XCTestCase {

    func testRoundTripsOneEntry() throws {
        let store = ["abc": #"{"auth_mode":"chatgpt"}"#]
        let encoded = try CodexAccountStore.encode(store)
        XCTAssertEqual(try CodexAccountStore.decode(encoded), store)
    }

    func testRoundTripsMultipleEntries() throws {
        let store = ["a": "{\"x\":1}", "b": "{\"y\":2}"]
        let encoded = try CodexAccountStore.encode(store)
        XCTAssertEqual(try CodexAccountStore.decode(encoded), store)
    }

    func testEmptyStoreRoundTrips() throws {
        let encoded = try CodexAccountStore.encode([:])
        XCTAssertEqual(try CodexAccountStore.decode(encoded), [:])
    }

    /// A corrupt or foreign payload must yield an empty store rather than
    /// throwing, so one bad Keychain item cannot brick account switching.
    func testGarbageDecodesToEmpty() {
        XCTAssertEqual(CodexAccountStore.decodeLenient(Data("not json".utf8)), [:])
    }

    func testDecodeLenientPreservesGoodData() throws {
        let encoded = try CodexAccountStore.encode(["k": "v"])
        XCTAssertEqual(CodexAccountStore.decodeLenient(encoded), ["k": "v"])
    }
}
```

- [ ] **Step 2: Run it and see it fail** with `cannot find 'CodexAccountStore' in scope`.

- [ ] **Step 3: Implement**

Create `CodexAccountStore.swift` as an `actor` (matching `KeychainService`'s isolation choice) with:

```swift
actor CodexAccountStore {
    static let shared = CodexAccountStore()

    /// Entire `auth.json` text for `accountId`, or nil.
    func backup(forAccountId accountId: String) -> String?
    func saveBackup(_ authJSON: String, forAccountId accountId: String) -> Bool
    func removeBackup(forAccountId accountId: String) -> Bool
    /// Ids that currently have a backup, from one store read.
    func backedUpAccountIds() -> Set<String>

    // Pure, testable serialization — these are what the tests call.
    static func encode(_ store: [String: String]) throws -> Data
    static func decode(_ data: Data) throws -> [String: String]
    /// Never throws: a corrupt item yields an empty store.
    static func decodeLenient(_ data: Data) -> [String: String]
}
```

`encode`/`decode` are `JSONEncoder`/`JSONDecoder` over `[String: String]`. `decodeLenient` is `try? decode(...) ?? [:]` with a `log.warning` on failure. The Keychain read/write bodies mirror `KeychainService.loadBackupStore()` / `saveBackupStore(_:)` — copy their structure, swapping the service constant and the value type, and keep the in-memory cache so repeated reads do not hit the Keychain.

- [ ] **Step 4: Run the test — expect all 5 to pass, and the suite total to rise by 5.**

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Codex/Services/CodexAccountStore.swift CCSwitcherTests/CodexAccountStoreTests.swift
git commit -m "Store per-account Codex credentials in the keychain"
```

---

### Task 2: Codex CLI service

**Files:**
- Create: `CCSwitcher/Codex/Services/CodexCLIService.swift`

No unit test: this forks processes and opens a browser. It is verified by use in Task 5 and by the settings tab in Task 6.

Read `CCSwitcher/Services/ClaudeService.swift` and copy its process-running approach. The parts you need are its private `runClaude(args:)` helper (around line 176), `login()` / `logout()` (around line 719), and `readVersion(at:)` (around line 738). Note especially the **PATH augmentation**: it injects `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` and `~/.npm-global/bin` so an NVM- or Homebrew-installed binary can find `node`. Codex is installed at `/opt/homebrew/bin/codex` on the dev machine, so the same augmentation is required.

- [ ] **Step 1: Implement**

```swift
enum CodexCLIError: LocalizedError {
    case notFound
    case failed(exitCode: Int32, stderr: String)
}

actor CodexCLIService {
    static let shared = CodexCLIService()

    /// User override, else the first hit from the augmented PATH.
    static let binaryPathPreferenceKey = "codexBinaryPathPreference"

    func resolvedBinaryPath() -> String?
    func isAvailable() -> Bool
    /// `codex login` — opens the browser, returns when the process exits.
    func login() async throws
    /// `codex logout`.
    func logout() async throws
    /// `codex login status` — read-only, returns its stdout trimmed.
    func loginStatus() async -> String?
    static func readVersion(at path: String) async -> String?
}
```

Mirror `kClaudeBinaryPathPreferenceKey`'s handling for the override key so the settings tab can point at a non-standard install.

`codex login` with no arguments performs browser OAuth, exactly like `claude auth login`. Verified: `codex login --help` lists only `status` as a subcommand, plus `--with-api-key` and `--with-access-token` stdin variants that this app does not use.

- [ ] **Step 2: Verify by hand, without logging out**

Do **not** call `login()` or `logout()` — that would disturb the user's live session. Verify the read-only parts:

```bash
codex login status
codex --version
which codex
```

Then confirm from your code that `resolvedBinaryPath()` finds the same path `which` reports, and that `loginStatus()` returns the same text. Write a throwaway test for those two, run it, and delete it before committing.

- [ ] **Step 3: Commit**

```bash
git add CCSwitcher/Codex/Services/CodexCLIService.swift
git commit -m "Add Codex CLI service for login and version"
```

---

### Task 3: Atomic auth.json writer

**Files:**
- Create: `CCSwitcher/Codex/Services/CodexAuthWriter.swift`
- Test: `CCSwitcherTests/CodexAuthWriterTests.swift`

This is the only code in the project that writes credentials to a plaintext file. Its tests must run against a temporary directory, **never** against the real `~/.codex`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CCSwitcher

final class CodexAuthWriterTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var target: String { dir.appendingPathComponent("auth.json").path }

    func testWritesContentToANewFile() throws {
        let ok = CodexAuthWriter.write(#"{"a":1}"#, to: target)
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), #"{"a":1}"#)
    }

    func testFileIsOwnerReadWriteOnly() throws {
        XCTAssertTrue(CodexAuthWriter.write("{}", to: target))
        let attrs = try FileManager.default.attributesOfItem(atPath: target)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value
        XCTAssertEqual(perms, 0o600)
    }

    func testOverwriteReplacesContentEntirely() throws {
        XCTAssertTrue(CodexAuthWriter.write(#"{"long":"previous content"}"#, to: target))
        XCTAssertTrue(CodexAuthWriter.write(#"{"s":1}"#, to: target))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), #"{"s":1}"#)
    }

    func testOverwriteKeepsPermissions() throws {
        XCTAssertTrue(CodexAuthWriter.write("{}", to: target))
        XCTAssertTrue(CodexAuthWriter.write(#"{"b":2}"#, to: target))
        let attrs = try FileManager.default.attributesOfItem(atPath: target)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testNoTemporaryFileIsLeftBehind() throws {
        XCTAssertTrue(CodexAuthWriter.write("{}", to: target))
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(contents, ["auth.json"])
    }

    func testWriteToUnwritableDirectoryFails() {
        XCTAssertFalse(CodexAuthWriter.write("{}", to: "/System/nope/auth.json"))
    }

    func testReadReturnsNilForMissingFile() {
        XCTAssertNil(CodexAuthWriter.read(at: dir.appendingPathComponent("absent.json").path))
    }

    func testReadRoundTripsWhatWasWritten() throws {
        XCTAssertTrue(CodexAuthWriter.write(#"{"r":1}"#, to: target))
        XCTAssertEqual(CodexAuthWriter.read(at: target), #"{"r":1}"#)
    }
}
```

- [ ] **Step 2: Run it and see it fail.**

- [ ] **Step 3: Implement**

```swift
enum CodexAuthWriter {
    /// Atomic, owner-only write. Writes a sibling temp file, chmods it to 0600,
    /// then renames over the target — so a crash mid-write can never leave Codex
    /// with a truncated credential file, and the credential is never briefly
    /// world-readable.
    static func write(_ contents: String, to path: String) -> Bool

    static func read(at path: String) -> String?
}
```

Use `FileManager.default.createFile(atPath:contents:attributes:)` with `[.posixPermissions: 0o600]` for the temp file, then `FileManager.default.replaceItemAt(_:withItemAt:)` or `rename(2)` via `FileManager.moveItem` after removing the destination. Whichever you choose, `testNoTemporaryFileIsLeftBehind` and `testOverwriteKeepsPermissions` must both pass — verify rather than assume, because `replaceItemAt` can preserve the *original* file's attributes instead of the new one's.

- [ ] **Step 4: Run the tests — expect all 9 to pass.**

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Codex/Services/CodexAuthWriter.swift CCSwitcherTests/CodexAuthWriterTests.swift
git commit -m "Write Codex credentials atomically with owner-only permissions"
```

---

### Task 4: Codex account registry

**Files:**
- Create: `CCSwitcher/Codex/CodexAccountRegistry.swift`
- Test: `CCSwitcherTests/CodexAccountRegistryTests.swift`

Codex accounts reuse the `Account` struct with `provider == .codex`, but persist under **their own** `UserDefaults` key. A separate key, not the existing array, so `AppState.loadAccounts` and its `first(where: \.isActive)` logic can never see a Codex row.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CCSwitcher

final class CodexAccountRegistryTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "codex-registry-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func account(_ email: String, active: Bool = false) -> Account {
        Account(email: email, displayName: email, provider: .codex, isActive: active)
    }

    func testStartsEmpty() {
        XCTAssertTrue(CodexAccountRegistry.load(from: defaults).isEmpty)
    }

    func testRoundTripsAccounts() {
        let accounts = [account("a@b.c", active: true), account("d@e.f")]
        CodexAccountRegistry.save(accounts, to: defaults)
        let loaded = CodexAccountRegistry.load(from: defaults)
        XCTAssertEqual(loaded.map(\.email), ["a@b.c", "d@e.f"])
        XCTAssertTrue(loaded[0].isActive)
        XCTAssertFalse(loaded[1].isActive)
    }

    func testEveryStoredAccountIsCodex() {
        CodexAccountRegistry.save([account("a@b.c")], to: defaults)
        XCTAssertEqual(CodexAccountRegistry.load(from: defaults).map(\.provider), [.codex])
    }

    /// The Claude key must be untouched — reading or writing it would let Codex
    /// rows leak into `AppState`, which assumes every account is Claude.
    func testDoesNotUseTheClaudeKey() {
        CodexAccountRegistry.save([account("a@b.c")], to: defaults)
        XCTAssertNil(defaults.data(forKey: "com.ccswitcher.accounts"))
        XCTAssertNotNil(defaults.data(forKey: CodexAccountRegistry.storageKey))
    }

    func testMarkActiveMovesTheFlag() {
        let a = account("a@b.c", active: true)
        let b = account("d@e.f")
        let updated = CodexAccountRegistry.markActive(id: b.id, in: [a, b])
        XCTAssertFalse(updated[0].isActive)
        XCTAssertTrue(updated[1].isActive)
    }

    func testMarkActiveWithUnknownIdClearsEveryFlag() {
        let updated = CodexAccountRegistry.markActive(id: UUID(), in: [account("a@b.c", active: true)])
        XCTAssertFalse(updated[0].isActive)
    }

    func testCorruptPayloadLoadsEmptyRatherThanCrashing() {
        defaults.set(Data("garbage".utf8), forKey: CodexAccountRegistry.storageKey)
        XCTAssertTrue(CodexAccountRegistry.load(from: defaults).isEmpty)
    }
}
```

- [ ] **Step 2: Run it and see it fail.**

- [ ] **Step 3: Implement**

```swift
enum CodexAccountRegistry {
    static let storageKey = "com.ccswitcher.accounts.codex"

    static func load(from defaults: UserDefaults = .standard) -> [Account]
    static func save(_ accounts: [Account], to defaults: UserDefaults = .standard)
    /// Returns a copy with exactly the given id active, or none if it is absent.
    static func markActive(id: UUID, in accounts: [Account]) -> [Account]
}
```

`load` decodes `[Account]` and returns `[]` on any failure. `save` encodes with `JSONEncoder`.

- [ ] **Step 4: Run the tests — expect all 7 to pass.**

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Codex/CodexAccountRegistry.swift CCSwitcherTests/CodexAccountRegistryTests.swift
git commit -m "Persist Codex accounts under their own key"
```

---

### Task 5: Wire switching into CodexState

**Files:**
- Modify: `CCSwitcher/Codex/CodexState.swift`

This is the task with real consequences. Read the current file fully before editing.

- [ ] **Step 1: Replace the single synthetic account with the registry**

Stage 2's `CodexState` fabricated one card from whatever `auth.json` held, with `accountId = UUID()` regenerated per launch. Replace that with:

```swift
    @Published private(set) var accounts: [Account] = []
```

loaded via `CodexAccountRegistry.load()` in `init`, and saved via `CodexAccountRegistry.save(accounts)` after every mutation.

`accountCards` and `accountRows` now map over `accounts` — one entry each — using the same obfuscation rule as before. The live snapshot, error and notice belong to the **active** account only; inactive accounts show their last-known snapshot if one exists, else an empty card. Keep a `[UUID: CodexRateLimitSnapshot]` dictionary for that, mirroring `AppState.accountUsage`.

- [ ] **Step 2: Turn the capabilities on**

```swift
    var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            canSwitchAccounts: true,
            canImportCurrent: true,
            canLoginNewAccount: true,
            canReauthenticate: true,
            managesAccounts: true,
            tracksLinesWritten: true
        )
    }
```

- [ ] **Step 3: Implement the actions**

```swift
    func importCurrentAccount() async
    func loginNewAccount() async
    func switchTo(accountId: UUID) async
    func removeAccount(id: UUID)
    func reauthenticate(id: UUID) async
    func setLabel(_ label: String?, forAccount id: UUID)
```

Semantics, each mirroring the Claude flow in `AppState` but simpler because there is one file and no Keychain live slot:

- **`importCurrentAccount`** — read `auth.json`, extract email / `account_id` / plan from the `id_token` claims, refuse if an account with that email already exists, create the `Account`, save the file text to `CodexAccountStore`, mark it active, refresh.
- **`loginNewAccount`** — back up the current `auth.json` to the active account's store entry first, then `CodexCLIService.login()`, then read the new `auth.json` and proceed as `importCurrentAccount`. Set `isAuthenticating` for the duration so the UI blocks.
- **`switchTo`** — guard that the target has a stored backup; back up the live file to the currently-active account (only if the fingerprint still matches that account, see Step 4); write the target's backup with `CodexAuthWriter`; mark the target active; clear the target's cached error; refresh.
- **`removeAccount`** — drop the registry row and the store entry. If it was active, do **not** delete the live `auth.json`; just clear the active flag. Deleting a user's live credentials because they removed a bookkeeping row would be indefensible.
- **`reauthenticate`** — `CodexCLIService.login()`, then require the resulting email to match the target before overwriting its backup.
- **`setLabel`** — update `customLabel`, save.

Every action ends with `CodexAccountRegistry.save(accounts)` and a log line naming the action and the affected email.

- [ ] **Step 4: Add the desync guard**

Before using the live `auth.json`, compare `CodexAuthService.fingerprint(for:)` against the active account's stored backup fingerprint.

**On mismatch, do not restore over the live file.** Unlike Claude's Keychain case, a mismatch here almost always means the user legitimately switched accounts inside Codex Desktop or the CLI. Clobbering that would fight the user. Instead:

- if the live fingerprint matches a *known* account, silently make that account the active one;
- otherwise leave the live file alone and surface a one-line notice on the card: `"Codex is signed in as an account CCSwitcher does not know. Use Add current account to adopt it."`

Add that string via `String(localized:bundle: L10n.bundle)`.

- [ ] **Step 5: Verify**

Build and run the suite; the total must be unchanged from Task 4.

Then verify by hand, in this order, reporting the log lines for each:

1. Take the manual `auth.json` backup described in the Safety Rules and report its path.
2. Open the popover on Codex, Accounts tab. Confirm one row appears with the pencil, trash and (since there is only one account) no Switch button.
3. Use **Add current account**. Confirm the row persists across an app relaunch.
4. Rename it. Confirm the label survives a relaunch.
5. **Do not** run `loginNewAccount` unless the user has a second ChatGPT account to hand — it would log the current session out of Codex. Say in your report that it is unverified and why.
6. Confirm `auth.json`'s mtime is unchanged by everything above except step 3's backup capture, which only reads it.

- [ ] **Step 6: Commit**

```bash
git add CCSwitcher/Codex/CodexState.swift
git commit -m "Switch Codex accounts by swapping the credential file"
```

---

### Task 6: Codex CLI settings tab

**Files:**
- Create: `CCSwitcher/Views/CodexCLITabView.swift`
- Modify: `CCSwitcher/Views/SettingsView.swift`

- [ ] **Step 1: Build the tab by mirroring the Claude one**

Read `CCSwitcher/Views/ClaudeCLITabView.swift` and follow its structure: resolved binary path with an override field, detected version, login status, and an action button. For Codex the fields are:

- Binary path: resolved via `CodexCLIService.resolvedBinaryPath()`, overridable into `CodexCLIService.binaryPathPreferenceKey`.
- Version: `CodexCLIService.readVersion(at:)`.
- Login status: `CodexCLIService.loginStatus()`.
- A **Sign in** button calling `CodexState.loginNewAccount()`, and a **Sign out** button calling `CodexCLIService.logout()`.

Put a plain-language caution next to Sign out: signing out clears the live credentials, and switching back needs a stored backup.

- [ ] **Step 2: Register it in `SettingsView`**

Add after the existing `ClaudeCLITabView()` tab:

```swift
            CodexCLITabView()
                .tabItem {
                    Label("Codex CLI", systemImage: "chevron.left.forwardslash.chevron.right")
                }
```

`CodexCLITabView` needs `CodexState`, which the `Settings` scene must therefore inject. Check `CCSwitcherApp.swift`: the scene currently injects `appState`, `updateChecker`, `menuBarConfig` and `providerHub`. Add `.environmentObject(codexState)`.

- [ ] **Step 3: Verify**

Build, run the suite, then open Settings and confirm the tab shows the real binary path, version `0.145.0` or later, and `Logged in using ChatGPT`. **Do not click Sign out.**

- [ ] **Step 4: Commit**

```bash
git add CCSwitcher/Views/CodexCLITabView.swift CCSwitcher/Views/SettingsView.swift CCSwitcher/CCSwitcherApp.swift
git commit -m "Add Codex CLI settings tab"
```

---

### Task 7: Stage verification

- [ ] **Step 1: Full suite.** Report the total and every class.

- [ ] **Step 2: Confirm every `~/.codex` write goes through the writer.**

```bash
grep -rn "\.codex" CCSwitcher/ | grep -iE "write|create|remove|move|replace"
```

The only write path to `auth.json` must be `CodexAuthWriter`. Explain every hit.

- [ ] **Step 3: Confirm the live file is intact.** `codex login status` must still report `Logged in using ChatGPT`, and `codex --version` must still run.

- [ ] **Step 4: Confirm Claude is untouched.** `Tools/verify_cost.sh` mismatch count unchanged, and Claude account switching still works — **ask the user to confirm the latter rather than switching their accounts yourself.**

- [ ] **Step 5: Report what remains unverified**, specifically multi-account switching if the user has only one ChatGPT account.

---

## Known Limitation Carried Into Stage 4

Codex data refreshes on launch, on provider switch, and on the manual refresh button — but the periodic timer still only drives Claude. Stage 4 addresses that, because menu-bar modules need live Codex numbers without the popover being open.
