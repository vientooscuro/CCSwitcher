# Codex Provider Support — Design

**Date:** 2026-07-31
**Status:** Approved
**Author:** brainstorming session

## Goal

Add OpenAI Codex as a first-class provider alongside Claude Code: usage limits,
API-equivalent cost, activity stats, and multi-account switching — with a
dedicated near-black theme when Codex is selected. Introduce the seams that make
a third provider (Gemini) cheap to add.

## Motivation

CCSwitcher already solves "which account am I on and how much quota is left" for
Claude Code. Users who run Codex alongside Claude have the same questions and no
answer: `codex` has no menu-bar surface, and its `/status` only shows a cached
snapshot inside a running session.

`AIProviderType` has carried a `.codex` case since the first commit, but nothing
consumes it. Everything below it — `AppState`, the parsers, every view — is
hardcoded to Claude.

## Non-Goals

- Gemini support. The seams are designed for it; the implementation is not in scope.
- Cross-provider aggregate views ("total spend across Claude + Codex").
- Any write to `~/.codex` beyond `auth.json` swapping.
- Issuing our own OAuth refresh grants for Codex (see Token Lifetime below).

---

## Discovered Facts About Codex

Everything in this section was verified against a live Codex 0.145.0 install
before the design was fixed. Numbers come from that machine.

### Credentials: `~/.codex/auth.json`

```
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token":      "<JWT, 1h lifetime>",
    "access_token":  "<JWT, 240h (10 day) lifetime>",
    "refresh_token": "<opaque>",
    "account_id":    "<uuid>"
  },
  "last_refresh": "2026-07-30T16:11:56.249967Z"
}
```

Mode `0600`, single file, no Keychain involvement. `id_token` claims carry
`email`, `name`, `https://api.openai.com/auth.chatgpt_plan_type`, and the
organization list.

**Token lifetime is the single most consequential finding.** The Codex
`access_token` lives 10 days, versus roughly 8 hours for Claude. The entire
delegated-refresh / `invalid_grant` / live-slot-self-heal apparatus that
dominates `AppState` exists because Claude's token expires constantly and is
co-owned by a rotating refresher. For Codex none of that applies: the token is
valid almost always, and the Codex CLI refreshes it during normal use. We
re-read the file; we never issue a refresh grant ourselves. On the rare genuine
expiry we surface "sign in again" with a button that runs `codex login`.

The `id_token` expires hourly, which is fine — we read its claims as metadata
without verifying the signature, and the authoritative `email` / `plan_type`
come from the live usage endpoint anyway. Observed drift proves the point: the
`id_token` on the test machine said `prolite` while the live endpoint said
`pro`.

### Live limits: `GET https://chatgpt.com/backend-api/codex/usage`

Verified 200. Response:

```
{
  "user_id": "...", "account_id": "...", "email": "...", "plan_type": "pro",
  "rate_limit": {
    "allowed": true, "limit_reached": false,
    "primary_window":   { "used_percent": 65, "limit_window_seconds": 604800,
                          "reset_after_seconds": 539029, "reset_at": 1786033302 },
    "secondary_window": null
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": [
    { "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
      "rate_limit": { ... same shape ... } }
  ],
  "credits": { "has_credits": false, "unlimited": false, "balance": "0",
               "approx_local_messages": [0,0], "approx_cloud_messages": [0,0],
               "overage_limit_reached": false },
  "spend_control": { "reached": false, "individual_limit": null },
  "rate_limit_reached_type": null,
  "promo": null,
  "rate_limit_reset_credits": { "available_count": 0, "applicable_available_count": 0 }
}
```

Conceptually one-to-one with Claude's `/api/oauth/usage`:

| Claude | Codex |
|---|---|
| `five_hour` / `seven_day` | `rate_limit.primary_window` / `secondary_window`, classified by `limit_window_seconds` |
| `limits[]` with `kind: weekly_scoped` (e.g. Fable 5) | `additional_rate_limits[]` (e.g. `GPT-5.3-Codex-Spark`) |
| `extra_usage` | `credits` |
| — | `spend_control`, `rate_limit_reached_type`, `promo` |

