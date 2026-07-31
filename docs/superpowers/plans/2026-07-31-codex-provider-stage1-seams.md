# Codex Provider — Stage 1: Provider Seams Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a provider abstraction (registry, surface protocol, normalized display models, per-provider theme) and migrate the existing Claude UI onto it, with zero visible change to the app.

**Architecture:** `AppState` keeps all Claude logic untouched and gains a thin `ProviderSurface` conformance that maps its data into normalized display models. A concrete `ProviderHub` owns the surfaces and is the single `EnvironmentObject` views observe. Views stop reading Claude-specific types and render display models plus an `Environment` theme.

**Tech Stack:** Swift 6 (`SWIFT_STRICT_CONCURRENCY: targeted`), SwiftUI, macOS 14 deployment, XcodeGen 2.46 (`project.yml` is the only source of truth), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-31-codex-provider-design.md`

---

## Ground Rules For Every Task

- **Never edit `CCSwitcher.xcodeproj/project.pbxproj` or `Info.plist` directly.** Change `project.yml`, then run `xcodegen generate`.
- After adding any new `.swift` file under `CCSwitcher/`, run `xcodegen generate` before building — the target globs a path, but Xcode needs the regenerated project to see new files.
- Build check: `xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5`
- Test check: `xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/<TestClass> 2>&1 | tail -20`
- Use the standard DerivedData location. Do **not** pass `-derivedDataPath`, and never build into `/tmp`.
- Commit messages: one imperative line, English, no body, no backticks, no `Co-Authored-By`.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `CCSwitcherTests/Info.plist` — *not needed*, `GENERATE_INFOPLIST_FILE` is used | — |
| `CCSwitcher/Providers/Display/UsageWindowModel.swift` | Window kind, classification, formatting helpers |
| `CCSwitcher/Providers/Display/UsageCardModel.swift` | Usage-tab card: windows, scoped limits, credits, error |
| `CCSwitcher/Providers/Display/AccountModels.swift` | `AccountHeaderModel`, `AccountRowModel` |
| `CCSwitcher/Providers/Display/ActivitySummaryModel.swift` | Turns, active time, lines, per-model entries |
| `CCSwitcher/Providers/Display/CostSeriesModel.swift` | Today cost + daily series |
| `CCSwitcher/Providers/ProviderSurface.swift` | The protocol every provider satisfies + capabilities |
| `CCSwitcher/Providers/ProviderTheme.swift` | Theme tokens, Claude theme, `Environment` key |
| `CCSwitcher/Providers/ProviderRegistry.swift` | Which providers exist on this machine |
| `CCSwitcher/Providers/ProviderHub.swift` | Owns surfaces, publishes active provider, forwards changes |
| `CCSwitcher/Claude/ClaudeDisplayMapper.swift` | Pure Claude → display-model mapping (the tested part) |
| `CCSwitcher/Claude/ClaudeProviderSurface.swift` | `extension AppState: ProviderSurface` |
| `CCSwitcherTests/UsageWindowModelTests.swift` | Window classification and formatting |
| `CCSwitcherTests/ClaudeDisplayMapperTests.swift` | Claude mapping, proving numbers did not change |
| `CCSwitcherTests/ProviderRegistryTests.swift` | Detection and active-provider fallback |

**Modified:**

| Path | Change |
|---|---|
| `project.yml` | Add `CCSwitcherTests` target and an explicit `schemes:` block |
| `CCSwitcher/CCSwitcherApp.swift` | Build the hub, inject it |
| `CCSwitcher/Services/StatusItemController.swift` | Accept the hub alongside `AppState` |
| `CCSwitcher/Views/UsageDashboardView.swift` | Render display models + theme |
| `CCSwitcher/Views/CostDetailView.swift` | Render `CostSeriesModel` |
| `CCSwitcher/Views/AccountSwitcherView.swift` | Render `AccountRowModel`, call surface actions |
| `CCSwitcher/Views/MenuBarModuleView.swift` | Read windows from the surface |
| `CCSwitcher/Views/MainMenuView.swift` | Header/footer read the surface; theme applied |

---

### Task 1: Test target

**Files:**
- Modify: `project.yml`
- Create: `CCSwitcherTests/SmokeTests.swift`

- [ ] **Step 1: Add the test target and scheme to `project.yml`**

Append to the `targets:` mapping (after the `CCSwitcherWidgetExtension` block, same indentation as the other two targets):

```yaml
  CCSwitcherTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: CCSwitcherTests
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.vientooscuro.ccswitcher.tests
        GENERATE_INFOPLIST_FILE: true
        SWIFT_VERSION: "6.0"
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: XTPJK8U436
        SWIFT_STRICT_CONCURRENCY: targeted
    dependencies:
      - target: CCSwitcher
```

Then add a top-level `schemes:` block at the end of the file (column 0, sibling of `targets:`). Without it the generated scheme has no test action and `xcodebuild test` fails with "Scheme CCSwitcher is not currently configured for the test action":

```yaml
schemes:
  CCSwitcher:
    build:
      targets:
        CCSwitcher: all
    run:
      config: Debug
    test:
      config: Debug
      gatherCoverageData: false
      targets:
        - CCSwitcherTests
```

- [ ] **Step 2: Write a smoke test**

Create `CCSwitcherTests/SmokeTests.swift`:

```swift
import XCTest

final class SmokeTests: XCTestCase {
    func testTestTargetRuns() {
        XCTAssertEqual(1 + 1, 2)
    }
}
```

- [ ] **Step 3: Generate and run**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/SmokeTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`.

If it fails with a code-signing error on the test bundle, add `CODE_SIGNING_ALLOWED: false` under the test target's `settings.base` and re-run. Do not disable signing on the app target.

- [ ] **Step 4: Commit**

```bash
git add project.yml CCSwitcherTests/SmokeTests.swift
git commit -m "Add unit test target"
```

---

### Task 2: Usage window model and classification

**Files:**
- Create: `CCSwitcher/Providers/Display/UsageWindowModel.swift`
- Test: `CCSwitcherTests/UsageWindowModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `CCSwitcherTests/UsageWindowModelTests.swift`:

```swift
import XCTest
@testable import CCSwitcher

