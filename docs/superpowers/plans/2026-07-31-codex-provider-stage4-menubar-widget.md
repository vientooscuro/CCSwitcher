# Codex Provider — Stage 4: Menu Bar and Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the always-visible surfaces — the menu-bar strip and the desktop widget — follow the active provider, with per-provider module configuration and live data.

**Architecture:** The strip already renders from `ProviderHub`. This stage generalizes module labels so they describe the actual window rather than the literal strings `5H`/`7D`, stores module selection per provider, adds a module for scoped model limits, teaches `WidgetData` about providers, and puts the active provider on the periodic refresh timer.

**Tech Stack:** Swift 6 (`SWIFT_STRICT_CONCURRENCY: targeted`), SwiftUI, WidgetKit, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-31-codex-provider-design.md`
**Prerequisites:** Stages 1-3 complete.

---

## Ground Rules For Every Task

- `project.yml` is the ONLY source of truth. **Never hand-edit `project.pbxproj` or `Info.plist`.** Run `xcodegen generate` after adding files.
- Standard DerivedData only. No `-derivedDataPath`, never `/tmp`.
- Run `xcodebuild` in the FOREGROUND with a timeout up to 600000 ms.
- Commit messages: ONE imperative line, English, no body, no backticks, **never** `Co-Authored-By`.
- The editor's language server emits spurious `Cannot find X in scope` errors after `xcodegen generate`. Trust `xcodebuild`.

## Two Constraints That Shape Everything Here

1. **The strip is not an ordinary SwiftUI view.** `MenuBarStripView` takes `let hub: ProviderHub` as a plain stored property and re-renders on a 3-second `Timer.publish`, because `ObservableObject` change delivery is unreliable inside the `NSStatusItem` hosting context. Never convert it to `@EnvironmentObject`, and read `hub.theme` directly rather than injecting `\.providerTheme` at its hosting site — an injected value is captured once and would not follow a provider switch.

2. **Existing user configuration must survive.** `MenuBarModuleStore` already has a `migrateIfNeeded()` and decodes resiliently so one unknown raw value cannot wipe the list. Raw values must not change. The dev machine's config is currently an **empty array** (icon only), which is a deliberate user choice — do not "fix" it.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `CCSwitcherTests/MenuBarModuleTests.swift` | Label derivation, per-provider storage, migration |

**Modified:**

| Path | Change |
|---|---|
| `CCSwitcher/Models/MenuBarModule.swift` | Add `scopedLimitBar`; per-provider storage keys |
| `CCSwitcher/Views/MenuBarModuleView.swift` | Derive labels from the window; render scoped limit |
| `CCSwitcher/Views/MenuBarModulesSettingsView.swift` | Provider picker above the module list |
| `Shared/WidgetData.swift` | Provider identity and theme hint |
| `CCSwitcher/AppState.swift` | Widget snapshot gains provider fields |
| `CCSwitcher/Codex/CodexState.swift` | Write the widget snapshot when Codex is active |
| `CCSwitcherWidget/CCSwitcherWidget.swift` | Render the active provider's colours |
| `CCSwitcher/CCSwitcherApp.swift` | Periodic refresh follows the active provider |

---

### Task 1: Generic module labels and the scoped-limit module

**Files:**
- Modify: `CCSwitcher/Models/MenuBarModule.swift`
- Modify: `CCSwitcher/Views/MenuBarModuleView.swift`
- Test: `CCSwitcherTests/MenuBarModuleTests.swift`

Today `compactLabel` returns the literal `"5H"` and `"7D"`. For Codex that is wrong: the account may have only a weekly window, and the session window's length is defined by data. The label must come from the window.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CCSwitcher

final class MenuBarModuleTests: XCTestCase {

    // MARK: - Label derivation

    func testSessionWindowLabelsAsHours() {
        let window = UsageWindowModel(kind: .session, utilization: 5, resetsAt: nil, windowSeconds: 5 * 3600)
        XCTAssertEqual(MenuBarModule.compactLabel(for: window), "5H")
    }

    func testThreeHundredMinuteWindowAlsoLabelsAsFiveHours() {
        let window = UsageWindowModel(kind: .session, utilization: 5, resetsAt: nil, windowSeconds: 300 * 60)
        XCTAssertEqual(MenuBarModule.compactLabel(for: window), "5H")
    }

    func testWeeklyWindowLabelsAsDays() {
        let window = UsageWindowModel(kind: .weekly, utilization: 5, resetsAt: nil, windowSeconds: 604_800)
        XCTAssertEqual(MenuBarModule.compactLabel(for: window), "7D")
    }

    func testNonStandardWindowLabelsFromItsLength() {
        let window = UsageWindowModel(kind: .other(seconds: 30 * 86_400), utilization: 5,
                                      resetsAt: nil, windowSeconds: 30 * 86_400)
        XCTAssertEqual(MenuBarModule.compactLabel(for: window), "30D")
    }

    /// A three-hour session window must not be mislabelled "5H".
    func testThreeHourWindowLabelsAsThreeHours() {
        let window = UsageWindowModel(kind: .session, utilization: 5, resetsAt: nil, windowSeconds: 3 * 3600)
        XCTAssertEqual(MenuBarModule.compactLabel(for: window), "3H")
    }

    // MARK: - Per-provider storage

    func testClaudeKeepsTheLegacyKey() {
        XCTAssertEqual(MenuBarModuleStore.storageKey(for: .claudeCode), "menuBarModules")
    }

    func testCodexUsesItsOwnKey() {
        XCTAssertEqual(MenuBarModuleStore.storageKey(for: .codex), "menuBarModules.codex")
    }

    func testEachProviderGetsADistinctKey() {
        let keys = Set(AIProviderType.allCases.map(MenuBarModuleStore.storageKey(for:)))
        XCTAssertEqual(keys.count, AIProviderType.allCases.count)
    }

    // MARK: - Resilient decoding, unchanged behaviour

    func testUnknownRawValuesAreDroppedNotFatal() throws {
        let data = try JSONEncoder().encode(["account", "notAModule", "weeklyBar"])
        XCTAssertEqual(MenuBarModuleStore.decode(data), [.account, .weeklyBar])
    }

    func testScopedLimitBarDecodes() throws {
        let data = try JSONEncoder().encode(["scopedLimitBar"])
        XCTAssertEqual(MenuBarModuleStore.decode(data), [.scopedLimitBar])
    }

    func testEveryCaseHasADisplayName() {
        for module in MenuBarModule.allCases {
            XCTAssertFalse(module.localizedDisplayName.isEmpty, "\(module) has no display name")
        }
    }
}
```