Critically, **windows are not named** — a window is identified by its length.
On the test machine `primary_window` was the 7-day window and `secondary_window`
was null; in older session snapshots `primary` was the 300-minute window and
`secondary` the 10080-minute one. Hardcoding "five hour" and "seven day" fields
the way the Claude models do would be wrong for Codex. Windows must be a list
classified by duration.

### Local fallback: `~/.codex/sessions/**/rollout-*.jsonl`

JSONL, one event per line. Relevant records:

- `event_msg` / `token_count` — carries `rate_limits` (same window shape as the
  live endpoint, with `window_minutes` instead of seconds) and, when non-null,
  `info.total_token_usage` with `input_tokens`, `cached_input_tokens`,
  `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`,
  `total_tokens`, plus `model_context_window`.
- `turn_context` — `model` (e.g. `gpt-5.6-sol`), `effort`, `cwd`.
- `event_msg` / `task_started` — one per turn.
- `custom_tool_call` with `name: apply_patch` — `input` is a `*** Begin Patch`
  payload; added lines are the `+`-prefixed ones.
- `session_meta` — `originator` (`Codex Desktop` / CLI), subagent lineage.

Measured on the test machine: **940 files, 2 059 MB**. An mtime-keyed
incremental cache is mandatory, exactly as `SessionParseCacheV2` does for
Claude.

`info.total_token_usage` is cumulative per session and was **strictly monotonic
across 23 063 events with zero regressions**, so per-event deltas of that
counter are a sound basis for daily attribution. Summing `last_token_usage`
instead is *not* sound: it overshoots the final cumulative total by roughly 6%
because streaming emits repeated events.

### Pricing

LiteLLM — already the project's price source — carries every OpenAI id Codex
uses, including `gpt-5.6-sol`, `gpt-5.6-luna`, `gpt-5.6-terra`, the
`gpt-5.x-codex` family, and `o3`. No new price table is needed; the fetch filter
and the loader filter widen to include OpenAI ids.

OpenAI billing differs from Anthropic in three ways that the cost math must respect:

1. `input_tokens` **includes** `cached_input_tokens`. Billable fresh input is
   `input - cached`; the cached part bills at `cache_read_input_token_cost`.
2. `output_tokens` **already includes** `reasoning_output_tokens`. Adding
   reasoning separately would double-count.
3. Cache writes are free — `cache_write_input_tokens` is 0 in practice. If a
   non-zero value ever appears it bills at `cache_creation_input_token_cost`
   when the model defines one, else 0.

### CLI surface

- `codex login` — browser OAuth, same shape as `claude auth login`.
- `codex login status` — read-only, prints `Logged in using ChatGPT`.
- `codex logout` — clears credentials.
- No usage/status subcommand, hence the endpoint above.

---

## Architecture

Chosen approach: a separate `CodexState` beside the existing `AppState`, with a
shared display layer. `AppState` keeps its Claude ownership and, crucially, its
credential self-heal, per-account back-off, and refresh-coalescing logic
untouched — that code is the most valuable and most fragile part of the project,
and Codex does not need any of it.

Extensibility comes from three explicit seams rather than from generalizing
`AppState`: a provider registry, normalized display models, and a theme.

### Component map

```
CCSwitcher/
  Providers/
    ProviderRegistry.swift        which providers exist on this machine
    ProviderSelection.swift       active provider, persisted
    ProviderHub.swift             the single EnvironmentObject views see
    ProviderSurface.swift         protocol every provider satisfies
    ProviderTheme.swift           per-provider color/background tokens
    Display/
      AccountHeaderModel.swift
      UsageCardModel.swift
      ActivitySummaryModel.swift
      CostSeriesModel.swift
      MenuBarSnapshot.swift
  Claude/
    ClaudeProviderSurface.swift   extension AppState: ProviderSurface (mapping only)
  Codex/
    CodexState.swift
    Services/
      CodexAuthService.swift      auth.json read/write, id_token claims, login/logout
      CodexAccountStore.swift     per-account auth.json backups in Keychain
      CodexUsageService.swift     live endpoint + local snapshot fallback
      CodexSessionCache.swift     incremental rollout-*.jsonl parser (cost + activity)
    Models/
      CodexUsageResponse.swift
      CodexRateLimitSnapshot.swift
      CodexTokenUsage.swift
```