final class UsageWindowModelTests: XCTestCase {
    func testFiveHourWindowClassifiesAsSession() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 5 * 3600), .session)
    }

    func testThreeHundredMinuteCodexWindowClassifiesAsSession() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 300 * 60), .session)
    }

    func testSevenDayWindowClassifiesAsWeekly() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 604_800), .weekly)
    }

    func testTenThousandEightyMinuteCodexWindowClassifiesAsWeekly() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 10_080 * 60), .weekly)
    }

    func testMonthlyWindowClassifiesAsOther() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 30 * 86_400), .other(seconds: 30 * 86_400))
    }

    func testBoundaryAtSixHoursIsSession() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 6 * 3600), .session)
    }

    func testJustOverSixHoursIsWeekly() {
        XCTAssertEqual(UsageWindowModel.Kind(windowSeconds: 6 * 3600 + 1), .weekly)
    }

    func testElapsedPercentIsHalfwayThroughWindow() {
        let window = UsageWindowModel(
            kind: .session,
            utilization: 10,
            resetsAt: Date().addingTimeInterval(2.5 * 3600),
            windowSeconds: 5 * 3600
        )
        let elapsed = window.elapsedPercent
        XCTAssertNotNil(elapsed)
        XCTAssertEqual(elapsed!, 50, accuracy: 1)
    }

    func testElapsedPercentIsNilWithoutResetDate() {
        let window = UsageWindowModel(kind: .weekly, utilization: 10, resetsAt: nil, windowSeconds: 604_800)
        XCTAssertNil(window.elapsedPercent)
    }

    func testElapsedPercentClampsWhenResetIsInThePast() {
        let window = UsageWindowModel(
            kind: .session,
            utilization: 10,
            resetsAt: Date().addingTimeInterval(-3600),
            windowSeconds: 5 * 3600
        )
        XCTAssertEqual(window.elapsedPercent!, 100, accuracy: 0.001)
    }

    func testResetTextUsesMinutesUnderAnHour() {
        let text = UsageWindowFormat.resetText(until: Date().addingTimeInterval(25 * 60))
        XCTAssertEqual(text, "25 min")
    }

    func testResetTextUsesHoursAndMinutes() {
        let text = UsageWindowFormat.resetText(until: Date().addingTimeInterval(2 * 3600 + 14 * 60))
        XCTAssertEqual(text, "2 hr 14 min")
    }

    func testResetTextIsNowWhenElapsed() {
        XCTAssertEqual(UsageWindowFormat.resetText(until: Date().addingTimeInterval(-5)), "now")
    }

    func testCompactResetTextUsesDaysAndHours() {
        let text = UsageWindowFormat.compactResetText(until: Date().addingTimeInterval(4 * 86_400 + 6 * 3600))
        XCTAssertEqual(text, "4d 6h")
    }

    func testDurationTextForNonStandardWindow() {
        XCTAssertEqual(UsageWindowFormat.durationText(seconds: 30 * 86_400), "30d")
        XCTAssertEqual(UsageWindowFormat.durationText(seconds: 3 * 3600), "3h")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/UsageWindowModelTests 2>&1 | tail -20
```

Expected: compile failure, `cannot find 'UsageWindowModel' in scope`.

- [ ] **Step 3: Write the implementation**

Create `CCSwitcher/Providers/Display/UsageWindowModel.swift`:

```swift
import Foundation

/// One rate-limit window, normalized across providers.
///
/// Providers do not agree on how windows are named. Claude's usage payload has
/// fixed `five_hour` / `seven_day` fields; Codex returns `primary_window` /
/// `secondary_window` whose meaning is defined only by `limit_window_seconds`
/// (the 5-hour window has been observed in either slot). Classifying by
/// duration is therefore the only correct shared representation.
struct UsageWindowModel: Identifiable {
    enum Kind: Equatable {
        case session
        case weekly
        case other(seconds: Double)

        /// `<= 6h` is a session window, up to 8 days is a weekly window, and
        /// anything longer keeps its raw length for display. The slack on both
        /// sides absorbs provider rounding without mislabelling a window.
        init(windowSeconds: Double) {
            if windowSeconds <= 6 * 3600 {
                self = .session
            } else if windowSeconds <= 8 * 86_400 {
                self = .weekly
            } else {
                self = .other(seconds: windowSeconds)
            }
        }
    }

    let kind: Kind
    /// 0-100.
    let utilization: Double
    let resetsAt: Date?
    let windowSeconds: Double

    var id: String {
        switch kind {
        case .session: return "session"
        case .weekly: return "weekly"
        case .other(let s): return "other-\(Int(s))"
        }
    }

    /// How much of the window has already elapsed, 0-100. Compared against
    /// `utilization` this shows whether the user is burning quota faster or
    /// slower than the clock. Nil when the provider gave no reset timestamp.
    var elapsedPercent: Double? {
        guard windowSeconds > 0, let resetsAt else { return nil }
        let fraction = 1.0 - (resetsAt.timeIntervalSinceNow / windowSeconds)
        return min(max(fraction, 0), 1) * 100
    }
}

/// Text rendering for windows. Kept out of the model so the model stays
/// `Sendable`-friendly plain data and so the view layer owns presentation.
enum UsageWindowFormat {
    /// Long form used in the popover: "now", "25 min", "2 hr 14 min", or an
    /// absolute weekday-time beyond 24 hours ("Tue 9:00 AM").
    static func resetText(until date: Date?) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "now" }

        // Round rather than truncate: the wall-clock time elapsed between the
        // caller computing `date` and this call always makes `remaining`
        // slightly less than intended, which truncation would round down.
        let totalSeconds = Int(remaining.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 24 { return Formatters.weekdayTime.string(from: date) }
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        return "\(minutes) min"
    }

    /// Fixed-shape short form for the menu bar, which cannot afford width:
    /// "now", "5m", "2h 14m", "4d 6h". Never returns an absolute date.
    static func compactResetText(until date: Date?) -> String? {
        guard let date else { return nil }
        let raw = date.timeIntervalSinceNow
        guard raw > 0 else { return "now" }
        // Rounded for the same reason as `resetText`.
        let remaining = Int(raw.rounded())

        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3600
        let minutes = (remaining % 3600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    /// Length of a non-standard window, for `.other` labels.
    static func durationText(seconds: Double) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        if days > 0 { return "\(days)d" }
        let hours = total / 3600
        if hours > 0 { return "\(hours)h" }
        return "\(max(total / 60, 1))m"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/UsageWindowModelTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 15 tests.

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Providers/Display/UsageWindowModel.swift CCSwitcherTests/UsageWindowModelTests.swift
git commit -m "Add provider-agnostic usage window model"
```

---

### Task 3: Remaining display models

No tests here — these are plain data declarations with no behaviour. They get exercised by Task 5's mapper tests.

**Files:**
- Create: `CCSwitcher/Providers/Display/UsageCardModel.swift`
- Create: `CCSwitcher/Providers/Display/AccountModels.swift`
- Create: `CCSwitcher/Providers/Display/ActivitySummaryModel.swift`
- Create: `CCSwitcher/Providers/Display/CostSeriesModel.swift`

- [ ] **Step 1: Create `UsageCardModel.swift`**

```swift
import SwiftUI

/// A rate limit that applies to one specific model rather than the account as a
/// whole — Claude's scoped weekly limits (e.g. Fable 5) and Codex's
/// `additional_rate_limits` entries (e.g. GPT-5.3-Codex-Spark).
struct ScopedLimitModel: Identifiable {
    let modelName: String
    let utilization: Double
    let resetsAt: Date?
    /// Supplied by the provider. A shared name-to-color switch would be wrong:
    /// the Claude palette keys off Fable/Opus/Sonnet/Haiku, which say nothing
    /// about `gpt-5.6-sol`.
    let tint: Color

    var id: String { modelName }
}

/// Pay-as-you-go pool beyond the subscription: Claude's `extra_usage`,
/// Codex's `credits`.
struct CreditPoolModel {
    let isEnabled: Bool
    let isUnlimited: Bool
    /// Pre-formatted by the provider, because the units differ (dollars vs credits).
    let balanceText: String?
    let utilization: Double?
}

struct ProviderErrorModel {
    let message: String
    /// Drives the "re-authenticate" affordance and the warning icon.
    let needsReauth: Bool
    /// A rate limit blocks refreshes but does not invalidate numbers already
    /// fetched, so the card keeps showing them alongside the message.
    let isRateLimited: Bool
}

/// One account card on the Usage tab.
struct UsageCardModel: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String?
    let planBadge: String?
    let isActive: Bool
    let windows: [UsageWindowModel]
    let scopedLimits: [ScopedLimitModel]
    let credits: CreditPoolModel?
    /// Provider-level notice that is not an error: spend control reached,
    /// limit-reached type, stale local snapshot.
    let notice: String?
    let error: ProviderErrorModel?

    /// True when there is nothing to draw but also no explanation — the
    /// "refresh to fetch" state.
    var isEmpty: Bool {
        windows.isEmpty && scopedLimits.isEmpty && credits == nil && error == nil
    }
}
```

- [ ] **Step 2: Create `AccountModels.swift`**

```swift
import Foundation

/// Identity block shown in the popover header for the active account.
struct AccountHeaderModel {
    let title: String
    let subtitle: String
    let planBadge: String?
}

/// One row on the Accounts tab.
struct AccountRowModel: Identifiable {
    let id: UUID
    let title: String
    let email: String
    let planBadge: String?
    let isActive: Bool
    let lastUsedText: String?
    /// False when switching to this account would fail for lack of stored
    /// credentials — the row shows a re-authenticate prompt instead.
    let hasStoredCredentials: Bool
    /// Seeds the inline rename field. Nil when no custom label is set.
    let rawLabel: String?
}
```

- [ ] **Step 3: Create `ActivitySummaryModel.swift`**

```swift
import SwiftUI

struct ModelUsageEntry: Identifiable {
    let displayName: String
    let count: Int
    let tint: Color

    var id: String { displayName }
}

struct ActivitySummaryModel {
    let turns: Int
    /// Pre-formatted ("4h 38m") because providers compute it differently.
    let activeTimeText: String
    /// Nil when the provider cannot measure edited lines; the view hides the stat.
    let linesWritten: Int?
    let perModel: [ModelUsageEntry]

    static let empty = ActivitySummaryModel(turns: 0, activeTimeText: "0m", linesWritten: nil, perModel: [])
}
```

- [ ] **Step 4: Create `CostSeriesModel.swift`**

```swift
import Foundation

struct DailyCostEntry: Identifiable {
    /// "yyyy-MM-dd".
    let date: String
    let cost: Double
    /// Nil when the provider cannot count sessions; the view hides the label.
    /// Claude counts JSONL session files, Codex counts rollout files.
    let sessionCount: Int?
    let modelBreakdown: [String: Double]
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int

    var id: String { date }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
    }
}

struct CostSeriesModel {
    let todayCost: Double
    let daily: [DailyCostEntry]

    var totalCost: Double { daily.reduce(0) { $0 + $1.cost } }

    static let empty = CostSeriesModel(todayCost: 0, daily: [])
}
```

- [ ] **Step 5: Verify it builds**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add CCSwitcher/Providers/Display
git commit -m "Add normalized provider display models"
```

---

### Task 4: ProviderSurface protocol and theme

**Files:**
- Create: `CCSwitcher/Providers/ProviderSurface.swift`
- Create: `CCSwitcher/Providers/ProviderTheme.swift`

- [ ] **Step 1: Create `ProviderSurface.swift`**

```swift
import Foundation

/// What a provider can actually do. Views hide affordances rather than calling
/// methods that silently no-op — Codex ships read-only in stage 2 and gains
/// switching in stage 3, and the UI must follow without edits.
struct ProviderCapabilities {
    let canSwitchAccounts: Bool
    let canImportCurrent: Bool
    let canLoginNewAccount: Bool
    let canReauthenticate: Bool
    /// Whether the provider owns its account list at all. False for a read-only
    /// provider, which must not offer rename or remove either.
    let managesAccounts: Bool
    let tracksLinesWritten: Bool

    static let claude = ProviderCapabilities(
        canSwitchAccounts: true,
        canImportCurrent: true,
        canLoginNewAccount: true,
        canReauthenticate: true,
        managesAccounts: true,
        tracksLinesWritten: true
    )
}

/// Everything the popover asks of a provider. Implemented by `AppState` for
/// Claude and by `CodexState` for Codex.
@MainActor
protocol ProviderSurface: AnyObject, ObservableObject {
    var providerType: AIProviderType { get }
    /// The provider's CLI or config was found on this machine.
    var isAvailable: Bool { get }
    var isLoading: Bool { get }
    /// A browser OAuth round trip is in flight; the UI blocks account actions.
    var isAuthenticating: Bool { get }
    var errorMessage: String? { get }
    var lastRefresh: Date? { get }
    var capabilities: ProviderCapabilities { get }

    var header: AccountHeaderModel? { get }
    var accountCards: [UsageCardModel] { get }
    var accountRows: [AccountRowModel] { get }
    var activity: ActivitySummaryModel { get }
    var cost: CostSeriesModel { get }

    func refresh(force: Bool) async
    func switchTo(accountId: UUID) async
    /// Adopt whichever account the provider's CLI is already signed in as.
    func importCurrentAccount() async
    /// Run a browser OAuth flow and add the result as a new account.
    func loginNewAccount() async
    func removeAccount(id: UUID)
    func reauthenticate(id: UUID) async
    func setLabel(_ label: String?, forAccount id: UUID)
}
```

- [ ] **Step 2: Create `ProviderTheme.swift`**

The Claude values are lifted verbatim from `BrandColor.swift` so nothing shifts visually.

```swift
import SwiftUI

/// Per-provider visual tokens. Injected through `Environment` so shared
/// components restyle without knowing which provider is active.
struct ProviderTheme {
    enum Panel {
        case material(Material)
        case flat(Color)
    }

    let panel: Panel
    let accent: Color
    let accentForeground: Color
    let cardFill: Color
    let cardFillStrong: Color
    let cardBorder: Color
    let textPrimary: Color
    let textSecondary: Color
    let tabFill: Color
    let tabBorder: Color
    let tabSelectedFill: Color
    let tabSelectedForeground: Color
    let progressTrack: Color
    let subtleAccent: Color
    /// Forced appearance. Nil means follow the system, which is what Claude does.
    let forcedColorScheme: ColorScheme?

    /// Utilization ramp. Kept semantic in every theme: a monochrome bar makes
    /// the number unreadable at a glance, which defeats the point of the bar.
    func utilizationColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 60 { return .orange }
        return .green
    }
}

extension ProviderTheme {
    /// Today's look, unchanged.
    static let claude = ProviderTheme(
        panel: .material(.ultraThinMaterial),
        accent: .brand,
        accentForeground: .white,
        cardFill: .cardFill,
        cardFillStrong: .cardFillStrong,
        cardBorder: .cardBorder,
        textPrimary: .textPrimary,
        textSecondary: .textSecondary,
        tabFill: .tabFill,
        tabBorder: .tabBorder,
        tabSelectedFill: .brand,
        tabSelectedForeground: .white,
        progressTrack: .progressTrack,
        subtleAccent: .subtleBrand,
        forcedColorScheme: nil
    )

    static func theme(for provider: AIProviderType) -> ProviderTheme {
        switch provider {
        case .claudeCode: return .claude
        case .codex: return .claude   // replaced by the Codex theme in stage 2
        case .gemini: return .claude
        }
    }
}

private struct ProviderThemeKey: EnvironmentKey {
    static let defaultValue: ProviderTheme = .claude
}

extension EnvironmentValues {
    var providerTheme: ProviderTheme {
        get { self[ProviderThemeKey.self] }
        set { self[ProviderThemeKey.self] = newValue }
    }
}
```

- [ ] **Step 3: Verify it builds**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add CCSwitcher/Providers/ProviderSurface.swift CCSwitcher/Providers/ProviderTheme.swift
git commit -m "Add provider surface protocol and theme tokens"
```

---

### Task 5: Claude display mapper

This is the safety net for the whole stage: it pins the exact numbers the current build shows, so the view migration cannot silently change them.

**Files:**
- Create: `CCSwitcher/Claude/ClaudeDisplayMapper.swift`
- Test: `CCSwitcherTests/ClaudeDisplayMapperTests.swift`

- [ ] **Step 1: Write the failing test**

Create `CCSwitcherTests/ClaudeDisplayMapperTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import CCSwitcher

final class ClaudeDisplayMapperTests: XCTestCase {

    /// Shape returned by /api/oauth/usage: fixed session and weekly windows,
    /// a model-scoped weekly limit, and the extra-usage pool.
    private func decodeUsage(_ json: String) throws -> UsageAPIResponse {
        try JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
    }

    private let fullUsageJSON = """
    {
      "five_hour": { "utilization": 65, "resets_at": "2026-07-31T14:00:00.000Z" },
      "seven_day": { "utilization": 34, "resets_at": "2026-08-04T13:59:00.000Z" },
      "extra_usage": { "is_enabled": false, "monthly_limit": 100, "used_credits": 0, "utilization": 0 },
      "limits": [
        { "kind": "session", "percent": 65, "resets_at": "2026-07-31T14:00:00.000Z" },
        { "kind": "weekly_all", "percent": 34, "resets_at": "2026-08-04T13:59:00.000Z" },
        { "kind": "weekly_scoped", "percent": 5, "resets_at": "2026-08-04T14:00:00.000Z",
          "scope": { "model": { "id": "claude-fable-5", "display_name": "Fable" } } }
      ]
    }
    """

    private func account(active: Bool = true, label: String? = nil) -> Account {
        Account(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            email: "dan@gradient.photo",
            displayName: "Gradient",
            provider: .claudeCode,
            orgName: "Gradient",
            subscriptionType: "team",
            isActive: active,
            lastUsed: nil,
            customLabel: label
        )
    }

    func testWindowsAreSessionThenWeekly() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let windows = ClaudeDisplayMapper.windows(from: usage)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].kind, .session)
        XCTAssertEqual(windows[0].utilization, 65)
        XCTAssertEqual(windows[0].windowSeconds, 5 * 3600)
        XCTAssertEqual(windows[1].kind, .weekly)
        XCTAssertEqual(windows[1].utilization, 34)
        XCTAssertEqual(windows[1].windowSeconds, 7 * 86_400)
    }

    func testMissingWindowsAreOmittedRatherThanZeroed() throws {
        let usage = try decodeUsage(#"{ "seven_day": { "utilization": 12, "resets_at": null } }"#)
        let windows = ClaudeDisplayMapper.windows(from: usage)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].kind, .weekly)
        XCTAssertNil(windows[0].resetsAt)
    }

    func testScopedLimitIsMappedWithModelTint() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let scoped = ClaudeDisplayMapper.scopedLimits(from: usage)
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped[0].modelName, "Fable")
        XCTAssertEqual(scoped[0].utilization, 5)
        XCTAssertEqual(scoped[0].tint, Color.purple)
    }

    func testExtraUsageBecomesDisabledCreditPool() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let credits = ClaudeDisplayMapper.credits(from: usage)
        XCTAssertNotNil(credits)
        XCTAssertFalse(credits!.isEnabled)
        XCTAssertFalse(credits!.isUnlimited)
    }

    func testAbsentExtraUsageYieldsNoCreditPool() throws {
        let usage = try decodeUsage(#"{ "five_hour": { "utilization": 1, "resets_at": null } }"#)
        XCTAssertNil(ClaudeDisplayMapper.credits(from: usage))
    }

    func testCardObfuscatesEmailWhenRequested() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let card = ClaudeDisplayMapper.card(account: account(), usage: usage, error: nil, obfuscate: true)
        XCTAssertEqual(card.subtitle, "dan@gradient.photo".obfuscatedEmail())
        XCTAssertNotEqual(card.subtitle, "dan@gradient.photo")
    }

    func testCardShowsFullEmailWhenNotObfuscating() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let card = ClaudeDisplayMapper.card(account: account(), usage: usage, error: nil, obfuscate: false)
        XCTAssertEqual(card.subtitle, "dan@gradient.photo")
    }

    func testCardCapitalizesSubscriptionBadge() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let card = ClaudeDisplayMapper.card(account: account(), usage: usage, error: nil, obfuscate: false)
        XCTAssertEqual(card.planBadge, "Team")
    }

    func testCardWithoutUsageAndWithoutErrorIsEmpty() {
        let card = ClaudeDisplayMapper.card(account: account(), usage: nil, error: nil, obfuscate: false)
        XCTAssertTrue(card.isEmpty)
        XCTAssertTrue(card.windows.isEmpty)
    }

    func testCardCarriesErrorWhenPresent() {
        let error = ProviderErrorModel(message: "Session expired.", needsReauth: true, isRateLimited: false)
        let card = ClaudeDisplayMapper.card(account: account(), usage: nil, error: error, obfuscate: false)
        XCTAssertFalse(card.isEmpty)
        XCTAssertEqual(card.error?.message, "Session expired.")
        XCTAssertTrue(card.error!.needsReauth)
    }

    func testRateLimitedCardKeepsPreviouslyFetchedWindows() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let error = ProviderErrorModel(message: "API rate-limited.", needsReauth: false, isRateLimited: true)
        let card = ClaudeDisplayMapper.card(account: account(), usage: usage, error: error, obfuscate: false)
        XCTAssertEqual(card.windows.count, 2)
        XCTAssertTrue(card.error!.isRateLimited)
    }

    func testCustomLabelWinsOverDisplayName() throws {
        let usage = try decodeUsage(fullUsageJSON)
        let card = ClaudeDisplayMapper.card(account: account(label: "Work"), usage: usage, error: nil, obfuscate: true)
        XCTAssertEqual(card.title, "Work")
    }

    func testActivityMapsAllFourClaudeModelsInFixedOrder() {
        var stats = ActivityStats()
        stats.conversationTurns = 37
        stats.activeCodingMinutes = 278
        stats.linesWritten = 2396
        stats.modelUsage = ["Opus": 611, "Sonnet": 0]

        let model = ClaudeDisplayMapper.activity(stats)
        XCTAssertEqual(model.turns, 37)
        XCTAssertEqual(model.activeTimeText, "4h 38m")
        XCTAssertEqual(model.linesWritten, 2396)
        XCTAssertEqual(model.perModel.map(\.displayName), ["Fable", "Opus", "Sonnet", "Haiku"])
        XCTAssertEqual(model.perModel.map(\.count), [0, 611, 0, 0])
    }

    func testCostMapsTodayAndDailySeries() {
        let summary = CostSummary(
            todayCost: 319.57,
            dailyCosts: [
                DailyCost(date: "2026-07-31", totalCost: 319.57, modelBreakdown: ["claude-opus-4-8": 319.57],
                          sessionCount: 3, inputTokens: 10, outputTokens: 20,
                          cacheWriteTokens: 30, cacheReadTokens: 40)
            ]
        )
        let model = ClaudeDisplayMapper.cost(summary)
        XCTAssertEqual(model.todayCost, 319.57, accuracy: 0.0001)
        XCTAssertEqual(model.daily.count, 1)
        XCTAssertEqual(model.daily[0].totalTokens, 100)
        XCTAssertEqual(model.totalCost, 319.57, accuracy: 0.0001)
    }

    func testHeaderUsesEffectiveNameAndBadge() {
        let header = ClaudeDisplayMapper.header(account: account(label: "Work"), obfuscate: true)
        XCTAssertEqual(header.title, "Work")
        XCTAssertEqual(header.planBadge, "Team")
    }

    func testRowReportsMissingCredentials() {
        let row = ClaudeDisplayMapper.row(account: account(), hasStoredCredentials: false, obfuscate: false)
        XCTAssertFalse(row.hasStoredCredentials)
        XCTAssertEqual(row.email, "dan@gradient.photo")
        XCTAssertTrue(row.isActive)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/ClaudeDisplayMapperTests 2>&1 | tail -20
```

Expected: compile failure, `cannot find 'ClaudeDisplayMapper' in scope`.

- [ ] **Step 3: Write the implementation**

Create `CCSwitcher/Claude/ClaudeDisplayMapper.swift`:

```swift
import SwiftUI

/// Pure Claude-to-display-model mapping. Deliberately free of `AppState` and of
/// any actor isolation so it can be unit-tested without forking the CLI, and so
/// the numbers the UI shows are pinned by tests.
enum ClaudeDisplayMapper {

    /// Fixed order matching today's UI: the four Claude tiers always render,
    /// including zeros, because a disappearing column reads as a bug.
    static let modelOrder = ["Fable", "Opus", "Sonnet", "Haiku"]

    static func tint(forModel name: String) -> Color {
        switch name {
        case "Fable": return .purple
        case "Opus": return .brand
        case "Sonnet": return .blue
        case "Haiku": return .green
        default: return .gray
        }
    }

    static func windows(from usage: UsageAPIResponse) -> [UsageWindowModel] {
        var result: [UsageWindowModel] = []
        if let session = usage.fiveHour {
            result.append(UsageWindowModel(
                kind: .session,
                utilization: session.utilization ?? 0,
                resetsAt: session.resetsAtDate,
                windowSeconds: RateLimitWindow.fiveHourSeconds
            ))
        }
        if let weekly = usage.sevenDay {
            result.append(UsageWindowModel(
                kind: .weekly,
                utilization: weekly.utilization ?? 0,
                resetsAt: weekly.resetsAtDate,
                windowSeconds: RateLimitWindow.sevenDaySeconds
            ))
        }
        return result
    }

    static func scopedLimits(from usage: UsageAPIResponse) -> [ScopedLimitModel] {
        (usage.limits ?? []).compactMap { limit in
            guard limit.kind == "weekly_scoped",
                  let name = limit.scope?.model?.displayName else { return nil }
            return ScopedLimitModel(
                modelName: name,
                utilization: limit.percent ?? 0,
                resetsAt: UsageWindow(utilization: limit.percent, resetsAt: limit.resetsAt).resetsAtDate,
                tint: tint(forModel: name)
            )
        }
    }

    static func credits(from usage: UsageAPIResponse) -> CreditPoolModel? {
        guard let extra = usage.extraUsage else { return nil }
        return CreditPoolModel(
            isEnabled: extra.isEnabled == true,
            isUnlimited: false,
            balanceText: nil,
            utilization: extra.utilization
        )
    }

    static func card(
        account: Account,
        usage: UsageAPIResponse?,
        error: ProviderErrorModel?,
        obfuscate: Bool
    ) -> UsageCardModel {
        UsageCardModel(
            id: account.id,
            title: account.effectiveDisplayName(obfuscated: obfuscate),
            subtitle: account.displayEmail(obfuscated: obfuscate),
            planBadge: account.displaySubscriptionType,
            isActive: account.isActive,
            windows: usage.map(windows(from:)) ?? [],
            scopedLimits: usage.map(scopedLimits(from:)) ?? [],
            credits: usage.flatMap(credits(from:)),
            notice: nil,
            error: error
        )
    }

    static func header(account: Account, obfuscate: Bool) -> AccountHeaderModel {
        AccountHeaderModel(
            title: account.effectiveDisplayName(obfuscated: obfuscate),
            subtitle: account.displayEmail(obfuscated: obfuscate),
            planBadge: account.displaySubscriptionType
        )
    }

    static func row(account: Account, hasStoredCredentials: Bool, obfuscate: Bool) -> AccountRowModel {
        AccountRowModel(
            id: account.id,
            title: account.effectiveDisplayName(obfuscated: obfuscate),
            email: account.displayEmail(obfuscated: obfuscate),
            planBadge: account.displaySubscriptionType,
            isActive: account.isActive,
            lastUsedText: account.lastUsed.map { Formatters.monthDay.string(from: $0) },
            hasStoredCredentials: hasStoredCredentials,
            rawLabel: account.customLabel
        )
    }

    static func activity(_ stats: ActivityStats) -> ActivitySummaryModel {
        ActivitySummaryModel(
            turns: stats.conversationTurns,
            activeTimeText: stats.activeCodingTimeString,
            linesWritten: stats.linesWritten,
            perModel: modelOrder.map { name in
                ModelUsageEntry(displayName: name, count: stats.modelUsage[name] ?? 0, tint: tint(forModel: name))
            }
        )
    }

    static func cost(_ summary: CostSummary) -> CostSeriesModel {
        CostSeriesModel(
            todayCost: summary.todayCost,
            daily: summary.dailyCosts.map { day in
                DailyCostEntry(
                    date: day.date,
                    cost: day.totalCost,
                    sessionCount: day.sessionCount,
                    modelBreakdown: day.modelBreakdown,
                    inputTokens: day.inputTokens,
                    outputTokens: day.outputTokens,
                    cacheWriteTokens: day.cacheWriteTokens,
                    cacheReadTokens: day.cacheReadTokens
                )
            }
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/ClaudeDisplayMapperTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 16 tests.

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Claude/ClaudeDisplayMapper.swift CCSwitcherTests/ClaudeDisplayMapperTests.swift
git commit -m "Add tested Claude to display model mapping"
```

---

### Task 6: AppState conforms to ProviderSurface

`AppState`'s own logic is not touched. All of this lands in a new file.

**Files:**
- Create: `CCSwitcher/Claude/ClaudeProviderSurface.swift`
- Modify: `CCSwitcher/AppState.swift` (one added stored property only)

- [ ] **Step 1: Expose which accounts have stored credentials**

`AccountRowModel.hasStoredCredentials` needs a Keychain answer, and a SwiftUI `body` cannot await, so `AppState` has to cache it.

**Do not compute this inside `diagnoseTokenHealth`, and do not call that diagnostic from `refresh`.** The comment at `AppState.init` records that the health check deliberately runs once at startup because it "used to run on every refresh — totally unnecessary every 5 minutes". Wiring it into the refresh cycle would reintroduce precisely the regression that comment describes, and it costs one Keychain read per account every five minutes. Read the backup store once instead, and only when its contents can actually have changed.

First expose the ids. In `CCSwitcher/Services/KeychainService.swift`, add next to `getAccountBackup(forAccountId:)`:

```swift
    /// Ids that currently have a credential backup, from one store read.
    /// Returns ids only — callers that need a token still ask for it by id, so
    /// this can be called freely without moving secrets around.
    func backedUpAccountIds() -> Set<String> {
        Set(loadBackupStore().keys)
    }
```

Then in `CCSwitcher/AppState.swift`, add after the `@Published var accountUsageErrors` declaration (around line 32):

```swift
    /// Account ids that have a usable credential backup. Consumed by the
    /// Accounts tab so `body` never awaits the Keychain. Refreshed only when the
    /// set can have changed — never on the periodic poll.
    @Published var accountsWithBackups: Set<UUID> = []
```

and add this alongside `diagnoseTokenHealth` in the `// MARK: - Diagnostics` section:

```swift
    /// One Keychain read, refreshed on the events that can change which accounts
    /// have backups. Kept out of `refresh` on purpose: the periodic cycle must
    /// not touch the Keychain.
    private func refreshBackupPresence() async {
        let ids = await keychain.backedUpAccountIds()
        accountsWithBackups = Set(ids.compactMap(UUID.init(uuidString:)))
    }
```

Call it from exactly these six places, each of which adds or removes a backup:

1. In `init`, inside the existing `Task.detached` block, after `diagnoseTokenHealth()`: `await self?.refreshBackupPresence()`
2. At the end of `addAccount()`, on the success path after `scheduleSave()`.
3. At the end of `loginNewAccount()`, after the `scheduleSave()` that follows appending the new account.
4. In `removeAccount(_:)`, after `scheduleSave()`. That method is not `async`, so wrap it: `Task { await refreshBackupPresence() }`.
5. At the end of `reauthenticateAccount(_:)`, after `clearUsageBlocks(for:)`.
6. In `updateActiveAccount(from:)`, in the `accounts.isEmpty` branch that auto-creates the first account and calls `captureCurrentCredentials`, after `scheduleSave()`.

Do **not** add it to `switchTo(_:)`. Switching moves credentials between the live slot and existing backups without creating or destroying any, so the set is unchanged and a read there would be waste.

- [ ] **Step 2: Create the conformance**

Create `CCSwitcher/Claude/ClaudeProviderSurface.swift`:

```swift
import Foundation

/// Adapts `AppState` — which owns all Claude credential, refresh and rate-limit
/// logic — to the shared `ProviderSurface` the popover consumes. Mapping only:
/// no behaviour lives here.
extension AppState: ProviderSurface {
    var providerType: AIProviderType { .claudeCode }

    var isAvailable: Bool { claudeAvailable }

    var isAuthenticating: Bool { isLoggingIn }

    var lastRefresh: Date? { lastUsageRefresh }

    var capabilities: ProviderCapabilities { .claude }

    private var obfuscateEmails: Bool {
        !UserDefaults.standard.bool(forKey: "showFullEmail")
    }

    var header: AccountHeaderModel? {
        activeAccount.map { ClaudeDisplayMapper.header(account: $0, obfuscate: obfuscateEmails) }
    }

    var accountCards: [UsageCardModel] {
        let obfuscate = obfuscateEmails
        return accounts.map { account in
            ClaudeDisplayMapper.card(
                account: account,
                usage: accountUsage[account.id],
                error: accountUsageErrors[account.id].map(ProviderErrorModel.init(claude:)),
                obfuscate: obfuscate
            )
        }
    }

    var accountRows: [AccountRowModel] {
        let obfuscate = obfuscateEmails
        return accounts.map { account in
            ClaudeDisplayMapper.row(
                account: account,
                hasStoredCredentials: accountsWithBackups.contains(account.id),
                obfuscate: obfuscate
            )
        }
    }

    var activity: ActivitySummaryModel { ClaudeDisplayMapper.activity(activityStats) }

    var cost: CostSeriesModel { ClaudeDisplayMapper.cost(costSummary) }

    // MARK: - Actions

    /// `refresh(knownStatus:force:)` does not witness this requirement: a
    /// defaulted parameter does not satisfy a protocol signature that omits it.
    /// Verified — without this the build fails with "protocol requires function
    /// 'refresh(force:)'". `loginNewAccount()` needs no witness; it already matches.
    func refresh(force: Bool) async {
        await refresh(knownStatus: nil, force: force)
    }

    func switchTo(accountId: UUID) async {
        guard let account = accounts.first(where: { $0.id == accountId }) else { return }
        await switchTo(account)
    }

    func importCurrentAccount() async {
        await addAccount()
    }

    func removeAccount(id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        removeAccount(account)
    }

    func reauthenticate(id: UUID) async {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        await reauthenticateAccount(account)
    }

    func setLabel(_ label: String?, forAccount id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        updateAccountLabel(account, label: label)
    }
}

extension ProviderErrorModel {
    /// `AppState.UsageErrorState` is nested inside a `@MainActor` type, so the
    /// conversion lives here rather than in the pure mapper.
    init(claude state: AppState.UsageErrorState) {
        self.init(message: state.message, needsReauth: state.isExpired, isRateLimited: state.isRateLimited)
    }
}
```

- [ ] **Step 3: Verify it builds**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

If the compiler reports that `switchTo(accountId:)` conflicts with the existing `switchTo(_ account: Account)`, they differ by argument label and both are valid overloads — the error would instead be an ambiguity at a call site, which there are none of yet.

- [ ] **Step 4: Run the full test suite to confirm nothing regressed**

```bash
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Claude/ClaudeProviderSurface.swift CCSwitcher/AppState.swift CCSwitcher/Services/KeychainService.swift
git commit -m "Conform AppState to ProviderSurface"
```

---

### Task 7: Provider registry

**Files:**
- Create: `CCSwitcher/Providers/ProviderRegistry.swift`
- Test: `CCSwitcherTests/ProviderRegistryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `CCSwitcherTests/ProviderRegistryTests.swift`:

```swift
import XCTest
@testable import CCSwitcher

final class ProviderRegistryTests: XCTestCase {

    func testClaudeOnlyWhenCodexConfigIsAbsent() {
        let available = ProviderRegistry.detect(
            claudeInstalled: true,
            fileExists: { _ in false }
        )
        XCTAssertEqual(available, [.claudeCode])
    }

    func testCodexAppearsWhenAuthFileExists() {
        let available = ProviderRegistry.detect(
            claudeInstalled: true,
            fileExists: { $0.hasSuffix("/.codex/auth.json") }
        )
        XCTAssertEqual(available, [.claudeCode, .codex])
    }

    func testCodexOnlyWhenClaudeIsMissing() {
        let available = ProviderRegistry.detect(
            claudeInstalled: false,
            fileExists: { $0.hasSuffix("/.codex/auth.json") }
        )
        XCTAssertEqual(available, [.codex])
    }

    /// A machine with neither provider must still yield one entry, otherwise the
    /// hub has no surface to show and the popover renders blank.
    func testFallsBackToClaudeWhenNothingIsDetected() {
        let available = ProviderRegistry.detect(claudeInstalled: false, fileExists: { _ in false })
        XCTAssertEqual(available, [.claudeCode])
    }

    func testResolvePrefersPersistedProviderWhenAvailable() {
        let resolved = ProviderRegistry.resolveActive(persisted: "Codex", available: [.claudeCode, .codex])
        XCTAssertEqual(resolved, .codex)
    }

    func testResolveFallsBackWhenPersistedProviderVanished() {
        let resolved = ProviderRegistry.resolveActive(persisted: "Codex", available: [.claudeCode])
        XCTAssertEqual(resolved, .claudeCode)
    }

    func testResolveFallsBackOnUnknownPersistedValue() {
        let resolved = ProviderRegistry.resolveActive(persisted: "Copilot", available: [.claudeCode, .codex])
        XCTAssertEqual(resolved, .claudeCode)
    }

    func testResolveFallsBackOnNoPersistedValue() {
        let resolved = ProviderRegistry.resolveActive(persisted: nil, available: [.codex])
        XCTAssertEqual(resolved, .codex)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/ProviderRegistryTests 2>&1 | tail -20
```

Expected: compile failure, `cannot find 'ProviderRegistry' in scope`.

- [ ] **Step 3: Write the implementation**

Create `CCSwitcher/Providers/ProviderRegistry.swift`:

```swift
import Foundation

/// Which providers are usable on this machine, and which one is active.
///
/// Detection is injectable so it is testable without touching the real
/// filesystem or forking the Claude CLI.
enum ProviderRegistry {

    /// Ordered so the switcher's segments never reshuffle between launches.
    private static let displayOrder: [AIProviderType] = [.claudeCode, .codex, .gemini]

    static func detect(
        claudeInstalled: Bool,
        fileExists: (String) -> Bool
    ) -> [AIProviderType] {
        var available: [AIProviderType] = []
        if claudeInstalled { available.append(.claudeCode) }
        if fileExists(codexAuthPath) { available.append(.codex) }

        // Never return empty: the hub must always have a surface to render, and
        // a Claude-shaped empty state is the same thing the app shows today
        // when the CLI is missing.
        return available.isEmpty ? [.claudeCode] : available.sorted { lhs, rhs in
            (displayOrder.firstIndex(of: lhs) ?? .max) < (displayOrder.firstIndex(of: rhs) ?? .max)
        }
    }

    static var codexAuthPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")
    }

    /// Pick the active provider, honouring the user's persisted choice unless
    /// that provider is no longer installed.
    static func resolveActive(persisted: String?, available: [AIProviderType]) -> AIProviderType {
        if let persisted, let provider = AIProviderType(rawValue: persisted), available.contains(provider) {
            return provider
        }
        return available.first ?? .claudeCode
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/ProviderRegistryTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Providers/ProviderRegistry.swift CCSwitcherTests/ProviderRegistryTests.swift
git commit -m "Add provider registry with injectable detection"
```

---

### Task 8: ProviderHub

**Files:**
- Create: `CCSwitcher/Providers/ProviderHub.swift`

No unit test: the hub's only real behaviour is Combine republishing, which is verified by the manual check in Task 14 (Codex data landing must re-render a view that observes the hub). Its pure parts are already covered by `ProviderRegistryTests`.

- [ ] **Step 1: Write the implementation**

Create `CCSwitcher/Providers/ProviderHub.swift`:

```swift
import SwiftUI
import Combine

private let log = FileLog("ProviderHub")

/// Owns every provider surface and exposes the active one.
///
/// SwiftUI cannot inject an `EnvironmentObject` by protocol existential, so a
/// concrete hub is the single observable object views see. It forwards each
/// surface's `objectWillChange` so a view that observes only the hub still
/// re-renders when the underlying provider's data changes.
///
/// Adding a provider is one `surfaces` entry plus one `ProviderTheme` case.
@MainActor
final class ProviderHub: ObservableObject {
    @Published private(set) var available: [AIProviderType]
    @Published private(set) var activeProvider: AIProviderType

    private var surfaces: [AIProviderType: any ProviderSurface]
    private var forwarders: [AnyCancellable] = []

    private static let persistenceKey = "activeProvider"

    var surface: any ProviderSurface {
        // `available` is never empty and every available provider has a
        // registered surface, so this is total. The fallback keeps the app
        // rendering instead of trapping if that invariant is ever broken.
        surfaces[activeProvider] ?? surfaces.values.first!
    }

    var theme: ProviderTheme { .theme(for: activeProvider) }

    /// Whether to show the switcher at all. A Claude-only machine keeps today's
    /// header exactly as it is.
    var showsSwitcher: Bool { available.count > 1 }

    init(surfaces: [AIProviderType: any ProviderSurface], available: [AIProviderType]) {
        precondition(!surfaces.isEmpty, "ProviderHub requires at least one surface")
        let registered = available.filter { surfaces[$0] != nil }
        let effective = registered.isEmpty ? Array(surfaces.keys) : registered

        self.surfaces = surfaces
        self.available = effective
        self.activeProvider = ProviderRegistry.resolveActive(
            persisted: UserDefaults.standard.string(forKey: Self.persistenceKey),
            available: effective
        )
        installForwarders()
        log.info("[init] available=\(effective.map(\.rawValue)) active=\(self.activeProvider.rawValue)")
    }

    func select(_ provider: AIProviderType) {
        guard provider != activeProvider, surfaces[provider] != nil else { return }
        activeProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.persistenceKey)
        log.info("[select] active=\(provider.rawValue)")
        Task { await surfaces[provider]?.refresh(force: false) }
    }

    /// Refresh only the visible provider. Polling a provider the user is not
    /// looking at spends CPU and, worse, rate-limit budget.
    func refreshActive(force: Bool) async {
        await surface.refresh(force: force)
    }

    private func installForwarders() {
        forwarders = surfaces.values.map { surface in
            surface.objectWillChange.sink { [weak self] _ in
                // The surface has not applied its mutation yet, so bounce to the
                // next turn of the main loop before republishing.
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            }
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

**This step requires editing `ProviderSurface.swift`, verified during implementation.** Without a concrete publisher type, `surface.objectWillChange.sink` on an existential fails with:

```
error: referencing instance method 'sink(receiveValue:)' on 'Publisher' requires the types 'Self.Failure' and 'Never' be equivalent
```

Constrain the associated type in `CCSwitcher/Providers/ProviderSurface.swift`:

```swift
@MainActor
protocol ProviderSurface: AnyObject, ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
```

That alone then fails with `cannot find type 'ObservableObjectPublisher' in scope`, because `ProviderSurface.swift` only imports `Foundation`. Add `import Combine` to it as well.

`AppState` and `CodexState` both use the synthesized `ObservableObjectPublisher`, so the constraint costs nothing — but confirm `AppState` still conforms after adding it.

- [ ] **Step 3: Commit**

```bash
git add CCSwitcher/Providers/ProviderHub.swift CCSwitcher/Providers/ProviderSurface.swift
git commit -m "Add provider hub owning all surfaces"
```

---

### Task 9: Wire the hub into the app

**Files:**
- Modify: `CCSwitcher/CCSwitcherApp.swift`
- Modify: `CCSwitcher/Services/StatusItemController.swift`

- [ ] **Step 1: Read the current app entry point**

```bash
cat CCSwitcher/CCSwitcherApp.swift
```

Note the existing `@StateObject private var appState = AppState()` declaration, the `StatusItemController.install(appState:config:locale:)` call, and every `.environmentObject(appState)` injection site. The edits below add the hub beside `appState` without removing it — views migrate one at a time in Tasks 10-13, and until then they still need `appState`.

- [ ] **Step 2: Build and inject the hub**

In `CCSwitcher/CCSwitcherApp.swift`, add next to the existing `appState` declaration:

```swift
    @StateObject private var providerHub: ProviderHub
```

and add an `init()` that constructs both (replace the implicit initializer; keep any existing `@StateObject` declarations for `MenuBarConfig` / `UpdateChecker` untouched):

```swift
    init() {
        let state = AppState()
        let available = ProviderRegistry.detect(
            claudeInstalled: true,   // corrected asynchronously via AppState.claudeAvailable
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        _appState = StateObject(wrappedValue: state)
        _providerHub = StateObject(wrappedValue: ProviderHub(
            surfaces: [.claudeCode: state],
            available: available.filter { $0 == .claudeCode }
        ))
    }
```

Codex is filtered out here on purpose: stage 1 has no `CodexState`, and registering an unavailable provider would give the hub a segment with no surface behind it. Stage 2 replaces this filter.

Then add `.environmentObject(providerHub)` next to every existing `.environmentObject(appState)` call in the scene body.

- [ ] **Step 3: Pass the hub to the status item**

In `CCSwitcher/Services/StatusItemController.swift`, add a stored property beside `private var appState: AppState?`:

```swift
    private var providerHub: ProviderHub?
```

Change the `install` signature and body to take and retain the hub, and inject it into both hosting controllers:

```swift
    func install(appState: AppState, hub: ProviderHub, config: MenuBarConfig, locale: Locale) {
        self.appState = appState
        self.providerHub = hub
```

Inside `install`, every place that builds a hosting controller with `.environmentObject(appState)` gains `.environmentObject(hub)`. Do the same in `updateLocale(_:)` if it rebuilds the hosted views.

Update the call site in `CCSwitcherApp.swift` to `install(appState: appState, hub: providerHub, config: menuBarConfig, locale: locale)`.

- [ ] **Step 4: Verify it builds and runs**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

Then launch the built app and confirm the menu bar item appears and the popover opens unchanged:

```bash
open ~/Library/Developer/Xcode/DerivedData/CCSwitcher-*/Build/Products/Debug/CCSwitcher.app
```

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/CCSwitcherApp.swift CCSwitcher/Services/StatusItemController.swift
git commit -m "Inject provider hub into app and status item"
```

---

### Task 10: Migrate UsageDashboardView

The largest view migration. It is also where the payoff shows: `usageBars` stops knowing about `fiveHour` / `sevenDay`, and the activity card stops hardcoding four Claude model names.

**Files:**
- Modify: `CCSwitcher/Views/UsageDashboardView.swift`

- [ ] **Step 1: Swap the observed object and add the theme**

Replace lines 25-26:

```swift
    @EnvironmentObject private var appState: AppState
    @AppStorage("showFullEmail") private var showFullEmail = false
```

with:

```swift
    @EnvironmentObject private var hub: ProviderHub
    @Environment(\.providerTheme) private var theme
```

Email obfuscation moves into the mapper (`ClaudeDisplayMapper.card(obfuscate:)` already reads `showFullEmail`), so the view no longer needs the `@AppStorage`.

- [ ] **Step 2: Rewrite the body's branching**

Replace lines 28-83 with:

```swift
    var body: some View {
        let surface = hub.surface
        ScrollView {
            VStack(spacing: 16) {
                if surface.accountCards.isEmpty && surface.isLoading {
                    loadingState
                } else if surface.accountCards.isEmpty {
                    emptyState
                } else {
                    todayCostBanner(surface.cost.todayCost)
                    todayActivityCard(surface.activity)
                    ForEach(surface.accountCards) { card in
                        accountUsageCard(card)
                    }
                }

                if let lastRefresh = surface.lastRefresh {
                    HStack(spacing: 4) {
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                        Text(lastRefresh, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
            // Report this VStack's intrinsic height to MainMenuView so it can
            // size the popover frame to fit the Usage tab's content exactly.
            // See MainMenuView.swift for the measurement contract.
            .measureUsageContentHeight()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Loading usage data...")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundStyle(theme.textSecondary)
            Text("Usage data unavailable")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
```

- [ ] **Step 3: Parameterize the cost banner and activity card**

Replace the `todayCostBanner` computed property (lines 87-108) with:

```swift
    private func todayCostBanner(_ cost: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                Text("Today's API-Equivalent Cost")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
            }

            StatWithTooltip(tooltip: Self.costDisclaimer) {
                Text(Formatters.currency(cost))
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }
        }
        .cardStyle(fill: theme.cardFill, border: theme.cardBorder)
        .sectionPadding()
    }
```

Replace `todayActivityCard` (lines 114-150) with a version driven by the model. The per-model row becomes a `ForEach`, which is what lets Codex show `gpt-5.6-sol` instead of Claude tiers:

```swift
    private func todayActivityCard(_ activity: ActivitySummaryModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.subheadline)
                    .foregroundStyle(theme.accent)
                Text("Today's Activity")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            HStack(spacing: 0) {
                activityStat(icon: "bubble.left.and.bubble.right", value: "\(activity.turns)", label: "Turns",
                             tooltip: "Messages you sent today")
                activityStat(icon: "clock", value: activity.activeTimeText, label: "Active",
                             tooltip: "Estimated total time the agent worked for you today. Parallel sessions stack. Idle gaps >10 min excluded. This is an approximation based on message timestamps, not exact.")
                if let lines = activity.linesWritten {
                    activityStat(icon: "doc.text", value: "\(lines)", label: "Lines",
                                 tooltip: "Estimated lines of code written via file-editing tools")
                }
            }

            if !activity.perModel.isEmpty {
                HStack(spacing: 0) {
                    ForEach(activity.perModel) { entry in
                        modelStat(entry)
                    }
                }
            }
        }
        .cardStyle(fill: theme.cardFill, border: theme.cardBorder)
        .sectionPadding()
    }
```

Replace `modelStat(name:count:tooltip:)` (lines 170-187) and delete `modelColor(_:)` (lines 189-197) entirely — the tint now arrives with the entry:

```swift
    private func modelStat(_ entry: ModelUsageEntry) -> some View {
        VStack(spacing: 3) {
            Text("\(entry.count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(entry.count > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
            HStack(spacing: 3) {
                Circle()
                    .fill(entry.tint)
                    .frame(width: 7, height: 7)
                Text(entry.displayName)
                    .font(.caption2)
                    .foregroundStyle(entry.count > 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
            }
        }
        .frame(maxWidth: .infinity)
    }
```

The per-model tooltips are dropped because they described Claude tiers specifically and cannot be written generically. In `activityStat`, change `.foregroundStyle(.textSecondary)` to `.foregroundStyle(theme.textSecondary)` in both places.

- [ ] **Step 4: Rewrite the account card**

Replace `accountUsageCard(account:usage:)`, `accountHeader(_:)`, `usageBars(_:)` and `extraUsageRow(_:)` (lines 201-292) with:

```swift
    private func accountUsageCard(_ card: UsageCardModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            accountHeader(card)

            if let error = card.error, card.windows.isEmpty {
                errorRow(error)
            } else if card.isEmpty {
                noticeRow(icon: "exclamationmark.triangle", tint: .yellow,
                          text: Text("No usage data yet — refresh to fetch."))
            } else {
                ForEach(card.windows) { window in
                    usageRow(labelView: label(for: window), dotColor: nil,
                             resetText: UsageWindowFormat.resetText(until: window.resetsAt),
                             utilization: window.utilization)
                }
                ForEach(card.scopedLimits) { limit in
                    usageRow(labelView: Text(limit.modelName), dotColor: limit.tint,
                             resetText: UsageWindowFormat.resetText(until: limit.resetsAt),
                             utilization: limit.utilization)
                }
                if let credits = card.credits {
                    creditsRow(credits)
                }
                if let error = card.error {
                    errorRow(error)
                }
            }

            if let notice = card.notice {
                noticeRow(icon: "info.circle", tint: .orange, text: Text(notice))
            }
        }
        // The pre-migration code read `account.isActive ? .cardFill : .cardFill`,
        // i.e. the active account got no emphasis. Keep it identical so this
        // stage changes no pixels; giving the active card `cardFillStrong` is a
        // reasonable improvement but belongs in its own change.
        .cardStyle(fill: theme.cardFill, border: theme.cardBorder)
        .sectionPadding()
    }

    private func label(for window: UsageWindowModel) -> Text {
        switch window.kind {
        case .session: return Text("Session")
        case .weekly: return Text("Weekly")
        case .other(let seconds): return Text(UsageWindowFormat.durationText(seconds: seconds))
        }
    }

    @ViewBuilder
    private func accountHeader(_ card: UsageCardModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: hub.activeProvider.iconName)
                .font(.subheadline)
                .foregroundStyle(card.isActive ? theme.accent : theme.textSecondary)

            Text(card.subtitle ?? card.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if card.isActive {
                Badge(text: String(localized: "Active", bundle: L10n.bundle), color: .green)
            }

            Spacer()

            if let plan = card.planBadge {
                Badge(text: plan, color: theme.accent)
            }
        }
    }

    @ViewBuilder
    private func creditsRow(_ credits: CreditPoolModel) -> some View {
        let tint: Color = credits.isEnabled ? .orange : .gray
        HStack(spacing: 6) {
            Image(systemName: credits.isEnabled ? "bolt.fill" : "bolt.slash")
                .font(.caption)
                .foregroundStyle(tint)
            Text("Extra usage")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            if credits.isUnlimited {
                Text("Unlimited")
                    .font(.caption)
                    .foregroundStyle(tint)
            } else if let balance = credits.balanceText {
                Text(balance)
                    .font(.caption)
                    .foregroundStyle(tint)
            } else {
                Text(LocalizedStringKey(credits.isEnabled ? "On" : "Off"))
                    .font(.caption)
                    .foregroundStyle(tint)
            }
        }
    }

    private func errorRow(_ error: ProviderErrorModel) -> some View {
        let icon = error.isRateLimited ? "timer" : (error.needsReauth ? "exclamationmark.triangle" : "xmark.circle")
        return noticeRow(icon: icon, tint: error.needsReauth ? .yellow : .red, text: Text(error.message))
    }

    private func noticeRow(icon: String, tint: Color, text: Text) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(tint)
            text
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.top, 4)
    }
```

- [ ] **Step 5: Point the usage row at the theme**

In the remaining `usageRow(labelView:dotColor:resetText:utilization:)` (previously lines 305-344), replace `.foregroundStyle(.textSecondary)` with `.foregroundStyle(theme.textSecondary)` (three occurrences), `.fill(.progressTrack)` with `.fill(theme.progressTrack)`, and both `colorForUtilization(utilization)` calls with `theme.utilizationColor(utilization)`. Delete the now-unused `colorForUtilization(_:)` function and the two `usageRow` overloads that took `label:` / `labelText:` — all call sites now pass `labelView:`.

- [ ] **Step 6: Verify it builds and looks identical**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
open ~/Library/Developer/Xcode/DerivedData/CCSwitcher-*/Build/Products/Debug/CCSwitcher.app
```

Open the popover's Usage tab and compare against the screenshots in the design spec. Confirm: today's cost, the three activity stats, the four model dots with the same colours, per-account session and weekly bars with the same percentages, the Fable scoped row, and "Extra usage Off".

- [ ] **Step 7: Commit**

```bash
git add CCSwitcher/Views/UsageDashboardView.swift
git commit -m "Render usage dashboard from provider display models"
```

---

### Task 11: Migrate CostDetailView

**Files:**
- Modify: `CCSwitcher/Views/CostDetailView.swift`

- [ ] **Step 1: Swap the observed object**

Replace line 5:

```swift
    @EnvironmentObject private var appState: AppState
```

with:

```swift
    @EnvironmentObject private var hub: ProviderHub
    @Environment(\.providerTheme) private var theme
```

- [ ] **Step 2: Replace the three data reads**

`CostSeriesModel` mirrors `CostSummary`'s shape (`todayCost`, `daily`, `totalCost`) with `DailyCostEntry` replacing `DailyCost`, so these are mechanical substitutions:

- Line 22: `let summary = appState.costSummary` → `let summary = hub.surface.cost`
- Line 74: `let costs = appState.costSummary.dailyCosts` → `let costs = hub.surface.cost.daily`
- Line 112: `let costs = appState.costSummary.dailyCosts` → `let costs = hub.surface.cost.daily`
- Line 121: `appState.costSummary.totalCost` → `hub.surface.cost.totalCost`

- [ ] **Step 3: Update the element type**

Change every `[DailyCost]` annotation to `[DailyCostEntry]` and every `day: DailyCost` parameter to `day: DailyCostEntry` — specifically `costForLastDays(_ days: Int, costs: [DailyCost], today: String, formatter: DateFormatter)` at line 102 and `dailyRow(day: DailyCost, maxCost: Double)` at line 149.

Inside those functions, `DailyCost.totalCost` becomes `DailyCostEntry.cost`. `date`, `modelBreakdown`, `totalTokens` and the four token counts keep their names.

`DailyCostEntry.sessionCount` is `Int?`, so it maps straight across from `DailyCost.sessionCount`. Codex has the same concept — one rollout file is one session — so nothing is dropped.

Watch out: the `sessionCount` reference is **not** in `dailyRow`. It is in `todayCard`, which renders `Label("\(today.sessionCount) sessions", systemImage: "terminal")` in the model-breakdown footer. Because the field is now optional, wrap that label in `if let sessions = today.sessionCount`. Do not delete it.

- [ ] **Step 4: Point the view at the theme**

Replace every `.foregroundStyle(.textSecondary)` with `.foregroundStyle(theme.textSecondary)`, every `.cardStyle()` with `.cardStyle(fill: theme.cardFill, border: theme.cardBorder)`, and every `.brand` colour reference with `theme.accent`.

- [ ] **Step 5: Verify it builds and matches**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
open ~/Library/Developer/Xcode/DerivedData/CCSwitcher-*/Build/Products/Debug/CCSwitcher.app
```

Open the Costs tab. Confirm today's figure, the period summary cards, and the daily history rows show the same numbers as before the change.

- [ ] **Step 6: Commit**

```bash
git add CCSwitcher/Views/CostDetailView.swift
git commit -m "Render cost detail from provider display models"
```

---

### Task 12: Migrate AccountSwitcherView

**Files:**
- Modify: `CCSwitcher/Views/AccountSwitcherView.swift`

- [ ] **Step 1: Swap the observed object**

Replace line 5:

```swift
    @EnvironmentObject private var appState: AppState
```

with:

```swift
    @EnvironmentObject private var hub: ProviderHub
    @Environment(\.providerTheme) private var theme
```

- [ ] **Step 2: Drive the list from rows**

- Line 17: `if appState.accounts.isEmpty` → `if hub.surface.accountRows.isEmpty`
- Line 20: `ForEach(appState.accounts) { account in` → `ForEach(hub.surface.accountRows) { row in`
- Line 57: change `accountRow(_ account: Account)` to `accountRow(_ row: AccountRowModel)`

Inside `accountRow`, substitute the fields: `account.id` → `row.id`, `account.isActive` → `row.isActive`, `account.displaySubscriptionType` → `row.planBadge`, the display-name expression → `row.title`, the email expression → `row.email`, `account.customLabel` → `row.rawLabel`. Any `@AppStorage("showFullEmail")` read in this file becomes dead — the mapper already applied obfuscation — so delete it.

- [ ] **Step 3: Route the actions through the surface**

- Line 133: `Task { await appState.switchTo(account) }` → `Task { await hub.surface.switchTo(accountId: row.id) }`
- Line 141: `Task { await appState.reauthenticateAccount(account) }` → `Task { await hub.surface.reauthenticate(id: row.id) }`
- Line 151: `appState.removeAccount(account)` → `hub.surface.removeAccount(id: row.id)`
- Line 170: `appState.updateAccountLabel(account, label: editingLabel)` → `hub.surface.setLabel(editingLabel, forAccount: account.id)`; change `commitLabelEdit(_ account: Account)` to `commitLabelEdit(_ row: AccountRowModel)` and use `row.id`
- Line 178: `if appState.isLoggingIn` → `if hub.surface.isAuthenticating`
- Line 216: `Task { await appState.addAccount() }` → `Task { await hub.surface.importCurrentAccount() }`
- Line 234: `Task { await appState.loginNewAccount() }` → `Task { await hub.surface.loginNewAccount() }`

- [ ] **Step 4: Gate actions on capabilities**

Wrap the two add buttons in `addAccountButtons` so a read-only provider does not offer them:

```swift
        if hub.surface.capabilities.canImportCurrent {
            // existing "add current account" button
        }
        if hub.surface.capabilities.canLoginNewAccount {
            // existing "login new account" button
        }
```

Do the same for the switch action (`hub.surface.capabilities.canSwitchAccounts`) and the re-authenticate action (`hub.surface.capabilities.canReauthenticate`). Where a row has `hasStoredCredentials == false`, keep whatever prompt the current code shows for that case; if it shows none, the switch button simply stays disabled:

```swift
        .disabled(!row.hasStoredCredentials)
```

- [ ] **Step 5: Point the view at the theme**

Replace `.foregroundStyle(.textSecondary)` with `.foregroundStyle(theme.textSecondary)`, `.cardStyle()` with `.cardStyle(fill: theme.cardFill, border: theme.cardBorder)`, `.cardStyle(fill: .cardFillStrong)` with `.cardStyle(fill: theme.cardFillStrong, border: theme.cardBorder)`, and `.brand` with `theme.accent`.

- [ ] **Step 6: Verify it builds and every action works**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
open ~/Library/Developer/Xcode/DerivedData/CCSwitcher-*/Build/Products/Debug/CCSwitcher.app
```

On the Accounts tab, verify: both accounts listed with the right badges, renaming an account persists, switching accounts still works end to end, and the account that was active before the switch becomes inactive.

- [ ] **Step 7: Commit**

```bash
git add CCSwitcher/Views/AccountSwitcherView.swift
git commit -m "Render account switcher from provider display models"
```

---

### Task 13: Migrate MenuBarModuleView and MainMenuView

**Files:**
- Modify: `CCSwitcher/Views/MenuBarModuleView.swift`
- Modify: `CCSwitcher/Views/MainMenuView.swift`

- [ ] **Step 1: Replace the module view's data accessors**

`MenuBarModuleView` reads `appState.activeAccount` plus `accountUsage[id].fiveHour/sevenDay`. Those become lookups on the active card's windows. Add these helpers, replacing the computed properties at lines 91-141:

```swift
    private var activeCard: UsageCardModel? {
        hub.surface.accountCards.first { $0.isActive } ?? hub.surface.accountCards.first
    }

    private func window(_ kind: UsageWindowModel.Kind) -> UsageWindowModel? {
        activeCard?.windows.first { $0.kind == kind }
    }

    private var accountText: String {
        guard let card = activeCard else { return "—" }
        return card.title
    }

    private var sessionUtilization: Double? { window(.session)?.utilization }

    private var weeklyUtilization: Double? { window(.weekly)?.utilization }

    private var sessionTimeElapsed: Double? { window(.session)?.elapsedPercent }

    private var weeklyTimeElapsed: Double? { window(.weekly)?.elapsedPercent }

    private var dailyCostText: String {
        Formatters.currency(hub.surface.cost.todayCost)
    }

    private var sessionResetText: String {
        UsageWindowFormat.compactResetText(until: window(.session)?.resetsAt) ?? "—"
    }

    private var weeklyResetText: String {
        UsageWindowFormat.compactResetText(until: window(.weekly)?.resetsAt) ?? "—"
    }
```

Keep whatever surrounding formatting the originals applied (for example a `$`-stripping or truncation step in `dailyCostText` / `accountText`); only the data source changes.

**Do not use `@EnvironmentObject` here.** The menu-bar strip is not an ordinary view. `MenuBarStripView` takes `let appState: AppState` as a plain stored property and re-renders on a 3-second `Timer.publish`, and its own comment explains why: inside the `NSStatusItem` hosting context, `ObservableObject` change delivery is unreliable, so only `@State` or a timer actually redraws the hosted view. `StatusItemController` accordingly injects no environment object into the strip at all — verified: it passes `appState` and `config` through `MenuBarStripView`'s initializer. Switching the strip to `@EnvironmentObject` would both crash (no object in that environment) and break the polling that keeps countdowns current.

So thread the hub through the initializer, exactly as `appState` is threaded today:

1. In `MenuBarStripView`, replace `let appState: AppState` with `let hub: ProviderHub`, keeping the existing explanatory comment above it, and pass `hub: hub` down to `MenuBarModuleView` instead of `appState: appState`.
2. In `MenuBarModuleView`, replace its `appState` stored property with `let hub: ProviderHub` and rewrite the data accessors as below.
3. In `StatusItemController`, update **both** `MenuBarStripView(...)` construction sites — one in `install(...)`, one in `updateLocale(_:)` — to pass the hub. The controller already stores it as `providerHub` from Task 9.

Read the file before editing so you match its existing shape:

```bash
cat CCSwitcher/Views/MenuBarStripView.swift
```

Because the strip polls rather than observes, a provider switch will not restyle it until the next tick (up to 3 seconds). That is acceptable and matches how the strip already lags other state; do not add machinery to fix it in this task.

- [ ] **Step 2: Migrate the popover header and footer**

In `CCSwitcher/Views/MainMenuView.swift`, replace `@EnvironmentObject private var appState: AppState` with:

```swift
    @EnvironmentObject private var hub: ProviderHub
```

In `headerView` (lines 242-278): `appState.activeAccount` becomes `hub.surface.header`, so the branch becomes

```swift
                if let header = hub.surface.header {
                    HStack(spacing: 6) {
                        Text(header.title)
                            .font(.headline)
                        if let plan = header.planBadge {
                            Badge(text: plan, color: theme.accent)
                        }
                    }
                    Text(header.subtitle)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                } else {
```

and `Image(systemName: "brain.head.profile")` becomes `Image(systemName: hub.activeProvider.iconName)` with `.foregroundStyle(theme.accent)`. `appState.isLoading` becomes `hub.surface.isLoading`. The `@AppStorage("showFullEmail")` read becomes dead here too — delete it.

In `footerView` (lines 330-380): `appState.errorMessage` becomes `hub.surface.errorMessage`, and the refresh button's `Task { await appState.refresh(force: true) }` becomes `Task { await hub.refreshActive(force: true) }`.

In `tabBar` (lines 282-326): `Capsule().fill(Color.brand)` becomes `.fill(theme.tabSelectedFill)`, `.fill(.tabFill)` becomes `.fill(theme.tabFill)`, `.stroke(.tabBorder, ...)` becomes `.stroke(theme.tabBorder, ...)`, and the label's `.foregroundStyle(selectedTab == tab ? .white : .textSecondary)` becomes `.foregroundStyle(selectedTab == tab ? theme.tabSelectedForeground : theme.textSecondary)`.

- [ ] **Step 3: Apply the theme at the root**

In `MainMenuView.body`, add `@Environment(\.providerTheme) private var theme` is *not* used here — the root is where the theme is injected, so declare it locally instead:

```swift
    private var theme: ProviderTheme { hub.theme }
```

Replace `.background(.ultraThinMaterial)` (line 145) with a switch on the theme's panel, and inject the theme plus forced appearance into the subtree:

```swift
        .background(panelBackground)
        .environment(\.providerTheme, theme)
        .preferredColorScheme(theme.forcedColorScheme)
```

and add:

```swift
    @ViewBuilder
    private var panelBackground: some View {
        switch theme.panel {
        case .material(let material): Rectangle().fill(material)
        case .flat(let color): Rectangle().fill(color)
        }
    }
```

The strip needs the theme too, but **not** via `.environment(\.providerTheme, …)` at its hosting site: that value would be captured once when the `AnyView` is built and would not follow a later provider switch, because the strip is never re-created. Since the strip already holds the hub as a stored property, read `hub.theme` directly wherever a module needs a colour. The 3-second tick then picks up a provider switch on its own.

- [ ] **Step 4: Verify it builds and the strip still updates**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
open ~/Library/Developer/Xcode/DerivedData/CCSwitcher-*/Build/Products/Debug/CCSwitcher.app
```

Confirm the menu bar strip shows the account name and both bars with the same values as before, and that clicking refresh in the popover updates the strip.

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Views/MenuBarModuleView.swift CCSwitcher/Views/MainMenuView.swift CCSwitcher/Views/MenuBarStripView.swift CCSwitcher/Services/StatusItemController.swift
git commit -m "Render menu bar and popover chrome from provider hub"
```

---

### Task 14: Stage verification

**Files:** none — this is a verification gate.

- [ ] **Step 1: Confirm no view still reads AppState directly**

The four popover-surface views must be clean. Two other files legitimately keep `appState` and are excluded:

```bash
grep -rn "appState\." CCSwitcher/Views/ \
  | grep -v "SettingsView.swift" \
  | grep -v "ClaudeCLITabView.swift" \
  || echo "clean"
```

Expected: `clean`.

Why those two are excluded rather than migrated:

- `ClaudeCLITabView` is a **Claude-specific** settings tab — it manages the `claude` binary and its auth. It has no provider-agnostic meaning, and Stage 2 gives Codex its own separate tab rather than generalizing this one.
- `SettingsView` calls `appState.startAutoRefresh(interval:)`. That timer is global app behaviour, not per-provider display state, so routing it through `ProviderSurface` would put a scheduling concern into a display protocol.

`StatusItemController` also still retains `appState`, because it injects it into the environment for those Settings views.

- [ ] **Step 2: Run the whole suite**

```bash
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' 2>&1 | tail -25
```

Expected: `** TEST SUCCEEDED **` with all four test classes reporting.

- [ ] **Step 3: Side-by-side visual check**

Build the branch, screenshot each of the three tabs plus the menu bar strip, then check out `main`, build, and screenshot the same four surfaces. Compare. Any difference in numbers, colours, spacing or badge text is a regression to fix before moving to stage 2.

**One difference is expected and is not a regression.** `UsageWindowFormat.resetText` rounds to the nearest second, whereas the `UsageWindow.resetTimeString` it replaces truncated. A countdown may therefore read one minute higher than the old build at the same instant — for example "Resets in 25 min" where the old build said "24 min". Rounding is the more accurate rendering and is what the Task 2 tests pin. Only treat a countdown difference as a regression if it exceeds one minute.

Task 13's migration leaves `UsageWindow.resetTimeString`, `compactResetString` and `elapsedPercent(windowSeconds:)` in `UsageData.swift` with no remaining callers. Confirm that with a search and delete the dead ones, so two implementations of the same countdown cannot drift apart:

```bash
grep -rn "resetTimeString\|compactResetString\|elapsedPercent(windowSeconds" CCSwitcher/ CCSwitcherWidget/ Shared/
```

Anything still referenced from the widget target must stay.

```bash
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -3
```

- [ ] **Step 4: Confirm the switcher is correctly hidden**

The hub registers only Claude in stage 1, so `showsSwitcher` must be false and no segmented control should appear anywhere. Verify visually.

- [ ] **Step 5: Commit any fixes and tag the stage**

```bash
git add -A
git commit -m "Verify provider seams preserve existing behaviour"
```

---

## Self-Review

**Spec coverage.** Every Stage 1 item in the spec maps to a task: `ProviderRegistry` (7), `ProviderSelection` (folded into `ProviderHub`'s persisted `activeProvider`, Task 8 — the spec listed it as a separate file, but a 12-line object holding one `UserDefaults` key alongside the hub that reads it would be indirection without benefit), `ProviderHub` (8), `ProviderSurface` (4), display models (2, 3), `ProviderTheme` (4), `extension AppState: ProviderSurface` (6), and the four view migrations (10, 11, 12, 13). The spec's `MenuBarSnapshot.swift` is not created: the menu bar reads `accountCards` and `cost` directly, and a separate snapshot type would carry no information those do not already have. Per-provider module configuration is Stage 4, as the spec states.

**Placeholder scan.** Three steps intentionally direct the engineer to read a file before editing (`CCSwitcherApp.swift` in Task 9, `MenuBarStripView.swift` in Task 13, `CostDetailView`'s `sessionCount` in Task 11). These are not placeholders: the surrounding code is not reproduced in this plan, the exact substitutions are named, and the reason for reading is stated. Everything that creates code shows the code.

**Type consistency.** Checked across tasks: `UsageWindowModel.Kind(windowSeconds:)` is an initializer everywhere (Tasks 2, 5, 13), not a static `classify`. `ScopedLimitModel.tint` is used in Tasks 3, 5 and 10. `CostSeriesModel.daily` (not `dailyCosts`) and `DailyCostEntry.cost` (not `totalCost`) are used consistently in Tasks 3, 5 and 11. `ProviderErrorModel.needsReauth` (not `isExpired`) appears in Tasks 3, 5, 6 and 10. `ProviderSurface.isAuthenticating` (not `isLoggingIn`) appears in Tasks 4, 6 and 12. `UsageWindowFormat.resetText` / `compactResetText` / `durationText` are used with those exact names in Tasks 2, 10 and 13. `hub.surface` is the access path everywhere, and `hub.refreshActive(force:)` matches Task 8's definition.

**One deviation worth flagging.** Task 6 adds a stored property, a small private method, and six one-line call sites to `AppState`, plus one method to `KeychainService` — where the spec described `AppState` as untouched. It is needed because `AccountRowModel.hasStoredCredentials` requires a Keychain read that a SwiftUI `body` cannot await. No logic is added to the credential paths themselves.

The obvious cheaper-looking route — folding this into `diagnoseTokenHealth` and calling that from `refresh` — is explicitly rejected in Task 6, because `AppState.init` documents that the diagnostic was moved out of the refresh cycle for being "totally unnecessary every 5 minutes". Restoring it would undo a deliberate performance fix and add one Keychain read per account per poll.

---

## Next

Stage 2 (`docs/superpowers/plans/2026-07-31-codex-provider-stage2-readonly.md`) builds `CodexState` on these seams: auth reading, the live usage endpoint with local fallback, the rollout cost and activity parser, the Codex theme, and the header switcher.