- [ ] **Step 2: Run it and see it fail.**

- [ ] **Step 3: Implement**

In `MenuBarModule.swift`:

- Add `case scopedLimitBar` to the enum. Its `compactLabel` (the static fallback used when no window is available) is `"MDL"`, and its `localizedDisplayName` is `String(localized: "Model-scoped limit", bundle: L10n.bundle)`.
- Add the window-derived label:

```swift
extension MenuBarModule {
    /// Label for a bar module, derived from the window it renders rather than
    /// hardcoded. Claude always reports 5h and 7d, but Codex defines its windows
    /// by duration and may expose only a weekly one — a literal "5H" would be a
    /// lie there.
    static func compactLabel(for window: UsageWindowModel) -> String {
        let seconds = Int(window.windowSeconds)
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)D" }
        return "\(max(seconds / 3600, 1))H"
    }
}
```

- Replace the single `storageKey` with a per-provider function, keeping Claude on the legacy key so existing configuration is not lost:

```swift
enum MenuBarModuleStore {
    /// Claude keeps the original key so upgrades preserve the user's layout.
    static func storageKey(for provider: AIProviderType) -> String {
        provider == .claudeCode ? "menuBarModules" : "menuBarModules.\(provider.rawValue.lowercased())"
    }
```

`AIProviderType.codex.rawValue` is `"Codex"`, so this yields `menuBarModules.codex`. Keep `migrationKey` and `legacyShowAccountNameKey` as they are, and keep `migrateIfNeeded()` operating on the Claude key only — the migration exists to carry a pre-1.8 Claude preference forward and has no meaning for a provider that did not exist then.