### `ProviderSurface`

```swift
@MainActor
protocol ProviderSurface: AnyObject, ObservableObject {
    var providerType: AIProviderType { get }
    var isAvailable: Bool { get }
    var isLoading: Bool { get }
    var isAuthenticating: Bool { get }
    var errorMessage: String? { get }
    var lastRefresh: Date? { get }
    var capabilities: ProviderCapabilities { get }

    var header: AccountHeaderModel? { get }
    var accountCards: [UsageCardModel] { get }   // Usage tab
    var accountRows: [AccountRowModel] { get }   // Accounts tab
    var activity: ActivitySummaryModel { get }
    var cost: CostSeriesModel { get }

    func refresh(force: Bool) async
    func switchTo(accountId: UUID) async
    func importCurrentAccount() async            // adopt whoever the CLI is signed in as
    func loginNewAccount() async                 // browser OAuth for a new account
    func removeAccount(id: UUID)
    func reauthenticate(id: UUID) async
    func setLabel(_ label: String?, forAccount id: UUID)
}

struct ProviderCapabilities {
    let canSwitchAccounts: Bool
    let canImportCurrent: Bool
    let canLoginNewAccount: Bool
    let canReauthenticate: Bool
    let tracksLinesWritten: Bool
}
```

`importCurrentAccount` and `loginNewAccount` stay distinct because the existing
Claude UI offers both and they are genuinely different operations: one adopts the
account the CLI is already signed in as, the other runs a browser OAuth round
trip. Collapsing them would be a behaviour regression for Claude.

`capabilities` lets a view hide an action a provider cannot perform, instead of
each provider stubbing a method that silently does nothing.

### `ProviderHub`

SwiftUI cannot inject an `EnvironmentObject` by protocol existential, so a
concrete hub owns the surfaces and republishes their changes:

```swift
@MainActor
final class ProviderHub: ObservableObject {
    @Published private(set) var available: [AIProviderType]
    @Published var activeProvider: AIProviderType   // persisted to UserDefaults
    var surface: any ProviderSurface { surfaces[activeProvider]! }

    private var surfaces: [AIProviderType: any ProviderSurface]
    private var forwarders: [AnyCancellable]
}
```

The hub subscribes to each surface's `objectWillChange` and forwards it, so a
view observing only the hub still re-renders when Codex data lands. Adding a
provider is one dictionary entry plus one theme.

`activeProvider` falls back to the first available provider when the persisted
value refers to a provider that is no longer installed.

### Display models

These are the reason a third provider is cheap. They are expressed in concepts
common to every provider, not in Claude's field names.

```swift
struct UsageWindowModel: Identifiable {
    enum Kind { case session, weekly, other(seconds: Double) }
    let kind: Kind
    let label: String          // "Session", "Weekly", or a formatted duration
    let utilization: Double    // 0-100
    let resetsAt: Date?
    let windowSeconds: Double  // drives the usage-vs-time comparison bar
    var id: String { label }
}

struct ScopedLimitModel: Identifiable {
    let modelName: String      // "Fable 5" | "GPT-5.3-Codex-Spark"
    let utilization: Double
    let resetsAt: Date?
    let tint: Color            // provider supplies it; see note below
    var id: String { modelName }
}

struct ModelUsageEntry: Identifiable {
    let displayName: String    // "Opus" | "gpt-5.6-sol"
    let count: Int
    let tint: Color
    var id: String { displayName }
}

struct CreditPoolModel {
    let isEnabled: Bool
    let isUnlimited: Bool
    let balanceText: String?
    let utilization: Double?
}

struct UsageCardModel: Identifiable {
    let id: UUID               // Account.id
    let title: String          // effective display name
    let subtitle: String?      // email
    let planBadge: String?     // "Max" | "Pro"
    let isActive: Bool
    let windows: [UsageWindowModel]
    let scopedLimits: [ScopedLimitModel]
    let credits: CreditPoolModel?
    let warning: String?       // spend control reached, limit reached type
    let error: ProviderErrorModel?
}

struct ProviderErrorModel {
    let message: String
    let needsReauth: Bool
    let isRateLimited: Bool
}

struct ActivitySummaryModel {
    let turns: Int
    let activeTimeText: String
    let linesWritten: Int?     // nil when the provider cannot measure it
    let perModel: [ModelUsageEntry]   // display name, count, tint
}

struct CostSeriesModel {
    let todayCost: Double
    let daily: [DailyCostEntry]        // date, cost, per-model breakdown, tokens
}

struct AccountRowModel: Identifiable {
    let id: UUID
    let title: String
    let email: String
    let planBadge: String?
    let isActive: Bool
    let lastUsedText: String?
    let hasStoredCredentials: Bool
    let rawLabel: String?              // seeds the inline rename field
}
```