In `MenuBarModuleView.swift`: where a bar module renders its label, call `MenuBarModule.compactLabel(for: window)` when a window is available, falling back to the static `compactLabel` when it is not (no data yet). Add rendering for `scopedLimitBar`, which shows the **first** entry of `activeCard?.scopedLimits` — its utilization as a bar and its label as the model name truncated to four characters, since the strip cannot afford width. When there is no scoped limit, the module renders nothing at all rather than an empty bar.

- [ ] **Step 4: Run the tests — expect all 11 to pass.**

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Models/MenuBarModule.swift CCSwitcher/Views/MenuBarModuleView.swift CCSwitcherTests/MenuBarModuleTests.swift
git commit -m "Derive menu bar labels from the window and add a scoped limit module"
```

---

### Task 2: Per-provider module configuration in settings

**Files:**
- Modify: `CCSwitcher/Views/MenuBarModulesSettingsView.swift`
- Modify: `CCSwitcher/Models/MenuBarConfig.swift`

- [ ] **Step 1: Read both files**

```bash
cat CCSwitcher/Models/MenuBarConfig.swift
cat CCSwitcher/Views/MenuBarModulesSettingsView.swift
```

`MenuBarConfig` is the observable object the strip reads its `modules` from. It currently loads from the single key.

- [ ] **Step 2: Make the config provider-aware**

`MenuBarConfig.modules` must reflect the **active** provider. Give it a `provider` property, defaulting to whatever `ProviderHub` reports active, and reload `modules` from `MenuBarModuleStore.storageKey(for:)` when it changes. `ProviderHub.select(_:)` must tell the config to switch — add that call there.

Keep `MenuBarConfig.shared`: `StatusItemController` and the settings view both use it, and introducing a second instance would silently split state.

- [ ] **Step 3: Add the picker**

Above the existing module list in `MenuBarModulesSettingsView`, add a provider picker built from `hub.available`, shown only when `hub.showsSwitcher` is true so a Claude-only machine sees no change. Selecting a provider edits **that** provider's module list without changing which provider is active in the popover — those are different concerns, and conflating them would mean you cannot configure Codex's strip while looking at Claude.

That means the settings view needs its own selection state, separate from `hub.activeProvider`, and must read and write the corresponding key directly rather than going through `MenuBarConfig.shared`.

- [ ] **Step 4: Verify**

Build, run the suite. Then open Settings, Menu Bar tab: pick Codex, add the session/weekly/scoped modules, and confirm the strip does **not** change while Claude is the active provider. Switch the popover to Codex and confirm the strip now shows those modules within one 3-second tick.

Then switch back to Claude and confirm its strip configuration is exactly as it was — this is the check that proves the legacy key was preserved.

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Models/MenuBarConfig.swift CCSwitcher/Views/MenuBarModulesSettingsView.swift CCSwitcher/Providers/ProviderHub.swift
git commit -m "Configure menu bar modules per provider"
```

---

### Task 3: Periodic refresh follows the active provider

**Files:**
- Modify: `CCSwitcher/CCSwitcherApp.swift`
- Modify: `CCSwitcher/AppState.swift`

This closes the gap Stage 2 left open: the 5-minute timer drives only Claude, so a Codex strip would show numbers frozen at launch.

- [ ] **Step 1: Understand what exists**

`AppState.startAutoRefresh(interval:)` owns a `Timer` that calls `AppState.refresh()`. `AppState.menuDidAppear()` / `menuDidDisappear()` also start and stop it. The strip is always on screen, so the comment in `startAutoRefresh` notes the timer runs unconditionally rather than being gated on the popover.

- [ ] **Step 2: Drive the hub, not just Claude**

The cleanest change that does not move ownership of the timer: keep `AppState`'s timer as the scheduler, and have its tick also refresh the active provider when that is not Claude.

In `CCSwitcherApp`, after `appState.startAutoRefresh(interval: refreshInterval)`, install a second timer that calls `providerHub.refreshActive(force: false)` on the same interval, but **only when the active provider is not Claude** — otherwise Claude would be fetched twice per tick, doubling load on a rate-limited endpoint.

Put that timer on `ProviderHub` rather than in the scene, so it can be cancelled and restarted when `select(_:)` changes the active provider:

```swift
    /// Periodic refresh for the active provider. Claude has its own timer in
    /// `AppState` (it also feeds the widget), so this only runs for other
    /// providers — refreshing Claude here as well would double every fetch
    /// against a rate-limited endpoint.
    func startPeriodicRefresh(interval: TimeInterval)
    func stopPeriodicRefresh()
```

`select(_:)` restarts it. `startPeriodicRefresh` is a no-op while `activeProvider == .claudeCode`.

- [ ] **Step 3: Respect the user's interval setting**

The interval comes from the `refreshInterval` `@AppStorage` key, and `SettingsView` already calls `appState.startAutoRefresh(interval:)` on change. Add the matching `providerHub.startPeriodicRefresh(interval:)` call there so changing the setting affects both.

- [ ] **Step 4: Verify**

Set the refresh interval to 15 seconds in Settings, switch to Codex, and watch the log:

```bash
tail -f ~/Library/Logs/CCSwitcher-app.log | grep -E "CodexUsage|CodexCache"
```

Expect a `fetchLive` roughly every 15 seconds, and `CodexCache` refreshes reporting single-digit reparse counts in tens of milliseconds. Then switch to Claude and confirm Codex fetches **stop** — a provider nobody is looking at must not spend rate-limit budget.

Restore the interval to its previous value afterwards and say in your report what it was.

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Providers/ProviderHub.swift CCSwitcher/CCSwitcherApp.swift CCSwitcher/Views/SettingsView.swift
git commit -m "Refresh the active provider on the periodic timer"
```

---

### Task 4: Provider-aware widget

**Files:**
- Modify: `Shared/WidgetData.swift`
- Modify: `CCSwitcher/AppState.swift`
- Modify: `CCSwitcher/Codex/CodexState.swift`
- Modify: `CCSwitcherWidget/CCSwitcherWidget.swift`

Scheduled last because the widget is the only surface with no in-app fallback if it regresses.

- [ ] **Step 1: Read the current shape**

```bash
cat Shared/WidgetData.swift
grep -n "WidgetData\|WidgetAccountData\|WidgetScopedLimit" CCSwitcher/AppState.swift CCSwitcherWidget/CCSwitcherWidget.swift | head -30
```

`Shared/` is compiled into **both** targets, so any change to `WidgetData` must keep the widget extension compiling.

- [ ] **Step 2: Add provider identity, compatibly**

Add to `WidgetData`:

```swift
    /// Raw value of `AIProviderType`. Optional so a snapshot written by an older
    /// build still decodes — the widget then falls back to Claude styling.
    let provider: String?
```

Give it a default in the initializer so existing call sites keep compiling, and confirm decoding an old snapshot without the key still works. `WidgetData` is `Codable`; an optional added at the end decodes as nil, but **verify** rather than assume, because a custom `init(from:)` would change that.

- [ ] **Step 3: Write the snapshot from whichever provider is active**

`AppState.updateWidgetData()` currently writes unconditionally. That is correct while Claude is active and wrong when Codex is. Move the decision to `ProviderHub`: add

```swift
    /// The active provider owns the widget snapshot. Writing from both would
    /// make the widget flicker between providers on every refresh.
    func updateWidgetSnapshot()