Window classification is a single shared function:
`≤ 6h → .session`, `6h … 8d → .weekly`, else `.other(seconds:)`. It is what lets
the same card render Claude's fixed five-hour/seven-day pair and Codex's
data-defined windows without a branch in the view.

`Kind` carries no text, only shape. The view resolves `.session` / `.weekly` to
localized strings and `.other` to a formatted duration, so localization stays in
the view layer instead of leaking into the models.

Model tints come from the provider rather than from a switch in the view. The
current `modelColor` maps Fable / Opus / Sonnet / Haiku, which is meaningless for
`gpt-5.6-sol`; each provider therefore supplies the tint alongside the name.

### `ProviderTheme`

```swift
struct ProviderTheme {
    enum PanelBackground { case material(Material), flat(Color) }
    let panel: PanelBackground
    let accent: Color
    let accentForeground: Color
    let cardFill, cardFillStrong, cardBorder: Color
    let textPrimary, textSecondary: Color
    let tabFill, tabBorder, tabSelectedFill, tabSelectedForeground: Color
    let progressTrack: Color
    let forcedColorScheme: ColorScheme?
}
```

Injected through `Environment` (`\.providerTheme`). The existing static
`Color.cardFill` family stays as the Claude theme's values, so nothing breaks
during the migration; components move onto the environment theme as they are
touched.

**Claude theme** — exactly today's look: `.material(.ultraThinMaterial)`,
accent `#E86D45`, adaptive light/dark, `forcedColorScheme = nil`.

**Codex theme** — modeled on ChatGPT Desktop:

| Token | Value |
|---|---|
| `panel` | `.flat(#0D0D0D)` |
| `cardFill` / `cardFillStrong` | `#171717` / `#1F1F1F` |
| `cardBorder` | `#2E2E2E` |
| `textPrimary` / `textSecondary` | `#ECECEC` / `#9A9A9A` |
| `tabFill` / `tabBorder` | `#161616` / `#2E2E2E` |
| `tabSelectedFill` / `tabSelectedForeground` | `#303030` / `#FFFFFF` |
| `progressTrack` | `#2A2A2A` |
| `accent` / `accentForeground` | `#FFFFFF` / `#0D0D0D` |
| `forcedColorScheme` | `.dark` |

No brand orange anywhere in Codex mode; the palette is monochrome. Utilization
bars keep their semantic ramp in both themes (green below 50%, amber 50–80%,
red above 80%), slightly desaturated in the Codex theme — a monochrome bar makes
the number unreadable at a glance, which is the whole point of the bar.

### Provider switcher

A compact icon segmented control in the top-right of the popover header. Renders
only when `ProviderRegistry` reports two or more available providers, so a
Claude-only machine sees today's header unchanged. Icons come from
`AIProviderType.iconName` (SF Symbols, no bundled assets). Selecting a provider
swaps the theme with a 0.2 s ease-in-out and persists the choice.

---

## Codex Data Flow

### Accounts

Codex accounts are `Account` values with `provider == .codex`, persisted under
their own key `com.ccswitcher.accounts.codex`. A separate key — not the existing
array — so `AppState.loadAccounts` and its `first(where: \.isActive)` logic can
never see a Codex row.