```

which asks the active surface for its data and writes it. Give `ProviderSurface` a `widgetSnapshot: WidgetData` requirement, implemented by `AppState` from its existing code and by `CodexState` from its cards, cost and activity.

Then change `AppState.updateWidgetData()` to return the snapshot instead of writing it, and have the hub write. Keep `AppState`'s existing hash-based "skip reload when unchanged" logic — move it into the hub so it still applies.

- [ ] **Step 4: Style the widget per provider**

In `CCSwitcherWidget.swift`, derive colours from `data.provider`: Claude keeps today's palette; Codex uses the near-black scheme (`#0D0D0D` panel, `#171717` cards, `#2E2E2E` borders, `#ECECEC` / `#9A9A9A` text). Utilization colours stay semantic in both, for the same reason as in the app.

The widget cannot import `ProviderTheme` unless `CCSwitcher/Providers/ProviderTheme.swift` is added to the widget target's sources in `project.yml`. Prefer that over duplicating hex values — but note `ProviderTheme` imports SwiftUI only, so check it has no app-target dependencies before adding it. If it does, duplicate the six colours in the widget with a comment pointing at the source of truth.

- [ ] **Step 5: Verify**

Build both targets. Then add the widget to the desktop if it is not already there, and confirm:

- with Claude active, the widget looks exactly as before;
- switching the popover to Codex changes the widget to the dark scheme and Codex's numbers within one widget refresh;
- the widget shows the Codex plan badge and weekly percentage matching the popover.

Widget timelines refresh on their own schedule, so allow a minute, and use `WidgetCenter.shared.reloadAllTimelines()` (already called on change) to hurry it.

If you cannot get the widget onto the desktop yourself, say so and report exactly what you did verify — a compiling widget target and a correct snapshot on disk is partial but honest.

Inspect the snapshot directly:

```bash
python3 -c "
import json, os, glob
p = glob.glob(os.path.expanduser('~/Library/Group Containers/*.ccswitcher/*'))
print(p)
"
```

- [ ] **Step 6: Commit**

```bash
git add Shared/WidgetData.swift CCSwitcher/AppState.swift CCSwitcher/Codex/CodexState.swift CCSwitcherWidget/CCSwitcherWidget.swift CCSwitcher/Providers/ProviderHub.swift CCSwitcher/Providers/ProviderSurface.swift project.yml
git commit -m "Render the widget for the active provider"
```

---

### Task 5: Stage verification

- [ ] **Step 1: Full suite.** Report the total and every class.

- [ ] **Step 2: Confirm Claude's strip and widget are unchanged.** Compare against `main` the same way Stage 1's Task 14 did: build both, screenshot the strip and the widget, compare. The switcher in the popover header is the only sanctioned addition.

- [ ] **Step 3: Confirm the user's module configuration survived.**

```bash
defaults read com.vientooscuro.ccswitcher menuBarModules
defaults read com.vientooscuro.ccswitcher menuBarModules.codex
```

The Claude key must hold whatever it held before this stage. Report both values.

- [ ] **Step 4: Confirm no double-fetching.** With Claude active, the log must show one Claude `getUsageLimits` pair per interval and **no** `CodexUsage fetchLive`. With Codex active, the reverse for the Codex fetch — Claude may still fetch, because its timer also feeds nothing else, and say plainly whether it does.

- [ ] **Step 5: Report what remains unverified.**

---

## After This Stage

The feature is complete as specified: both providers, switching for each, per-provider menu bar, and a provider-aware widget. Remaining known gaps, none of them in scope:

- Gemini is designed for but not implemented. Adding it is one `ProviderSurface`, one theme, and one registry entry.
- Codex `activeMinutes` sums parallel sessions rather than deduplicating overlap, matching the Claude approximation.
- `verify_cost.sh` reports six pre-existing `cache_creation_tokens` mismatches on Claude rows, unrelated to this work and documented in `COST_VERIFICATION.md`.