Backups live in the Keychain under service
`me.xueshi.ccswitcher.codex.backups`, storing the whole `auth.json` text per
account id. The file holds a refresh token, so Application Support is not an
acceptable home for it.

- **Add** — run `codex login` in the background (it opens the browser, same as
  the Claude flow), then read `auth.json`, extract email / `account_id` / plan
  from the `id_token` claims, create the `Account`, and back it up.
- **Switch** — verify the live file still belongs to the currently-active
  account, back it up, then write the target's backup atomically (temp file +
  `rename`, mode `0600`).
- **Remove** — drop the Keychain backup and the row.
- **Reauthenticate** — `codex login`, then require the resulting email to match
  the target account before overwriting its backup.

**Desync guard, deliberately gentler than Claude's.** Before using the live
`auth.json` we compare its `tokens.account_id` and `id_token` email against the
active account's backup. On mismatch we do *not* restore over it: unlike the
Claude keychain case, a mismatch here most likely means the user legitimately
switched accounts inside Codex Desktop, and clobbering that would fight the
user. Instead we re-point our notion of "active" at whichever known account is
actually in the file, and show a one-line banner if it is an account we have
never seen.

### Usage

Primary source is the live endpoint, per account:

- Active account uses the live `auth.json` access token; inactive accounts use
  the token from their backup, which stays valid for 10 days.
- Headers: `Authorization: Bearer <access_token>` and
  `chatgpt-account-id: <account_id>`. The minimal accepted header set is
  established empirically during implementation, preferring an honest
  `CCSwitcher/<version>` user agent over impersonating the CLI, and only adding
  `originator: codex_cli_rs` if the endpoint demands it.
- `401` → mark the account as needing re-auth with a button that runs
  `codex login`. We never issue a refresh grant. This is the same call the
  project already made for Claude, and here it costs almost nothing because the
  token lasts 10 days.
- `429` → per-account back-off that keeps the previously fetched numbers
  visible, mirroring the Claude behaviour.
- Offline / endpoint failure → fall back to the newest `rate_limits` snapshot
  found in the most recent rollout file, flagged as stale in the UI. A
  last-known response is also cached on disk so the popover is populated before
  the first fetch completes, mirroring `hydrateFromWidgetCache`.

Mapping to display models: each non-null window is classified by
`limit_window_seconds`; `additional_rate_limits[]` become `ScopedLimitModel`s
keyed on `limit_name`; `credits` becomes `CreditPoolModel`;
`rate_limit_reached_type` and `spend_control.reached` become the card warning.

### Cost and activity

`CodexSessionCache` mirrors `SessionParseCacheV2`'s proven shape: an actor, a
per-file cache keyed by path plus mtime, stored at
`~/Library/Application Support/CCSwitcher/codex-session-cache.json`, holding
already-aggregated per-date / per-model values so unchanged files are never
re-read. With 2 GB of rollouts on a real machine this is the difference between
a responsive app and a CPU-pegged one.

Per file:

- Walk events in order, tracking the current model from the latest
  `turn_context`.
- On each `token_count` with non-null `info`, take the **delta** of
  `total_token_usage` against the previous event in that file and attribute it
  to the event timestamp's local date and the current model. A negative delta
  (never observed, but cheap to guard) restarts the baseline instead of
  producing negative cost.
- Cost per delta: `(input - cached) * inputRate + cached * cacheReadRate +
  output * outputRate`, plus cache-write at the creation rate only when
  non-zero. `reasoning_output_tokens` is not added — it is already inside
  `output_tokens`.
- Turns: count `task_started` events.
- Active minutes: reuse the existing gap-based `calculateActiveMinutes` over
  event timestamps.
- Lines written: sum `+`-prefixed lines (excluding `+++`) from `apply_patch`
  tool-call inputs.

Pricing widens in two places: `Tools/fetch_litellm.sh` keeps OpenAI ids
alongside Claude ones, and `PricingService`'s validation filter becomes
provider-aware with a per-provider minimum row count, so a wrong-shape 200
response still cannot zero out prices.

### Menu bar

The strip renders the active provider only, so its width does not grow.
`MenuBarModule` case semantics generalize while raw values stay put for
settings compatibility: `sessionBar`/`sessionBarPlain` mean "short window",
`weeklyBar`/`weeklyBarPlain` mean "weekly window", and the compact label is
derived from the actual window length rather than the literal strings `5H`/`7D`.
A new `scopedLimitBar` case surfaces the first scoped limit (Fable 5 for Claude,
`GPT-5.3-Codex-Spark` for Codex) — something the current build cannot show at
all. Module selection is stored per provider: `menuBarModules` stays Claude's
key for backward compatibility, Codex uses `menuBarModules.codex`.

### Widget

`WidgetData` gains the active provider and its theme, and shows that provider's
accounts. Scheduled last, because it is the only piece with no in-app fallback
if it regresses.

---

## Settings

A `Codex CLI` tab mirroring `ClaudeCLITabView` (binary path, detected version,
login status, sign in / sign out). The existing `Menu Bar` tab gains a provider
picker above the module list so each provider's strip is configured separately.

---

## Testing

`project.yml` has no test target today; one is added (`CCSwitcherTests`,
`type: bundle.unit-test`) covering the pure functions where correctness is
actually at risk:

- Window classification from `limit_window_seconds` and `window_minutes`.
- `CodexUsageResponse` → `UsageCardModel` mapping, including a null
  `secondary_window`, populated `additional_rate_limits`, and `credits`.
- `id_token` claim extraction, including an expired token (claims must still
  parse) and a malformed one.
- Rollout delta accounting on a committed fixture: monotonic counters, a
  mid-session model switch, a synthetic counter regression.
- OpenAI cost math: cached-input subtraction, reasoning not double-counted,
  zero cache-write.
- `apply_patch` added-line counting, including `+++` exclusion.
- Claude display-model mapping, to prove the seam did not change existing
  numbers.

UI layout stays unverified by tests, as it is today.

---

## Delivery Stages

Each stage is independently shippable and verifiable.

**Stage 1 — Seams, no behaviour change.** `ProviderRegistry`,
`ProviderSelection`, `ProviderHub`, `ProviderSurface`, display models,
`ProviderTheme`, `extension AppState: ProviderSurface`, and the migration of
`UsageDashboardView`, `CostDetailView`, `AccountSwitcherView` and
`MenuBarModuleView` onto display models. Success criterion: the app looks and
behaves exactly as before, with Claude values identical to the previous build.

**Stage 2 — Codex, read-only.** `CodexAuthService`, `CodexUsageService` (live
plus fallback), `CodexSessionCache`, `CodexState`, the Codex theme, and the
header switcher. Codex usage, cost and activity are visible; account switching
is not yet offered (`capabilities.canSwitchAccounts == false`).

**Stage 3 — Codex account switching.** `CodexAccountStore`, `auth.json`
swapping, `codex login` / `logout` integration, the desync guard, and the
`Codex CLI` settings tab.

**Stage 4 — Menu bar and widget.** Per-provider module configuration, the
generalized labels, `scopedLimitBar`, and provider-aware `WidgetData`.

## Risks

- **View-layer migration is the bulk of Stage 1** — roughly a thousand lines of
  view code moving onto display models. No logic risk, but it is where a visual
  regression would hide. Mitigated by the Claude mapping tests and by comparing
  against the current build before merging.
- **The usage endpoint is undocumented.** It can change or start requiring
  headers we do not send. Mitigated by the local rollout fallback, which is
  derived from files Codex writes for its own use and is therefore far more
  stable.
- **`codex login` is interactive by nature.** It opens a browser; the Claude
  flow already proves the background-process pattern works, but Codex's exact
  non-interactive behaviour has to be confirmed during Stage 3 rather than
  assumed.
- **Session volume grows.** 2 GB today. The cache handles steady state, but the
  very first parse on a large install is expensive and must run off the main
  thread with the UI showing partial data, as the Claude parser already does.
