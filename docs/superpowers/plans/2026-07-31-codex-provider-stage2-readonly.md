# Codex Provider — Stage 2: Read-Only Codex Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Codex usage limits, API-equivalent cost and activity in the popover, with the near-black Codex theme and a provider switcher in the header. Account switching is deliberately not offered yet.

**Architecture:** A new `CodexState` implements the `ProviderSurface` protocol built in Stage 1. Limits come from the live `GET /backend-api/codex/usage` endpoint, falling back to the last `rate_limits` snapshot Codex itself wrote into its rollout files. Cost and activity come from an mtime-keyed incremental parse of `~/.codex/sessions/**/rollout-*.jsonl`, priced with the LiteLLM table the app already ships.

**Tech Stack:** Swift 6 (`SWIFT_STRICT_CONCURRENCY: targeted`), SwiftUI, `URLSession`, Swift actors, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-31-codex-provider-design.md`
**Prerequisite:** Stage 1 complete (`docs/superpowers/plans/2026-07-31-codex-provider-stage1-seams.md`).

---

## Ground Rules For Every Task

- **Never edit `CCSwitcher.xcodeproj/project.pbxproj` or `Info.plist` directly.** Change `project.yml`, then run `xcodegen generate`.
- Run `xcodegen generate` after adding any new `.swift` file, before building.
- Build: `xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5`
- Test: `xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/<TestClass> 2>&1 | tail -20`
- Standard DerivedData only. No `-derivedDataPath`, never `/tmp`.
- **Nothing in this stage writes to `~/.codex`.** Every filesystem access is read-only. Writing is Stage 3.
- **Never issue an OAuth refresh grant.** The Codex access token lives 10 days and the Codex CLI owns refreshing it. On expiry we surface a re-auth prompt.
- Commit messages: one imperative line, English, no body, no backticks, no `Co-Authored-By`.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `CCSwitcher/Codex/Models/CodexAuth.swift` | `auth.json` shape and `id_token` claims |
| `CCSwitcher/Codex/Models/CodexUsageResponse.swift` | Live endpoint payload |
| `CCSwitcher/Codex/Models/CodexRateLimitSnapshot.swift` | Normalized limits from either source |
| `CCSwitcher/Codex/Models/CodexTokenTotals.swift` | Token counters and per-file aggregates |
| `CCSwitcher/Codex/Services/CodexAuthService.swift` | Locate and read credentials, decode claims |
| `CCSwitcher/Codex/Services/CodexUsageService.swift` | Live fetch, local fallback, disk cache |
| `CCSwitcher/Codex/Services/CodexRolloutParser.swift` | Pure per-file rollout parsing |
| `CCSwitcher/Codex/Services/CodexSessionCache.swift` | Actor, mtime-keyed incremental aggregation |
| `CCSwitcher/Codex/CodexDisplayMapper.swift` | Codex → display models |
| `CCSwitcher/Codex/CodexState.swift` | `ProviderSurface` implementation |
| `CCSwitcher/Views/ProviderSwitcherView.swift` | Header segmented control |
| `CCSwitcherTests/CodexAuthTests.swift` | Claims decoding, expiry tolerance, malformed input |
| `CCSwitcherTests/CodexUsageMappingTests.swift` | Endpoint payload → display models |
| `CCSwitcherTests/CodexRolloutParserTests.swift` | Deltas, model switching, lines, turns |
| `CCSwitcherTests/OpenAICostTests.swift` | OpenAI-shaped cost math and model resolution |
| `CCSwitcherTests/Fixtures/codex-usage.json` | Real endpoint response, identifiers scrubbed |
| `CCSwitcherTests/Fixtures/codex-rollout.jsonl` | Hand-built rollout covering the tricky cases |

**Modified:**

| Path | Change |
|---|---|
| `project.yml` | Add the fixtures folder as a test resource |
| `Tools/fetch_litellm.sh` | Keep OpenAI rows alongside Claude rows |
| `CCSwitcher/Services/PricingService.swift` | Provider-aware filter, OpenAI prefixes, OpenAI cost math |
| `CCSwitcher/Providers/ProviderTheme.swift` | Add the Codex theme |
| `CCSwitcher/CCSwitcherApp.swift` | Register `CodexState` with the hub |
| `CCSwitcher/Views/MainMenuView.swift` | Place the switcher in the header |

---

### Task 1: Codex credential reading

**Files:**
- Create: `CCSwitcher/Codex/Models/CodexAuth.swift`
- Create: `CCSwitcher/Codex/Services/CodexAuthService.swift`
- Test: `CCSwitcherTests/CodexAuthTests.swift`

- [ ] **Step 1: Write the failing test**

Create `CCSwitcherTests/CodexAuthTests.swift`:

```swift
import XCTest
@testable import CCSwitcher

final class CodexAuthTests: XCTestCase {

    /// Builds an unsigned JWT with the given payload. Only the payload segment
    /// matters: we read claims as metadata and never verify the signature,
    /// because the authoritative email and plan come from the live endpoint.
    private func makeJWT(payload: [String: Any]) -> String {
        let json = try! JSONSerialization.data(withJSONObject: payload)
        let body = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(body).sig"
    }

    private func authJSON(idToken: String, accessToken: String = "access", accountId: String = "acct-1") -> String {
        """
        {
          "auth_mode": "chatgpt",
          "OPENAI_API_KEY": null,
          "tokens": {
            "id_token": "\(idToken)",
            "access_token": "\(accessToken)",
            "refresh_token": "refresh",
            "account_id": "\(accountId)"
          },
          "last_refresh": "2026-07-30T16:11:56.249967Z"
        }
        """
    }

    private let fullClaims: [String: Any] = [
        "email": "user@example.com",
        "name": "Example User",
        "exp": 1_785_431_516,
        "https://api.openai.com/auth": [
            "chatgpt_account_id": "acct-1",
            "chatgpt_plan_type": "pro",
            "organizations": [["id": "org-1", "is_default": true, "title": "Personal", "role": "owner"]]
        ]
    ]

    func testParsesTokensAndAccountId() throws {
        let json = authJSON(idToken: makeJWT(payload: fullClaims))
        let auth = try CodexAuthService.decode(authJSON: Data(json.utf8))
        XCTAssertEqual(auth.tokens.accessToken, "access")
        XCTAssertEqual(auth.tokens.accountId, "acct-1")
        XCTAssertEqual(auth.authMode, "chatgpt")
    }

    func testExtractsEmailNameAndPlanFromClaims() throws {
        let json = authJSON(idToken: makeJWT(payload: fullClaims))
        let auth = try CodexAuthService.decode(authJSON: Data(json.utf8))
        let claims = CodexAuthService.claims(fromIDToken: auth.tokens.idToken)
        XCTAssertEqual(claims?.email, "user@example.com")
        XCTAssertEqual(claims?.name, "Example User")
        XCTAssertEqual(claims?.planType, "pro")
    }

    /// The id_token expires after one hour, so an expired token is the normal
    /// case, not an error. Claims must still parse.
    func testExpiredIDTokenStillYieldsClaims() throws {
        var expired = fullClaims
        expired["exp"] = 1_000_000
        let json = authJSON(idToken: makeJWT(payload: expired))
        let auth = try CodexAuthService.decode(authJSON: Data(json.utf8))
        XCTAssertEqual(CodexAuthService.claims(fromIDToken: auth.tokens.idToken)?.email, "user@example.com")
    }

    func testMalformedIDTokenYieldsNilClaimsWithoutThrowing() throws {
        let json = authJSON(idToken: "not-a-jwt")
        let auth = try CodexAuthService.decode(authJSON: Data(json.utf8))
        XCTAssertNil(CodexAuthService.claims(fromIDToken: auth.tokens.idToken))
    }

    func testClaimsWithoutPlanTypeYieldNilPlan() throws {
        let json = authJSON(idToken: makeJWT(payload: ["email": "a@b.c"]))
        let auth = try CodexAuthService.decode(authJSON: Data(json.utf8))
        let claims = CodexAuthService.claims(fromIDToken: auth.tokens.idToken)
        XCTAssertEqual(claims?.email, "a@b.c")
        XCTAssertNil(claims?.planType)
        XCTAssertNil(claims?.name)
    }

    func testMissingTokensBlockThrows() {
        let json = #"{ "auth_mode": "chatgpt" }"#
        XCTAssertThrowsError(try CodexAuthService.decode(authJSON: Data(json.utf8)))
    }

    func testAccessTokenExpiryIsReadFromItsOwnClaims() throws {
        let access = makeJWT(payload: ["exp": 4_000_000_000])
        let json = authJSON(idToken: makeJWT(payload: fullClaims), accessToken: access)
        let auth = try CodexAuthService.decode(authJSON: Data(json.utf8))
        XCTAssertFalse(CodexAuthService.isAccessTokenExpired(auth.tokens.accessToken))
    }

    func testExpiredAccessTokenIsDetected() throws {
        let access = makeJWT(payload: ["exp": 1_000_000])
        let json = authJSON(idToken: makeJWT(payload: fullClaims), accessToken: access)
        let auth = try CodexAuthService.decode(authJSON: Data(json.utf8))
        XCTAssertTrue(CodexAuthService.isAccessTokenExpired(auth.tokens.accessToken))
    }

    /// An opaque (non-JWT) access token cannot be pre-validated, so we must
    /// assume it is usable and let the endpoint decide. Treating it as expired
    /// would lock the user out of a working session.
    func testOpaqueAccessTokenIsNotTreatedAsExpired() throws {
        let json = authJSON(idToken: makeJWT(payload: fullClaims), accessToken: "opaque-token")
        let auth = try CodexAuthService.decode(authJSON: Data(json.utf8))
        XCTAssertFalse(CodexAuthService.isAccessTokenExpired(auth.tokens.accessToken))
    }

    func testFingerprintCombinesAccountIdAndEmail() throws {
        let json = authJSON(idToken: makeJWT(payload: fullClaims), accountId: "acct-9")
        let auth = try CodexAuthService.decode(authJSON: Data(json.utf8))
        XCTAssertEqual(CodexAuthService.fingerprint(for: auth), "acct-9|user@example.com")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/CodexAuthTests 2>&1 | tail -20
```

Expected: compile failure, `cannot find 'CodexAuthService' in scope`.

- [ ] **Step 3: Create the models**

Create `CCSwitcher/Codex/Models/CodexAuth.swift`:

```swift
import Foundation

/// Contents of `~/.codex/auth.json`, written and refreshed by the Codex CLI.
struct CodexAuth: Codable, Sendable {
    struct Tokens: Codable, Sendable {
        let idToken: String
        let accessToken: String
        let refreshToken: String?
        let accountId: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accountId = "account_id"
        }
    }

    let authMode: String?
    let tokens: Tokens
    let lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

/// Claims we care about from the `id_token`. Read as metadata only — the
/// signature is never verified, and the token's one-hour lifetime means it is
/// usually expired. Authoritative email and plan come from the live usage
/// endpoint, which was observed reporting `pro` while this said `prolite`.
struct CodexIDTokenClaims: Sendable {
    let email: String?
    let name: String?
    let planType: String?
    let chatgptAccountId: String?
}
```

- [ ] **Step 4: Create the service**

Create `CCSwitcher/Codex/Services/CodexAuthService.swift`:

```swift
import Foundation

private let log = FileLog("CodexAuth")

/// Reads Codex credentials. Stage 2 is strictly read-only; writing arrives in
/// stage 3 together with account switching.
enum CodexAuthService {

    enum AuthError: LocalizedError {
        case notFound
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notFound: return "Codex credentials not found at ~/.codex/auth.json"
            case .unreadable(let detail): return "Could not read Codex credentials: \(detail)"
            }
        }
    }

    static var authPath: String { ProviderRegistry.codexAuthPath }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: authPath)
    }

    /// Reads and decodes the live credential file.
    static func loadCurrent() throws -> CodexAuth {
        guard let data = FileManager.default.contents(atPath: authPath) else {
            throw AuthError.notFound
        }
        return try decode(authJSON: data)
    }

    static func decode(authJSON data: Data) throws -> CodexAuth {
        do {
            return try JSONDecoder().decode(CodexAuth.self, from: data)
        } catch {
            throw AuthError.unreadable(error.localizedDescription)
        }
    }

    /// Decodes a JWT payload without verifying the signature. Returns nil for
    /// anything that is not a three-part JWT with a JSON payload.
    static func claims(fromIDToken token: String) -> CodexIDTokenClaims? {
        guard let payload = jwtPayload(token) else { return nil }
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        return CodexIDTokenClaims(
            email: payload["email"] as? String,
            name: payload["name"] as? String,
            planType: auth?["chatgpt_plan_type"] as? String,
            chatgptAccountId: auth?["chatgpt_account_id"] as? String
        )
    }

    /// True only when the token is a JWT whose `exp` has passed. An opaque token
    /// is reported as not expired: we cannot know, and pretending otherwise
    /// would lock the user out of a working session. The endpoint decides.
    static func isAccessTokenExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let payload = jwtPayload(token), let exp = payload["exp"] as? Double else { return false }
        return Date(timeIntervalSince1970: exp) <= now
    }

    /// Identity of the account the credentials belong to. Used in stage 3 to
    /// detect that the CLI or Desktop app swapped accounts underneath us.
    static func fingerprint(for auth: CodexAuth) -> String {
        let accountId = auth.tokens.accountId ?? claims(fromIDToken: auth.tokens.idToken)?.chatgptAccountId ?? "?"
        let email = claims(fromIDToken: auth.tokens.idToken)?.email ?? "?"
        return "\(accountId)|\(email)"
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Base64url drops padding; JSONSerialization needs it back.
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.debug("jwtPayload: token is not a decodable JWT")
            return nil
        }
        return object
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/CodexAuthTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 11 tests.

- [ ] **Step 6: Commit**

```bash
git add CCSwitcher/Codex CCSwitcherTests/CodexAuthTests.swift
git commit -m "Read Codex credentials and id token claims"
```

---

### Task 2: Usage payload and display mapping

**Files:**
- Create: `CCSwitcher/Codex/Models/CodexUsageResponse.swift`
- Create: `CCSwitcher/Codex/Models/CodexRateLimitSnapshot.swift`
- Create: `CCSwitcher/Codex/CodexDisplayMapper.swift`
- Create: `CCSwitcherTests/Fixtures/codex-usage.json`
- Test: `CCSwitcherTests/CodexUsageMappingTests.swift`
- Modify: `project.yml`

- [ ] **Step 1: Add the fixture**

Create `CCSwitcherTests/Fixtures/codex-usage.json` — the live response captured from the endpoint, with identifiers scrubbed:

```json
{
  "user_id": "user-EXAMPLE",
  "account_id": "user-EXAMPLE",
  "email": "user@example.com",
  "plan_type": "pro",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 65,
      "limit_window_seconds": 604800,
      "reset_after_seconds": 539029,
      "reset_at": 1786033302
    },
    "secondary_window": null
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": [
    {
      "limit_name": "GPT-5.3-Codex-Spark",
      "metered_feature": "codex_bengalfox",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 12,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 604800,
          "reset_at": 1786099073
        },
        "secondary_window": null
      }
    }
  ],
  "credits": {
    "has_credits": false,
    "unlimited": false,
    "overage_limit_reached": false,
    "balance": "0",
    "approx_local_messages": [0, 0],
    "approx_cloud_messages": [0, 0]
  },
  "spend_control": { "reached": false, "individual_limit": null },
  "rate_limit_reached_type": null,
  "promo": null,
  "rate_limit_reset_credits": { "available_count": 0, "applicable_available_count": 0 }
}
```

Register it as a test resource. In `project.yml`, change the `CCSwitcherTests` target's `sources` to:

```yaml
    sources:
      - path: CCSwitcherTests
        excludes:
          - "Fixtures"
      - path: CCSwitcherTests/Fixtures
        type: folder
        buildPhase: resources
```

`type: folder` copies the directory as a blue folder reference so `Bundle(for:).url(forResource:subdirectory:)` finds the files.

- [ ] **Step 2: Write the failing test**

Create `CCSwitcherTests/CodexUsageMappingTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import CCSwitcher

final class CodexUsageMappingTests: XCTestCase {

    private func loadFixture() throws -> CodexUsageResponse {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "codex-usage", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "codex-usage", withExtension: "json") else {
            XCTFail("codex-usage.json fixture not found in the test bundle")
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(CodexUsageResponse.self, from: Data(contentsOf: url))
    }

    func testDecodesLiveFixture() throws {
        let usage = try loadFixture()
        XCTAssertEqual(usage.planType, "pro")
        XCTAssertEqual(usage.email, "user@example.com")
        XCTAssertEqual(usage.rateLimit?.primaryWindow?.usedPercent, 65)
        XCTAssertNil(usage.rateLimit?.secondaryWindow)
        XCTAssertEqual(usage.additionalRateLimits?.count, 1)
    }

    /// The 7-day window arrived in the `primary` slot on the real account, so
    /// classification must key off duration, never off slot name.
    func testPrimarySevenDayWindowMapsToWeekly() throws {
        let windows = CodexDisplayMapper.windows(from: try loadFixture())
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].kind, .weekly)
        XCTAssertEqual(windows[0].utilization, 65)
        XCTAssertEqual(windows[0].windowSeconds, 604_800)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_786_033_302))
    }

    func testBothWindowsMapAndSortSessionFirst() throws {
        let json = """
        { "rate_limit": { "primary_window": { "used_percent": 10, "limit_window_seconds": 604800, "reset_at": 100 },
                          "secondary_window": { "used_percent": 2, "limit_window_seconds": 18000, "reset_at": 50 } } }
        """
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        let windows = CodexDisplayMapper.windows(from: usage)
        XCTAssertEqual(windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(windows[0].utilization, 2)
        XCTAssertEqual(windows[1].utilization, 10)
    }

    func testAdditionalRateLimitBecomesScopedLimit() throws {
        let scoped = CodexDisplayMapper.scopedLimits(from: try loadFixture())
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped[0].modelName, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(scoped[0].utilization, 12)
        XCTAssertEqual(scoped[0].resetsAt, Date(timeIntervalSince1970: 1_786_099_073))
    }

    func testAdditionalLimitWithoutWindowIsSkipped() throws {
        let json = """
        { "additional_rate_limits": [ { "limit_name": "Ghost", "rate_limit": { "primary_window": null } } ] }
        """
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        XCTAssertTrue(CodexDisplayMapper.scopedLimits(from: usage).isEmpty)
    }

    func testCreditsWithZeroBalanceIsDisabled() throws {
        let credits = CodexDisplayMapper.credits(from: try loadFixture())
        XCTAssertNotNil(credits)
        XCTAssertFalse(credits!.isEnabled)
        XCTAssertFalse(credits!.isUnlimited)
    }

    func testUnlimitedCreditsAreReportedAsUnlimited() throws {
        let json = #"{ "credits": { "has_credits": true, "unlimited": true, "balance": "0" } }"#
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        let credits = CodexDisplayMapper.credits(from: usage)
        XCTAssertTrue(credits!.isUnlimited)
        XCTAssertTrue(credits!.isEnabled)
    }

    func testPositiveBalanceIsSurfacedAsText() throws {
        let json = #"{ "credits": { "has_credits": true, "unlimited": false, "balance": "12.50" } }"#
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(CodexDisplayMapper.credits(from: usage)?.balanceText, "12.50")
    }

    func testNoticeIsNilWhenNothingIsWrong() throws {
        XCTAssertNil(CodexDisplayMapper.notice(from: try loadFixture(), isStale: false))
    }

    func testStaleSnapshotProducesNotice() throws {
        XCTAssertNotNil(CodexDisplayMapper.notice(from: try loadFixture(), isStale: true))
    }

    func testSpendControlReachedProducesNotice() throws {
        let json = #"{ "spend_control": { "reached": true, "individual_limit": 50 } }"#
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(CodexDisplayMapper.notice(from: usage, isStale: false))
    }

    func testRateLimitReachedTypeProducesNotice() throws {
        let json = #"{ "rate_limit_reached_type": "weekly" }"#
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(CodexDisplayMapper.notice(from: usage, isStale: false))
    }

    func testPlanBadgeIsCapitalized() {
        XCTAssertEqual(CodexDisplayMapper.planBadge(from: "pro"), "Pro")
        XCTAssertEqual(CodexDisplayMapper.planBadge(from: "prolite"), "Prolite")
        XCTAssertNil(CodexDisplayMapper.planBadge(from: nil))
    }

    /// Rollout files carry window lengths in minutes rather than seconds.
    func testLocalSnapshotConvertsWindowMinutes() {
        let snapshot = CodexRateLimitSnapshot(
            windows: [.init(usedPercent: 2, windowSeconds: 300 * 60, resetAt: Date(timeIntervalSince1970: 42))],
            scoped: [],
            planType: "plus",
            creditsBalance: nil,
            hasCredits: false,
            unlimitedCredits: false,
            reachedType: nil,
            spendControlReached: false
        )
        let windows = CodexDisplayMapper.windows(from: snapshot)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].kind, .session)
        XCTAssertEqual(windows[0].windowSeconds, 18_000)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/CodexUsageMappingTests 2>&1 | tail -20
```

Expected: compile failure, `cannot find 'CodexUsageResponse' in scope`.

- [ ] **Step 4: Create the response model**

Create `CCSwitcher/Codex/Models/CodexUsageResponse.swift`:

```swift
import Foundation

/// Payload of `GET https://chatgpt.com/backend-api/codex/usage`.
///
/// Every field is optional. The endpoint is undocumented, so a missing or
/// renamed key must degrade one row rather than fail the whole decode.
struct CodexUsageResponse: Codable, Sendable {
    struct Window: Codable, Sendable {
        let usedPercent: Double?
        let limitWindowSeconds: Double?
        let resetAfterSeconds: Double?
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }

        var resetDate: Date? { resetAt.map { Date(timeIntervalSince1970: $0) } }
    }

    struct RateLimit: Codable, Sendable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct AdditionalLimit: Codable, Sendable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }
    }

    struct Credits: Codable, Sendable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let overageLimitReached: Bool?
        let balance: String?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case overageLimitReached = "overage_limit_reached"
            case balance
        }
    }

    struct SpendControl: Codable, Sendable {
        let reached: Bool?
        let individualLimit: Double?

        enum CodingKeys: String, CodingKey {
            case reached
            case individualLimit = "individual_limit"
        }
    }

    let userId: String?
    let accountId: String?
    let email: String?
    let planType: String?
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalLimit]?
    let credits: Credits?
    let spendControl: SpendControl?
    let rateLimitReachedType: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case accountId = "account_id"
        case email
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case spendControl = "spend_control"
        case rateLimitReachedType = "rate_limit_reached_type"
    }
}
```

- [ ] **Step 5: Create the normalized snapshot**

Create `CCSwitcher/Codex/Models/CodexRateLimitSnapshot.swift`:

```swift
import Foundation

/// Limits reduced to one shape regardless of source: the live endpoint (seconds)
/// or a rollout file's `rate_limits` block (minutes). Codable so the last known
/// value survives app restarts and the popover is never blank on launch.
struct CodexRateLimitSnapshot: Codable, Sendable {
    struct Window: Codable, Sendable {
        let usedPercent: Double
        let windowSeconds: Double
        let resetAt: Date?
    }

    struct Scoped: Codable, Sendable {
        let name: String
        let usedPercent: Double
        let windowSeconds: Double
        let resetAt: Date?
    }

    let windows: [Window]
    let scoped: [Scoped]
    let planType: String?
    let creditsBalance: String?
    let hasCredits: Bool
    let unlimitedCredits: Bool
    let reachedType: String?
    let spendControlReached: Bool

    static let empty = CodexRateLimitSnapshot(
        windows: [], scoped: [], planType: nil, creditsBalance: nil,
        hasCredits: false, unlimitedCredits: false, reachedType: nil, spendControlReached: false
    )
}

extension CodexRateLimitSnapshot {
    /// Build from the live endpoint payload.
    init(response: CodexUsageResponse) {
        var windows: [Window] = []
        for candidate in [response.rateLimit?.secondaryWindow, response.rateLimit?.primaryWindow] {
            guard let candidate, let seconds = candidate.limitWindowSeconds else { continue }
            windows.append(Window(
                usedPercent: candidate.usedPercent ?? 0,
                windowSeconds: seconds,
                resetAt: candidate.resetDate
            ))
        }
        // Shortest window first, so a session bar always renders above a weekly
        // one no matter which slot the endpoint used.
        windows.sort { $0.windowSeconds < $1.windowSeconds }

        let scoped: [Scoped] = (response.additionalRateLimits ?? []).compactMap { limit in
            guard let name = limit.limitName,
                  let window = limit.rateLimit?.primaryWindow ?? limit.rateLimit?.secondaryWindow,
                  let seconds = window.limitWindowSeconds else { return nil }
            return Scoped(
                name: name,
                usedPercent: window.usedPercent ?? 0,
                windowSeconds: seconds,
                resetAt: window.resetDate
            )
        }

        let balance = response.credits?.balance
        let hasCredits = response.credits?.hasCredits == true
        let unlimited = response.credits?.unlimited == true

        self.init(
            windows: windows,
            scoped: scoped,
            planType: response.planType,
            creditsBalance: (hasCredits && !unlimited) ? balance : nil,
            hasCredits: hasCredits,
            unlimitedCredits: unlimited,
            reachedType: response.rateLimitReachedType,
            spendControlReached: response.spendControl?.reached == true
        )
    }
}
```

- [ ] **Step 6: Create the display mapper**

Create `CCSwitcher/Codex/CodexDisplayMapper.swift`:

```swift
import SwiftUI

/// Codex-to-display-model mapping. Pure and free of actor isolation so the
/// numbers the UI shows are pinned by unit tests.
enum CodexDisplayMapper {

    /// Stable per-model tints. Codex model names are open-ended (`gpt-5.6-sol`,
    /// `gpt-5.6-luna`, future ids), so the colour is derived from the name's
    /// hash rather than enumerated — a fixed switch would silently grey out
    /// every model released after this build.
    static func tint(forModel name: String) -> Color {
        let palette: [Color] = [.teal, .purple, .blue, .green, .pink, .orange, .indigo]
        var hash = 5381
        for byte in name.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }

    static func planBadge(from planType: String?) -> String? {
        guard let planType, !planType.isEmpty else { return nil }
        return planType.prefix(1).uppercased() + planType.dropFirst()
    }

    static func windows(from snapshot: CodexRateLimitSnapshot) -> [UsageWindowModel] {
        snapshot.windows.map { window in
            UsageWindowModel(
                kind: UsageWindowModel.Kind(windowSeconds: window.windowSeconds),
                utilization: window.usedPercent,
                resetsAt: window.resetAt,
                windowSeconds: window.windowSeconds
            )
        }
    }

    static func windows(from response: CodexUsageResponse) -> [UsageWindowModel] {
        windows(from: CodexRateLimitSnapshot(response: response))
    }

    static func scopedLimits(from snapshot: CodexRateLimitSnapshot) -> [ScopedLimitModel] {
        snapshot.scoped.map { entry in
            ScopedLimitModel(
                modelName: entry.name,
                utilization: entry.usedPercent,
                resetsAt: entry.resetAt,
                tint: tint(forModel: entry.name)
            )
        }
    }

    static func scopedLimits(from response: CodexUsageResponse) -> [ScopedLimitModel] {
        scopedLimits(from: CodexRateLimitSnapshot(response: response))
    }

    static func credits(from snapshot: CodexRateLimitSnapshot) -> CreditPoolModel? {
        // A plan with no credit pool at all still reports the block with
        // has_credits false, so always show the row for parity with Claude's
        // "Extra usage Off".
        CreditPoolModel(
            isEnabled: snapshot.hasCredits || snapshot.unlimitedCredits,
            isUnlimited: snapshot.unlimitedCredits,
            balanceText: snapshot.creditsBalance,
            utilization: nil
        )
    }

    static func credits(from response: CodexUsageResponse) -> CreditPoolModel? {
        guard response.credits != nil else { return nil }
        return credits(from: CodexRateLimitSnapshot(response: response))
    }

    static func notice(from snapshot: CodexRateLimitSnapshot, isStale: Bool) -> String? {
        if snapshot.spendControlReached {
            return String(localized: "Spend limit reached.", bundle: L10n.bundle)
        }
        if let reached = snapshot.reachedType {
            return String(localized: "Rate limit reached (\(reached)).", bundle: L10n.bundle)
        }
        if isStale {
            return String(localized: "Showing the last snapshot Codex wrote locally.", bundle: L10n.bundle)
        }
        return nil
    }

    static func notice(from response: CodexUsageResponse, isStale: Bool) -> String? {
        notice(from: CodexRateLimitSnapshot(response: response), isStale: isStale)
    }
}
```

- [ ] **Step 7: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/CodexUsageMappingTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 14 tests.

If the fixture is not found, verify with:

```bash
find ~/Library/Developer/Xcode/DerivedData/CCSwitcher-*/Build/Products/Debug -name "codex-usage.json"
```

and adjust the `project.yml` resource declaration until it appears inside `CCSwitcherTests.xctest/Contents/Resources/`.

- [ ] **Step 8: Commit**

```bash
git add CCSwitcher/Codex CCSwitcherTests project.yml
git commit -m "Map Codex usage payload to display models"
```

---

### Task 3: OpenAI pricing

**Files:**
- Modify: `Tools/fetch_litellm.sh`
- Modify: `CCSwitcher/Services/PricingService.swift`
- Test: `CCSwitcherTests/OpenAICostTests.swift`

- [ ] **Step 1: Write the failing test**

Create `CCSwitcherTests/OpenAICostTests.swift`:

```swift
import XCTest
@testable import CCSwitcher

final class OpenAICostTests: XCTestCase {

    /// gpt-5.6-sol rates from LiteLLM, in dollars per token.
    private let sol = LiteLLMModelPricing(
        inputPerToken: 5e-06,
        outputPerToken: 3e-05,
        cacheCreatePerToken: 0,
        cacheCreate1hPerToken: nil,
        cacheReadPerToken: 5e-07,
        inputAbove200k: nil,
        outputAbove200k: nil,
        cacheCreateAbove200k: nil,
        cacheReadAbove200k: nil,
        fastMultiplier: nil
    )

    /// OpenAI reports `input_tokens` inclusive of `cached_input_tokens`, so the
    /// cached part must be subtracted before applying the fresh-input rate.
    /// Charging the full input at the fresh rate would overstate cost roughly
    /// tenfold on a cache-heavy Codex session, where 97% of input is cached.
    func testCachedInputIsSubtractedFromFreshInput() {
        let cost = sol.openAICost(inputTokens: 1000, cachedInputTokens: 900, cacheWriteTokens: 0, outputTokens: 0)
        XCTAssertEqual(cost, 100 * 5e-06 + 900 * 5e-07, accuracy: 1e-12)
    }

    func testFullyCachedInputBillsOnlyAtCacheReadRate() {
        let cost = sol.openAICost(inputTokens: 500, cachedInputTokens: 500, cacheWriteTokens: 0, outputTokens: 0)
        XCTAssertEqual(cost, 500 * 5e-07, accuracy: 1e-12)
    }

    /// A malformed payload where cached exceeds input must not produce negative cost.
    func testCachedExceedingInputClampsToZeroFreshInput() {
        let cost = sol.openAICost(inputTokens: 100, cachedInputTokens: 500, cacheWriteTokens: 0, outputTokens: 0)
        XCTAssertEqual(cost, 100 * 5e-07, accuracy: 1e-12)
    }

    /// `output_tokens` already contains `reasoning_output_tokens`; the caller must
    /// not add reasoning again, and this method must not either.
    func testOutputIsBilledOnceIncludingReasoning() {
        let cost = sol.openAICost(inputTokens: 0, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 308)
        XCTAssertEqual(cost, 308 * 3e-05, accuracy: 1e-12)
    }

    /// OpenAI does not charge for cache writes and reports the counter as zero.
    func testZeroCacheWriteCostsNothing() {
        let cost = sol.openAICost(inputTokens: 0, cachedInputTokens: 0, cacheWriteTokens: 1000, outputTokens: 0)
        XCTAssertEqual(cost, 0, accuracy: 1e-12)
    }

    func testRealSessionTotalsMatchHandCalculation() {
        // Observed totals from one rollout file.
        let cost = sol.openAICost(
            inputTokens: 54_774_121,
            cachedInputTokens: 52_989_696,
            cacheWriteTokens: 0,
            outputTokens: 213_171
        )
        let expected = Double(54_774_121 - 52_989_696) * 5e-06
            + 52_989_696 * 5e-07
            + 213_171 * 3e-05
        XCTAssertEqual(cost, expected, accuracy: 1e-9)
    }

    // MARK: - Model resolution

    func testBundledTableResolvesCodexModels() async {
        let service = PricingService.shared
        await service.ensureLoaded()
        for model in ["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.3-codex", "gpt-5.1-codex-max"] {
            let pricing = await service.pricing(for: model)
            XCTAssertNotNil(pricing, "no pricing row for \(model)")
            XCTAssertGreaterThan(pricing?.inputPerToken ?? 0, 0, "zero input rate for \(model)")
        }
    }

    func testBundledTableStillResolvesClaudeModels() async {
        let service = PricingService.shared
        await service.ensureLoaded()
        let pricing = await service.pricing(for: "claude-opus-4-8")
        XCTAssertNotNil(pricing)
        XCTAssertGreaterThan(pricing?.outputPerToken ?? 0, 0)
    }

    func testOpenAIRouterPrefixResolves() async {
        let service = PricingService.shared
        await service.ensureLoaded()
        XCTAssertNotNil(await service.pricing(for: "gpt-5.6"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/OpenAICostTests 2>&1 | tail -20
```

Expected: compile failure, `value of type 'LiteLLMModelPricing' has no member 'openAICost'`, and the model-resolution tests fail because the bundled table is Claude-only.

- [ ] **Step 3: Widen the fetch script**

In `Tools/fetch_litellm.sh`, replace the `is_claude` filter and the line that applies it:

```python
def is_claude(name: str) -> bool:
    return (name.startswith('claude-')
            or name.startswith('anthropic.claude-')
            or name.startswith('anthropic/claude-'))

claude = {k: v for k, v in data.items() if is_claude(k)}
```

with a two-provider filter:

```python
def is_claude(name: str) -> bool:
    return (name.startswith('claude-')
            or name.startswith('anthropic.claude-')
            or name.startswith('anthropic/claude-'))

def is_openai_codex(name: str) -> bool:
    # Models Codex can actually run. Chat-only and embedding rows are excluded
    # to keep the bundled snapshot small; anything Codex selects is a gpt-5.x,
    # codex-*, or o-series id.
    bare = name.split('/')[-1]
    return (bare.startswith('gpt-5')
            or bare.startswith('codex-')
            or bare.startswith('o3')
            or bare.startswith('o4'))

claude = {k: v for k, v in data.items() if is_claude(k) or is_openai_codex(k)}
```

Also update the header comment at the top of the file: the script now filters Claude **and** OpenAI rows. Then regenerate the bundled snapshot:

```bash
Tools/fetch_litellm.sh
```

Confirm both families landed:

```bash
python3 -c "
import json
d = json.load(open('CCSwitcher/Resources/litellm-pricing.json'))['models']
claude = [k for k in d if 'claude' in k]
openai = [k for k in d if k.startswith(('gpt-5','codex-','o3','o4'))]
print('claude', len(claude), 'openai', len(openai))
print('sol' , 'gpt-5.6-sol' in d)
"
```

Expected: both counts well above 10, and `sol True`.

- [ ] **Step 4: Make the loader provider-aware**

In `CCSwitcher/Services/PricingService.swift`:

Replace the `minClaudeModels` constant and its comment:

```swift
    private static let minClaudeModels = 10
```

with two floors — a wrong-shape 200 response must not be able to zero out either family:

```swift
    /// A usable LiteLLM payload yields dozens of rows per provider family.
    /// Below these floors the bytes parsed as JSON but are not the pricing
    /// table, so the payload is rejected rather than trusted.
    private static let minClaudeModels = 10
    private static let minOpenAIModels = 10
```

Rename `claudeModels(from:)` to `providerModels(from:)` and widen its filter. The existing implementation is:

```swift
    private static func claudeModels(from data: Data) -> [String: LiteLLMModelPricing]? {
        guard let raw = try? JSONDecoder().decode([String: LiteLLMEntry].self, from: data) else { return nil }
        let claude = raw.filter { name, _ in
            name.hasPrefix("claude-")
                || name.hasPrefix("anthropic/claude-")
                || name.hasPrefix("anthropic.claude-")
        }
        return claude.compactMapValues { $0.toPricing() }
    }
```

Replace it with:

```swift
    /// Decode a raw LiteLLM payload into the rows CCSwitcher prices: Claude for
    /// the Claude Code provider, gpt-5.x / codex / o-series for Codex. Returns
    /// nil when the bytes are not the expected object-of-entries schema, or when
    /// either family is too sparse to be a real pricing table.
    private static func providerModels(from data: Data) -> [String: LiteLLMModelPricing]? {
        guard let raw = try? JSONDecoder().decode([String: LiteLLMEntry].self, from: data) else { return nil }

        let claude = raw.filter { name, _ in isClaude(name) }
        let openAI = raw.filter { name, _ in isOpenAICodex(name) }
        guard claude.count >= minClaudeModels, openAI.count >= minOpenAIModels else { return nil }

        return claude.merging(openAI) { lhs, _ in lhs }.compactMapValues { $0.toPricing() }
    }

    private static func isClaude(_ name: String) -> Bool {
        name.hasPrefix("claude-")
            || name.hasPrefix("anthropic/claude-")
            || name.hasPrefix("anthropic.claude-")
    }

    private static func isOpenAICodex(_ name: String) -> Bool {
        let bare = name.split(separator: "/").last.map(String.init) ?? name
        return bare.hasPrefix("gpt-5")
            || bare.hasPrefix("codex-")
            || bare.hasPrefix("o3")
            || bare.hasPrefix("o4")
    }
```

The count guard now lives inside `providerModels`, so update the two call sites that previously applied it externally. In `conditionalRefresh()`, replace:

```swift
                guard let models = Self.claudeModels(from: data), models.count >= Self.minClaudeModels else {
                    log.warning("conditionalRefresh: 200 body not a usable pricing table (claude rows=\(Self.claudeModels(from: data)?.count ?? -1)), keeping previous cache")
                    return
                }
```

with:

```swift
                guard let models = Self.providerModels(from: data) else {
                    log.warning("conditionalRefresh: 200 body not a usable pricing table, keeping previous cache")
                    return
                }
```

and in `loadFresh()`, replace:

```swift
              let models = Self.claudeModels(from: data),
              models.count >= Self.minClaudeModels
```

with:

```swift
              let models = Self.providerModels(from: data)
```

Then add the OpenAI router prefix to `pricing(for:)`. The existing loop is:

```swift
        for prefix in ["anthropic/", "anthropic."] {
```

Change it to:

```swift
        for prefix in ["anthropic/", "anthropic.", "openai/"] {
```

- [ ] **Step 5: Add the OpenAI cost method**

In the same file, append to `LiteLLMModelPricing`, after the existing `cost(...)` method:

```swift
    /// OpenAI-shaped accounting, which differs from Anthropic's in three ways
    /// that all bite:
    ///   1. `inputTokens` is inclusive of `cachedInputTokens`, so the cached
    ///      part must be subtracted before applying the fresh-input rate.
    ///   2. `outputTokens` already includes reasoning tokens — the caller must
    ///      not add `reasoning_output_tokens` separately.
    ///   3. Cache writes are free and the counter is zero in practice; a
    ///      non-zero value bills at the creation rate when the model defines one.
    /// No 200k tier and no fast multiplier apply to OpenAI models.
    func openAICost(inputTokens: Int, cachedInputTokens: Int, cacheWriteTokens: Int, outputTokens: Int) -> Double {
        let cached = min(max(cachedInputTokens, 0), max(inputTokens, 0))
        let fresh = max(inputTokens, 0) - cached
        return Double(fresh) * inputPerToken
            + Double(cached) * cacheReadPerToken
            + Double(max(cacheWriteTokens, 0)) * cacheCreatePerToken
            + Double(max(outputTokens, 0)) * outputPerToken
    }
```

- [ ] **Step 6: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/OpenAICostTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 9 tests.

- [ ] **Step 7: Confirm Claude costs did not move**

The pricing table grew, and `pricing(for:)` does a longest-prefix fuzzy match — an OpenAI row must never win a Claude lookup. Run the existing verification script:

```bash
Tools/verify_cost.sh 2>&1 | tail -20
```

Expected: the same figures as before this task. If the script reports a mismatch, the fuzzy matcher is picking up an OpenAI row; fix by making `pricing(for:)` skip candidates whose provider family differs from the query's.

- [ ] **Step 8: Commit**

```bash
git add Tools/fetch_litellm.sh CCSwitcher/Services/PricingService.swift CCSwitcher/Resources/litellm-pricing.json CCSwitcherTests/OpenAICostTests.swift
git commit -m "Price OpenAI models from the LiteLLM snapshot"
```

---

### Task 4: Rollout parser

The correctness core of Codex cost. Everything here is a pure function over one file's bytes.

**Files:**
- Create: `CCSwitcher/Codex/Models/CodexTokenTotals.swift`
- Create: `CCSwitcher/Codex/Services/CodexRolloutParser.swift`
- Create: `CCSwitcherTests/Fixtures/codex-rollout.jsonl`
- Test: `CCSwitcherTests/CodexRolloutParserTests.swift`

- [ ] **Step 1: Create the fixture**

Create `CCSwitcherTests/Fixtures/codex-rollout.jsonl`. It deliberately exercises every case the real parser must survive: cumulative deltas, a mid-file model switch, a counter regression, a `token_count` with null `info`, an `apply_patch` with both added and removed lines, and a day boundary.

```
{"timestamp":"2026-07-30T10:00:00.000Z","type":"session_meta","payload":{"session_id":"s1","id":"r1","cwd":"/tmp","originator":"codex_cli_rs","cli_version":"0.145.0","model_provider":"openai"}}
{"timestamp":"2026-07-30T10:00:01.000Z","type":"turn_context","payload":{"turn_id":"t1","model":"gpt-5.6-sol","cwd":"/tmp","effort":"high"}}
{"timestamp":"2026-07-30T10:00:02.000Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-07-30T10:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1785000000}}}}
{"timestamp":"2026-07-30T10:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":40,"total_tokens":1100},"model_context_window":258400}}}
{"timestamp":"2026-07-30T10:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":2500,"cache_write_input_tokens":0,"output_tokens":300,"reasoning_output_tokens":90,"total_tokens":3300},"model_context_window":258400}}}
{"timestamp":"2026-07-30T10:06:00.000Z","type":"custom_tool_call","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"c1","input":"*** Begin Patch\n*** Update File: /tmp/a.swift\n@@\n-let old = 1\n+let new = 1\n+let extra = 2\n*** End Patch"}}
{"timestamp":"2026-07-30T10:07:00.000Z","type":"turn_context","payload":{"turn_id":"t2","model":"gpt-5.6-luna","cwd":"/tmp","effort":"low"}}
{"timestamp":"2026-07-30T10:07:01.000Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-07-30T10:07:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000,"cached_input_tokens":3000,"cache_write_input_tokens":0,"output_tokens":400,"reasoning_output_tokens":100,"total_tokens":4400},"model_context_window":258400}}}
{"timestamp":"2026-07-30T10:08:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15},"model_context_window":258400}}}
{"timestamp":"2026-07-31T09:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-07-31T09:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":60,"cached_input_tokens":10,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":80},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":65.0,"window_minutes":10080,"resets_at":1786033302},"secondary":null,"plan_type":"prolite","credits":{"has_credits":false,"unlimited":false,"balance":"0"}}}}
not valid json at all
{"timestamp":"2026-07-31T09:01:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"done"}}
```

- [ ] **Step 2: Write the failing test**

Create `CCSwitcherTests/CodexRolloutParserTests.swift`:

```swift
import XCTest
@testable import CCSwitcher

final class CodexRolloutParserTests: XCTestCase {

    private func parseFixture() throws -> CodexRolloutAggregate {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "codex-rollout", withExtension: "jsonl", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "codex-rollout", withExtension: "jsonl") else {
            XCTFail("codex-rollout.jsonl fixture not found in the test bundle")
            throw CocoaError(.fileNoSuchFile)
        }
        guard let aggregate = CodexRolloutParser.parse(contentsOf: url.path, relativePath: "codex-rollout.jsonl", mtime: 1) else {
            XCTFail("parser returned nil for a valid fixture")
            throw CocoaError(.fileReadCorruptFile)
        }
        return aggregate
    }

    /// First event establishes the baseline; only subsequent growth is billable.
    /// Treating the first cumulative value as a delta would double-count the
    /// opening turn of every session.
    func testFirstEventEstablishesBaseline() throws {
        let totals = try parseFixture().tokens["2026-07-30"]!["gpt-5.6-sol"]!
        // 1000 -> 3000 is the only sol delta on the 30th: +2000 input, +1700 cached, +200 output.
        XCTAssertEqual(totals.inputTokens, 2000)
        XCTAssertEqual(totals.cachedInputTokens, 1700)
        XCTAssertEqual(totals.outputTokens, 200)
    }

    /// The delta after a `turn_context` switch belongs to the new model.
    func testDeltaAfterModelSwitchIsAttributedToNewModel() throws {
        let totals = try parseFixture().tokens["2026-07-30"]!["gpt-5.6-luna"]!
        // 3000 -> 4000 lands on luna: +1000 input, +500 cached, +100 output.
        XCTAssertEqual(totals.inputTokens, 1000)
        XCTAssertEqual(totals.cachedInputTokens, 500)
        XCTAssertEqual(totals.outputTokens, 100)
    }

    /// A regression means the counter restarted; it must rebase, not go negative.
    func testCounterRegressionRebasesWithoutNegativeTokens() throws {
        let aggregate = try parseFixture()
        for (_, models) in aggregate.tokens {
            for (model, totals) in models {
                XCTAssertGreaterThanOrEqual(totals.inputTokens, 0, "negative input for \(model)")
                XCTAssertGreaterThanOrEqual(totals.outputTokens, 0, "negative output for \(model)")
                XCTAssertGreaterThanOrEqual(totals.cachedInputTokens, 0, "negative cached for \(model)")
            }
        }
    }

    /// Deltas are attributed to the local date of the event that carried them,
    /// so a session spanning midnight splits across two days.
    func testDeltasSplitAcrossDayBoundary() throws {
        let aggregate = try parseFixture()
        XCTAssertNotNil(aggregate.tokens["2026-07-30"])
        XCTAssertNotNil(aggregate.tokens["2026-07-31"])
        // After the rebase to 10, the 31st sees 10 -> 60: +50 input, +15 output.
        let day31 = aggregate.tokens["2026-07-31"]!["gpt-5.6-luna"]!
        XCTAssertEqual(day31.inputTokens, 50)
        XCTAssertEqual(day31.outputTokens, 15)
        XCTAssertEqual(day31.cachedInputTokens, 10)
    }

    func testTurnsAreCountedPerDay() throws {
        let aggregate = try parseFixture()
        XCTAssertEqual(aggregate.turns["2026-07-30"], 2)
        XCTAssertEqual(aggregate.turns["2026-07-31"], 1)
    }

    /// Only `+` lines count, and the `+++` header line of a unified diff is not
    /// an added line.
    func testAddedLinesAreCountedFromApplyPatch() throws {
        XCTAssertEqual(try parseFixture().linesAdded["2026-07-30"], 2)
    }

    func testNullInfoTokenCountIsIgnoredForCost() throws {
        // The null-info event carries rate limits but no usage; if it were
        // treated as a zero baseline the following delta would be inflated.
        let totals = try parseFixture().tokens["2026-07-30"]!["gpt-5.6-sol"]!
        XCTAssertEqual(totals.inputTokens, 2000)
    }

    func testMalformedLineDoesNotAbortTheParse() throws {
        // The fixture contains a line of plain text after the last usage event.
        // Reaching the assertions at all proves the parser skipped it.
        XCTAssertNotNil(try parseFixture().latestSnapshot)
    }

    /// The newest `rate_limits` block in the file is the offline fallback.
    func testLatestRateLimitSnapshotIsTakenFromTheLastBlock() throws {
        let snapshot = try parseFixture().latestSnapshot!
        XCTAssertEqual(snapshot.planType, "prolite")
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 65)
        XCTAssertEqual(snapshot.windows[0].windowSeconds, 10_080 * 60)
        XCTAssertEqual(snapshot.windows[0].resetAt, Date(timeIntervalSince1970: 1_786_033_302))
    }

    func testActiveMinutesExcludeLongIdleGaps() throws {
        let aggregate = try parseFixture()
        // The 30th spans 10:00:00 to 10:08:00 with no gap above ten minutes.
        XCTAssertEqual(aggregate.activeMinutes["2026-07-30"], 8)
        // The 31st has events one minute apart.
        XCTAssertEqual(aggregate.activeMinutes["2026-07-31"], 1)
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(CodexRolloutParser.parse(contentsOf: "/nonexistent/rollout.jsonl", relativePath: "x", mtime: 1))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/CodexRolloutParserTests 2>&1 | tail -20
```

Expected: compile failure, `cannot find 'CodexRolloutParser' in scope`.

- [ ] **Step 4: Create the token totals model**

Create `CCSwitcher/Codex/Models/CodexTokenTotals.swift`:

```swift
import Foundation

/// Token counters as Codex reports them. `inputTokens` is inclusive of
/// `cachedInputTokens`, and `outputTokens` is inclusive of reasoning tokens —
/// see `LiteLLMModelPricing.openAICost` for why both matter.
struct CodexTokenTotals: Codable, Sendable {
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var outputTokens: Int = 0

    static func + (lhs: CodexTokenTotals, rhs: CodexTokenTotals) -> CodexTokenTotals {
        CodexTokenTotals(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens
        )
    }
}

/// Everything one rollout file contributes. Cached on disk keyed by path and
/// mtime, so an unchanged file is never re-read.
struct CodexRolloutAggregate: Codable, Sendable {
    /// "yyyy-MM-dd" -> model id -> totals.
    var tokens: [String: [String: CodexTokenTotals]] = [:]
    var turns: [String: Int] = [:]
    var linesAdded: [String: Int] = [:]
    var activeMinutes: [String: Int] = [:]
    /// Newest `rate_limits` block seen in this file, for the offline fallback.
    var latestSnapshot: CodexRateLimitSnapshot?
    /// Timestamp of the newest event, used to pick the freshest file's snapshot.
    var latestEventAt: Double = 0
    var mtime: Double = 0
}
```

- [ ] **Step 5: Create the parser**

Create `CCSwitcher/Codex/Services/CodexRolloutParser.swift`:

```swift
import Foundation

private let log = FileLog("CodexRollout")

/// Parses one `rollout-*.jsonl` file. Pure: no actor state, no side effects, so
/// it can run concurrently across files and be unit-tested from a fixture.
enum CodexRolloutParser {

    /// Idle gap above which time stops counting as active. Matches the Claude
    /// parser's threshold so the two providers' "Active" figures are comparable.
    private static let idleGapSeconds: TimeInterval = 10 * 60

    static func parse(contentsOf path: String, relativePath: String, mtime: Double) -> CodexRolloutAggregate? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            log.debug("parse: unreadable \(relativePath)")
            return nil
        }

        var aggregate = CodexRolloutAggregate()
        aggregate.mtime = mtime

        var currentModel = "unknown"
        // Baseline for delta accounting. `total_token_usage` is cumulative per
        // session and was strictly monotonic across 23063 real events, so
        // differencing it is exact. Summing `last_token_usage` instead
        // overshoots by roughly 6% because streaming repeats events.
        var previous: CodexTokenTotals?
        var timestampsByDate: [String: [Date]] = [:]

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue   // a partially written or corrupt line must not abort the file
            }

            let payload = event["payload"] as? [String: Any]
            let timestamp = (event["timestamp"] as? String).flatMap(parseTimestamp)

            if let timestamp {
                let day = Formatters.isoDay.string(from: timestamp)
                timestampsByDate[day, default: []].append(timestamp)
                aggregate.latestEventAt = max(aggregate.latestEventAt, timestamp.timeIntervalSince1970)
            }

            switch event["type"] as? String {
            case "turn_context":
                if let model = payload?["model"] as? String, !model.isEmpty {
                    currentModel = model
                }

            case "event_msg":
                guard let payload else { break }
                switch payload["type"] as? String {
                case "task_started":
                    if let timestamp {
                        let day = Formatters.isoDay.string(from: timestamp)
                        aggregate.turns[day, default: 0] += 1
                    }

                case "token_count":
                    if let limits = payload["rate_limits"] as? [String: Any],
                       let snapshot = snapshot(fromRolloutLimits: limits) {
                        // Last one wins: the newest block in the file is current.
                        aggregate.latestSnapshot = snapshot
                    }
                    // `info` is null on many events; those carry limits only.
                    guard let info = payload["info"] as? [String: Any],
                          let raw = info["total_token_usage"] as? [String: Any],
                          let timestamp else { break }
                    let cumulative = totals(fromTotalUsage: raw)
                    defer { previous = cumulative }
                    guard let base = previous else { break }   // first event only sets the baseline
                    let day = Formatters.isoDay.string(from: timestamp)
                    let delta = difference(cumulative, minus: base)
                    guard let delta else { break }             // regression: rebase silently
                    var models = aggregate.tokens[day] ?? [:]
                    models[currentModel] = (models[currentModel] ?? CodexTokenTotals()) + delta
                    aggregate.tokens[day] = models

                default:
                    break
                }

            case "custom_tool_call":
                guard let payload,
                      payload["name"] as? String == "apply_patch",
                      let input = payload["input"] as? String,
                      let timestamp else { break }
                let day = Formatters.isoDay.string(from: timestamp)
                aggregate.linesAdded[day, default: 0] += addedLineCount(inPatch: input)

            default:
                break
            }
        }

        for (day, stamps) in timestampsByDate {
            aggregate.activeMinutes[day] = activeMinutes(stamps)
        }

        return aggregate
    }

    // MARK: - Helpers

    static func addedLineCount(inPatch patch: String) -> Int {
        patch.split(separator: "\n", omittingEmptySubsequences: false).reduce(into: 0) { count, line in
            // `+++` is a unified-diff file header, not an added line.
            if line.hasPrefix("+") && !line.hasPrefix("+++") { count += 1 }
        }
    }

    /// Sum of gaps between consecutive events, excluding gaps longer than
    /// `idleGapSeconds`. Rounded up so any activity at all reads as one minute.
    static func activeMinutes(_ timestamps: [Date]) -> Int {
        guard timestamps.count > 1 else { return timestamps.isEmpty ? 0 : 1 }
        let sorted = timestamps.sorted()
        var seconds: TimeInterval = 0
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            let gap = next.timeIntervalSince(previous)
            if gap > 0, gap <= idleGapSeconds { seconds += gap }
        }
        return max(Int((seconds / 60).rounded()), 1)
    }

    private static func totals(fromTotalUsage raw: [String: Any]) -> CodexTokenTotals {
        CodexTokenTotals(
            inputTokens: raw["input_tokens"] as? Int ?? 0,
            cachedInputTokens: raw["cached_input_tokens"] as? Int ?? 0,
            cacheWriteTokens: raw["cache_write_input_tokens"] as? Int ?? 0,
            outputTokens: raw["output_tokens"] as? Int ?? 0
        )
    }

    /// Nil when any counter went backwards, which means the session's counter
    /// restarted. The caller rebases instead of recording negative usage.
    private static func difference(_ current: CodexTokenTotals, minus base: CodexTokenTotals) -> CodexTokenTotals? {
        guard current.inputTokens >= base.inputTokens,
              current.cachedInputTokens >= base.cachedInputTokens,
              current.cacheWriteTokens >= base.cacheWriteTokens,
              current.outputTokens >= base.outputTokens else { return nil }
        return CodexTokenTotals(
            inputTokens: current.inputTokens - base.inputTokens,
            cachedInputTokens: current.cachedInputTokens - base.cachedInputTokens,
            cacheWriteTokens: current.cacheWriteTokens - base.cacheWriteTokens,
            outputTokens: current.outputTokens - base.outputTokens
        )
    }

    /// Rollout files express window length in minutes and use `primary` /
    /// `secondary` keys, unlike the endpoint's seconds and `*_window` keys.
    static func snapshot(fromRolloutLimits limits: [String: Any]) -> CodexRateLimitSnapshot? {
        func window(_ key: String) -> CodexRateLimitSnapshot.Window? {
            guard let raw = limits[key] as? [String: Any],
                  let minutes = raw["window_minutes"] as? Double else { return nil }
            return CodexRateLimitSnapshot.Window(
                usedPercent: raw["used_percent"] as? Double ?? 0,
                windowSeconds: minutes * 60,
                resetAt: (raw["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            )
        }

        let windows = [window("secondary"), window("primary")]
            .compactMap { $0 }
            .sorted { $0.windowSeconds < $1.windowSeconds }
        guard !windows.isEmpty else { return nil }

        let credits = limits["credits"] as? [String: Any]
        let hasCredits = credits?["has_credits"] as? Bool ?? false
        let unlimited = credits?["unlimited"] as? Bool ?? false

        return CodexRateLimitSnapshot(
            windows: windows,
            scoped: [],   // rollout blocks carry no per-model limits; only the endpoint does
            planType: limits["plan_type"] as? String,
            creditsBalance: (hasCredits && !unlimited) ? credits?["balance"] as? String : nil,
            hasCredits: hasCredits,
            unlimitedCredits: unlimited,
            reachedType: limits["rate_limit_reached_type"] as? String,
            spendControlReached: (limits["spend_control_reached"] as? Bool) ?? false
        )
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        Formatters.isoFractional.date(from: raw) ?? Formatters.iso.date(from: raw)
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -only-testing:CCSwitcherTests/CodexRolloutParserTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 11 tests.

Note the `defer { previous = cumulative }` placement: it must run even on the `break` paths so the baseline advances. If a test shows inflated deltas, that defer is the first thing to check.

- [ ] **Step 7: Sanity-check against real data**

The fixture proves the logic; this proves the shape matches reality. Compare the parser's view of one real file against a direct reading of its final cumulative counter:

```bash
python3 -c "
import json, glob, os
f = sorted(glob.glob(os.path.expanduser('~/.codex/sessions/**/rollout-*.jsonl'), recursive=True), key=os.path.getmtime)[-1]
last = None
for line in open(f):
    try: o = json.loads(line)
    except: continue
    p = o.get('payload') or {}
    if isinstance(p, dict) and p.get('type') == 'token_count' and p.get('info'):
        last = p['info']['total_token_usage']
print(os.path.basename(f))
print('final cumulative:', last)
"
```

Summed deltas over a single-model file must equal the final cumulative total minus its first observed value. Confirm the parser's numbers are in that range before moving on.

- [ ] **Step 8: Commit**

```bash
git add CCSwitcher/Codex CCSwitcherTests
git commit -m "Parse Codex rollout files into per-day token aggregates"
```

---

### Task 5: Incremental session cache

**Files:**
- Create: `CCSwitcher/Codex/Services/CodexSessionCache.swift`

No unit test: the actor's logic is filesystem traversal plus cache bookkeeping, and its per-file parsing is already covered by Task 4. Correctness is verified by the timing check in Step 3.

- [ ] **Step 1: Write the implementation**

Create `CCSwitcher/Codex/Services/CodexSessionCache.swift`:

```swift
import Foundation

private let log = FileLog("CodexCache")

/// Incrementally aggregates `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// A real install measured 940 files totalling 2 GB, so re-reading the tree on
/// every 5-minute refresh is not an option. Files are keyed by path and mtime;
/// unchanged files contribute their previously computed aggregate without being
/// opened. This mirrors `SessionParseCacheV2`, which solved the same problem for
/// Claude after re-parsing pegged the CPU on idle.
actor CodexSessionCache {
    static let shared = CodexSessionCache()

    private struct Envelope: Codable {
        let version: Int
        var files: [String: CodexRolloutAggregate]
    }

    private static let currentVersion = 1

    private var files: [String: CodexRolloutAggregate] = [:]
    private var loaded = false

    private static let cacheURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("CCSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("codex-session-cache.json")
    }()

    private static var sessionsRoot: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
    }

    /// Walk the tree, re-parsing only files whose mtime changed. Runs on the
    /// actor's executor, which is on the cooperative pool rather than the main
    /// thread, so awaiting this never blocks the UI.
    func refreshFromFilesystem() async {
        ensureLoaded()

        let root = Self.sessionsRoot
        guard FileManager.default.fileExists(atPath: root) else {
            log.info("refresh: no sessions directory")
            return
        }

        var seen: Set<String> = []
        var reparsed = 0
        let start = Date()

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }

            let path = url.path
            seen.insert(path)
            let mtime = modified.timeIntervalSince1970

            if let cached = files[path], cached.mtime == mtime { continue }

            if let aggregate = CodexRolloutParser.parse(contentsOf: path, relativePath: name, mtime: mtime) {
                files[path] = aggregate
                reparsed += 1
            }
        }

        // Drop entries for files the user archived or deleted, otherwise their
        // costs haunt the totals forever.
        let removed = files.keys.filter { !seen.contains($0) }
        for path in removed { files.removeValue(forKey: path) }

        log.info("refresh: \(seen.count) files, \(reparsed) reparsed, \(removed.count) dropped in \(Int(Date().timeIntervalSince(start) * 1000))ms")
        save()
    }

    /// Cost per day, priced with the current LiteLLM table. Prices are resolved
    /// in a single hop so a concurrent pricing reload cannot mix old and new
    /// rates into one answer.
    func costSeries() async -> CostSeriesModel {
        ensureLoaded()

        var byDate: [String: (cost: Double, models: [String: Double], totals: CodexTokenTotals)] = [:]
        var modelIds: Set<String> = []
        for aggregate in files.values {
            for (_, models) in aggregate.tokens { modelIds.formUnion(models.keys) }
        }

        let pricingService = PricingService.shared
        await pricingService.ensureLoaded()
        let prices = await pricingService.prices(for: Array(modelIds))

        for aggregate in files.values {
            for (date, models) in aggregate.tokens {
                for (model, totals) in models {
                    let cost = (prices[model] ?? nil)?.openAICost(
                        inputTokens: totals.inputTokens,
                        cachedInputTokens: totals.cachedInputTokens,
                        cacheWriteTokens: totals.cacheWriteTokens,
                        outputTokens: totals.outputTokens
                    ) ?? 0
                    var entry = byDate[date] ?? (0, [:], CodexTokenTotals())
                    entry.cost += cost
                    entry.models[model, default: 0] += cost
                    entry.totals = entry.totals + totals
                    byDate[date] = entry
                }
            }
        }

        let today = Formatters.isoDay.string(from: Date())
        let daily = byDate
            .map { date, entry in
                DailyCostEntry(
                    date: date,
                    cost: entry.cost,
                    modelBreakdown: entry.models,
                    inputTokens: entry.totals.inputTokens,
                    outputTokens: entry.totals.outputTokens,
                    cacheWriteTokens: entry.totals.cacheWriteTokens,
                    cacheReadTokens: entry.totals.cachedInputTokens
                )
            }
            .sorted { $0.date > $1.date }

        return CostSeriesModel(todayCost: byDate[today]?.cost ?? 0, daily: daily)
    }

    /// Today's activity. Per-file active minutes are summed, which means
    /// parallel sessions stack — the same approximation the Claude parser makes
    /// and the same one the UI tooltip already describes.
    func activityToday() -> ActivitySummaryModel {
        ensureLoaded()
        let today = Formatters.isoDay.string(from: Date())

        var turns = 0
        var minutes = 0
        var lines = 0
        var perModelTokens: [String: Int] = [:]

        for aggregate in files.values {
            turns += aggregate.turns[today] ?? 0
            minutes += aggregate.activeMinutes[today] ?? 0
            lines += aggregate.linesAdded[today] ?? 0
            for (model, totals) in aggregate.tokens[today] ?? [:] {
                // Output tokens are the closest Codex analogue to "how much did
                // this model actually produce today".
                perModelTokens[model, default: 0] += totals.outputTokens
            }
        }

        let entries = perModelTokens
            .sorted { $0.value > $1.value }
            .map { ModelUsageEntry(displayName: $0.key, count: $0.value, tint: CodexDisplayMapper.tint(forModel: $0.key)) }

        return ActivitySummaryModel(
            turns: turns,
            activeTimeText: Self.durationText(minutes: minutes),
            linesWritten: lines,
            perModel: entries
        )
    }

    /// Newest `rate_limits` block across all files, for the offline fallback.
    func latestLocalSnapshot() -> (snapshot: CodexRateLimitSnapshot, observedAt: Date)? {
        ensureLoaded()
        var best: (CodexRateLimitSnapshot, Double)?
        for aggregate in files.values {
            guard let snapshot = aggregate.latestSnapshot else { continue }
            if best == nil || aggregate.latestEventAt > best!.1 {
                best = (snapshot, aggregate.latestEventAt)
            }
        }
        return best.map { ($0.0, Date(timeIntervalSince1970: $0.1)) }
    }

    // MARK: - Disk I/O

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.currentVersion else {
            log.info("ensureLoaded: no usable cache, starting empty")
            return
        }
        files = envelope.files
        log.info("ensureLoaded: \(files.count) cached files")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Envelope(version: Self.currentVersion, files: files)) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    private static func durationText(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Verify the cache actually caches**

After Task 8 wires `CodexState` in, watch the log across two refreshes:

```bash
tail -f ~/Library/Logs/CCSwitcher/*.log | grep CodexCache
```

Expected: the first refresh reports a large `reparsed` count and hundreds of milliseconds or more; every subsequent refresh reports `reparsed` in the low single digits and completes in tens of milliseconds. If the second refresh re-parses everything, the mtime comparison is broken — check that `contentModificationDate` is being read, not `creationDate`.

- [ ] **Step 4: Commit**

```bash
git add CCSwitcher/Codex/Services/CodexSessionCache.swift
git commit -m "Cache Codex rollout aggregates keyed by file mtime"
```

---

### Task 6: Usage service

**Files:**
- Create: `CCSwitcher/Codex/Services/CodexUsageService.swift`

- [ ] **Step 1: Establish the minimal accepted header set**

The endpoint is undocumented, so determine empirically which headers it requires. Prefer an honest user agent; only fall back to the CLI's `originator` if the request is rejected without it.

```bash
python3 - <<'PY'
import json, os, urllib.request, urllib.error
a = json.load(open(os.path.expanduser('~/.codex/auth.json')))
tok, acct = a['tokens']['access_token'], a['tokens']['account_id']
variants = {
    'auth only': {'Authorization': 'Bearer ' + tok},
    'auth + account': {'Authorization': 'Bearer ' + tok, 'chatgpt-account-id': acct},
    'auth + account + honest UA': {'Authorization': 'Bearer ' + tok, 'chatgpt-account-id': acct,
                                   'User-Agent': 'CCSwitcher/1.13.0'},
}
for label, headers in variants.items():
    req = urllib.request.Request('https://chatgpt.com/backend-api/codex/usage', headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            print(f'{r.status}  {label}')
    except urllib.error.HTTPError as e:
        print(f'{e.code}  {label}')
PY
```

Use the smallest variant that returns 200 in Step 2's `makeRequest`. Record the result in a comment there so a future failure is diagnosable.

- [ ] **Step 2: Write the implementation**

Create `CCSwitcher/Codex/Services/CodexUsageService.swift`:

```swift
import Foundation

private let log = FileLog("CodexUsage")

/// Fetches Codex rate limits.
///
/// Primary source is the live endpoint. When it is unreachable, the fallback is
/// the newest `rate_limits` block Codex itself wrote into a rollout file — data
/// derived from files Codex maintains for its own use, and therefore far more
/// stable than the undocumented endpoint.
///
/// This service never issues an OAuth refresh grant. The Codex access token
/// lives 10 days and the Codex CLI owns refreshing it; a second refresher would
/// risk the token-family revocation the project already avoids on the Claude
/// side, for no benefit.
actor CodexUsageService {
    static let shared = CodexUsageService()

    enum UsageError: LocalizedError {
        case needsReauth
        case rateLimited(retryAfter: TimeInterval)
        case transport(String)
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .needsReauth:
                return String(localized: "Codex session expired. Run `codex login` to sign in again.", bundle: L10n.bundle)
            case .rateLimited:
                return String(localized: "Codex API rate-limited. Retrying automatically.", bundle: L10n.bundle)
            case .transport(let detail):
                return String(localized: "Could not reach Codex: \(detail)", bundle: L10n.bundle)
            case .badStatus(let code):
                return String(localized: "Codex usage request failed (HTTP \(code)).", bundle: L10n.bundle)
            }
        }
    }

    struct Result: Sendable {
        let snapshot: CodexRateLimitSnapshot
        let email: String?
        /// True when the numbers came from a local rollout file rather than live.
        let isStale: Bool
        let observedAt: Date
    }

    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/usage")!

    private static var lastKnownURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("CCSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("codex-usage-last-known.json")
    }

    /// Live fetch with the given credentials. Throws rather than falling back,
    /// so the caller decides whether a stale local snapshot is acceptable.
    func fetchLive(accessToken: String, accountId: String?) async throws -> Result {
        guard !CodexAuthService.isAccessTokenExpired(accessToken) else {
            log.warning("fetchLive: access token expired locally, not sending request")
            throw UsageError.needsReauth
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: makeRequest(accessToken: accessToken, accountId: accountId))
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            let decoded: CodexUsageResponse
            do {
                decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            } catch {
                throw UsageError.transport("unexpected payload: \(error.localizedDescription)")
            }
            let result = Result(
                snapshot: CodexRateLimitSnapshot(response: decoded),
                email: decoded.email,
                isStale: false,
                observedAt: Date()
            )
            persistLastKnown(result)
            log.info("fetchLive: ok, plan=\(decoded.planType ?? "?") windows=\(result.snapshot.windows.count)")
            return result

        case 401, 403:
            log.warning("fetchLive: \(http.statusCode) — credentials rejected")
            throw UsageError.needsReauth

        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
            log.warning("fetchLive: 429, backing off \(Int(retryAfter))s")
            throw UsageError.rateLimited(retryAfter: retryAfter)

        default:
            log.warning("fetchLive: unexpected status \(http.statusCode)")
            throw UsageError.badStatus(http.statusCode)
        }
    }

    /// Local fallback: the newest snapshot Codex wrote, or the last live answer
    /// we persisted, whichever is newer. Used when the endpoint fails and to
    /// populate the popover before the first fetch completes.
    func localFallback() async -> Result? {
        let fromRollouts = await CodexSessionCache.shared.latestLocalSnapshot()
            .map { Result(snapshot: $0.snapshot, email: nil, isStale: true, observedAt: $0.observedAt) }
        let fromCache = loadLastKnown()

        switch (fromRollouts, fromCache) {
        case (let rollout?, let cached?):
            return rollout.observedAt >= cached.observedAt ? rollout : cached
        case (let rollout?, nil):
            return rollout
        case (nil, let cached?):
            return cached
        case (nil, nil):
            return nil
        }
    }

    // MARK: - Private

    private func makeRequest(accessToken: String, accountId: String?) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        // Header set confirmed against the live endpoint in Task 6 Step 1.
        // Keep this list minimal: every extra header is one more thing that can
        // start being validated and break the request.
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId {
            request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        request.setValue("CCSwitcher/\(version)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        return request
    }

    private struct LastKnown: Codable {
        let snapshot: CodexRateLimitSnapshot
        let email: String?
        let observedAt: Date
    }

    private func persistLastKnown(_ result: Result) {
        let payload = LastKnown(snapshot: result.snapshot, email: result.email, observedAt: result.observedAt)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Self.lastKnownURL, options: .atomic)
    }

    private func loadLastKnown() -> Result? {
        guard let data = try? Data(contentsOf: Self.lastKnownURL),
              let payload = try? JSONDecoder().decode(LastKnown.self, from: data) else { return nil }
        return Result(snapshot: payload.snapshot, email: payload.email, isStale: true, observedAt: payload.observedAt)
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
git add CCSwitcher/Codex/Services/CodexUsageService.swift
git commit -m "Fetch Codex limits with local snapshot fallback"
```

---

### Task 7: Codex theme

**Files:**
- Modify: `CCSwitcher/Providers/ProviderTheme.swift`

- [ ] **Step 1: Add a hex initializer and the Codex theme**

In `CCSwitcher/Providers/ProviderTheme.swift`, add above the `extension ProviderTheme`:

```swift
private extension Color {
    /// 24-bit hex, for themes transcribed from a design reference.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
```

Then add the theme inside `extension ProviderTheme`, after `.claude`:

```swift
    /// Modeled on ChatGPT Desktop: flat near-black, monochrome accents, hairline
    /// borders. No brand orange participates.
    ///
    /// Utilization colours stay semantic (see `utilizationColor`) — a monochrome
    /// bar makes the percentage unreadable at a glance, which defeats its purpose.
    static let codex = ProviderTheme(
        panel: .flat(Color(hex: 0x0D0D0D)),
        accent: Color(hex: 0xFFFFFF),
        accentForeground: Color(hex: 0x0D0D0D),
        cardFill: Color(hex: 0x171717),
        cardFillStrong: Color(hex: 0x1F1F1F),
        cardBorder: Color(hex: 0x2E2E2E),
        textPrimary: Color(hex: 0xECECEC),
        textSecondary: Color(hex: 0x9A9A9A),
        tabFill: Color(hex: 0x161616),
        tabBorder: Color(hex: 0x2E2E2E),
        tabSelectedFill: Color(hex: 0x303030),
        tabSelectedForeground: Color(hex: 0xFFFFFF),
        progressTrack: Color(hex: 0x2A2A2A),
        subtleAccent: Color(hex: 0x1A1A1A),
        forcedColorScheme: .dark
    )
```

And change the `theme(for:)` switch so Codex gets it:

```swift
    static func theme(for provider: AIProviderType) -> ProviderTheme {
        switch provider {
        case .claudeCode: return .claude
        case .codex: return .codex
        case .gemini: return .claude
        }
    }
```

- [ ] **Step 2: Verify it builds**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. Nothing changes visually yet — Codex is not registered until Task 9.

- [ ] **Step 3: Commit**

```bash
git add CCSwitcher/Providers/ProviderTheme.swift
git commit -m "Add near-black Codex theme"
```

---

### Task 8: CodexState

**Files:**
- Create: `CCSwitcher/Codex/CodexState.swift`

- [ ] **Step 1: Write the implementation**

Create `CCSwitcher/Codex/CodexState.swift`:

```swift
import SwiftUI

private let log = FileLog("CodexState")

/// Codex provider state. Read-only in stage 2: it observes `~/.codex` and the
/// usage endpoint but writes nothing. Account switching arrives in stage 3,
/// gated by `capabilities`.
@MainActor
final class CodexState: ObservableObject, ProviderSurface {

    @Published private(set) var isLoading = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefresh: Date?

    @Published private var snapshot: CodexRateLimitSnapshot?
    @Published private var snapshotIsStale = false
    @Published private var email: String?
    @Published private var name: String?
    @Published private var planType: String?
    @Published private var usageError: ProviderErrorModel?
    @Published private var costSeries: CostSeriesModel = .empty
    @Published private var activitySummary: ActivitySummaryModel = .empty

    /// Identity for the single Codex account stage 2 knows about. Derived from
    /// the account id so it is stable across launches without persistence,
    /// which stage 3 replaces with real per-account records.
    private var accountId: UUID = UUID()

    /// Per-account 429 back-off, matching the Claude behaviour: a rate limit
    /// blocks refreshes but must not discard numbers already fetched.
    private var rateLimitedUntil: Date?

    private let usageService = CodexUsageService.shared
    private let sessionCache = CodexSessionCache.shared

    var providerType: AIProviderType { .codex }

    var isAvailable: Bool { CodexAuthService.isInstalled }

    var capabilities: ProviderCapabilities {
        // Stage 2 is read-only. Stage 3 flips the first four flags on.
        ProviderCapabilities(
            canSwitchAccounts: false,
            canImportCurrent: false,
            canLoginNewAccount: false,
            canReauthenticate: false,
            tracksLinesWritten: true
        )
    }

    var header: AccountHeaderModel? {
        guard let email else { return nil }
        let obfuscate = !UserDefaults.standard.bool(forKey: "showFullEmail")
        return AccountHeaderModel(
            title: name ?? (obfuscate ? email.obfuscatedEmail() : email),
            subtitle: obfuscate ? email.obfuscatedEmail() : email,
            planBadge: CodexDisplayMapper.planBadge(from: planType)
        )
    }

    var accountCards: [UsageCardModel] {
        guard let email else { return [] }
        let obfuscate = !UserDefaults.standard.bool(forKey: "showFullEmail")
        let displayEmail = obfuscate ? email.obfuscatedEmail() : email
        let snapshot = snapshot ?? .empty
        return [UsageCardModel(
            id: accountId,
            title: name ?? displayEmail,
            subtitle: displayEmail,
            planBadge: CodexDisplayMapper.planBadge(from: planType),
            isActive: true,
            windows: CodexDisplayMapper.windows(from: snapshot),
            scopedLimits: CodexDisplayMapper.scopedLimits(from: snapshot),
            credits: self.snapshot == nil ? nil : CodexDisplayMapper.credits(from: snapshot),
            notice: CodexDisplayMapper.notice(from: snapshot, isStale: snapshotIsStale),
            error: usageError
        )]
    }

    var accountRows: [AccountRowModel] {
        guard let email else { return [] }
        let obfuscate = !UserDefaults.standard.bool(forKey: "showFullEmail")
        let displayEmail = obfuscate ? email.obfuscatedEmail() : email
        return [AccountRowModel(
            id: accountId,
            title: name ?? displayEmail,
            email: displayEmail,
            planBadge: CodexDisplayMapper.planBadge(from: planType),
            isActive: true,
            lastUsedText: nil,
            hasStoredCredentials: true,
            rawLabel: nil
        )]
    }

    var activity: ActivitySummaryModel { activitySummary }

    var cost: CostSeriesModel { costSeries }

    // MARK: - Refresh

    func refresh(force: Bool) async {
        guard isAvailable else {
            errorMessage = String(localized: "Codex is not signed in on this Mac.", bundle: L10n.bundle)
            return
        }

        isLoading = true
        errorMessage = nil

        // Identity first: it comes from a local file and must render even if the
        // network is unavailable.
        let auth: CodexAuth?
        do {
            let loaded = try CodexAuthService.loadCurrent()
            auth = loaded
            let claims = CodexAuthService.claims(fromIDToken: loaded.tokens.idToken)
            email = claims?.email
            name = claims?.name
            // Provisional: the live endpoint's plan is authoritative and
            // overwrites this below. The id_token was observed reporting a
            // stale `prolite` where the endpoint said `pro`.
            if planType == nil { planType = claims?.planType }
        } catch {
            auth = nil
            errorMessage = error.localizedDescription
            log.error("[refresh] credentials unreadable: \(error.localizedDescription)")
        }

        await refreshLimits(auth: auth, force: force)
        await refreshCostAndActivity()

        lastRefresh = Date()
        isLoading = false
    }

    private func refreshLimits(auth: CodexAuth?, force: Bool) async {
        if !force, let until = rateLimitedUntil, until > Date() {
            log.info("[refresh] skipping limits — rate limited for \(Int(until.timeIntervalSinceNow))s more")
            return
        }

        guard let auth else {
            await applyFallback()
            return
        }

        do {
            let result = try await usageService.fetchLive(
                accessToken: auth.tokens.accessToken,
                accountId: auth.tokens.accountId
            )
            snapshot = result.snapshot
            snapshotIsStale = false
            planType = result.snapshot.planType ?? planType
            if let live = result.email { email = live }
            usageError = nil
            rateLimitedUntil = nil
        } catch CodexUsageService.UsageError.rateLimited(let retryAfter) {
            rateLimitedUntil = Date().addingTimeInterval(retryAfter)
            // Keep existing numbers; a 429 blocks refresh, it does not
            // invalidate what we already have.
            usageError = ProviderErrorModel(
                message: CodexUsageService.UsageError.rateLimited(retryAfter: retryAfter).localizedDescription,
                needsReauth: false,
                isRateLimited: true
            )
            if snapshot == nil { await applyFallback() }
        } catch CodexUsageService.UsageError.needsReauth {
            usageError = ProviderErrorModel(
                message: CodexUsageService.UsageError.needsReauth.localizedDescription,
                needsReauth: true,
                isRateLimited: false
            )
            await applyFallback()
        } catch {
            log.warning("[refresh] live limits failed: \(error.localizedDescription)")
            await applyFallback()
            if snapshot == nil {
                usageError = ProviderErrorModel(message: error.localizedDescription, needsReauth: false, isRateLimited: false)
            }
        }
    }

    private func applyFallback() async {
        guard let fallback = await usageService.localFallback() else { return }
        snapshot = fallback.snapshot
        snapshotIsStale = true
        planType = fallback.snapshot.planType ?? planType
        if email == nil { email = fallback.email }
        log.info("[refresh] using local snapshot from \(fallback.observedAt)")
    }

    private func refreshCostAndActivity() async {
        await PricingService.shared.reloadIfFreshChanged()
        PricingService.shared.refreshInBackground()
        await sessionCache.refreshFromFilesystem()
        costSeries = await sessionCache.costSeries()
        activitySummary = await sessionCache.activityToday()
        log.info("[refresh] today=$\(String(format: "%.2f", costSeries.todayCost)) turns=\(activitySummary.turns)")
    }

    // MARK: - Actions (stage 3)

    func switchTo(accountId: UUID) async {
        log.warning("[switchTo] not supported until stage 3")
    }

    func importCurrentAccount() async {
        log.warning("[importCurrentAccount] not supported until stage 3")
    }

    func loginNewAccount() async {
        log.warning("[loginNewAccount] not supported until stage 3")
    }

    func removeAccount(id: UUID) {
        log.warning("[removeAccount] not supported until stage 3")
    }

    func reauthenticate(id: UUID) async {
        log.warning("[reauthenticate] not supported until stage 3")
    }

    func setLabel(_ label: String?, forAccount id: UUID) {
        log.warning("[setLabel] not supported until stage 3")
    }
}
```

`PricingService.reloadIfFreshChanged()` and `refreshInBackground()` are called here so Codex benefits from the same hot-reload of a newly downloaded price table that the Claude path gets — without it, a model released mid-session would be priced at zero until the app restarted.

- [ ] **Step 2: Verify it builds**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

If the compiler complains that `CodexState` does not conform because `isLoading` and friends are `private(set)`, that is fine for a get-only protocol requirement. If it complains about `objectWillChange`, confirm the associated-type constraint added in Stage 1 Task 8 is present.

- [ ] **Step 3: Commit**

```bash
git add CCSwitcher/Codex/CodexState.swift
git commit -m "Add read-only Codex provider state"
```

---

### Task 9: Provider switcher and registration

**Files:**
- Create: `CCSwitcher/Views/ProviderSwitcherView.swift`
- Modify: `CCSwitcher/CCSwitcherApp.swift`
- Modify: `CCSwitcher/Views/MainMenuView.swift`

- [ ] **Step 1: Create the switcher**

Create `CCSwitcher/Views/ProviderSwitcherView.swift`:

```swift
import SwiftUI

/// Compact icon segmented control in the popover header. Renders only when more
/// than one provider is installed, so a Claude-only Mac sees no change.
struct ProviderSwitcherView: View {
    @EnvironmentObject private var hub: ProviderHub
    @Environment(\.providerTheme) private var theme

    var body: some View {
        if hub.showsSwitcher {
            HStack(spacing: 2) {
                ForEach(hub.available) { provider in
                    let isSelected = provider == hub.activeProvider
                    Image(systemName: provider.iconName)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 22)
                        .foregroundStyle(isSelected ? theme.tabSelectedForeground : theme.textSecondary)
                        .background(
                            Capsule().fill(isSelected ? theme.tabSelectedFill : Color.clear)
                        )
                        .contentShape(Capsule())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                hub.select(provider)
                            }
                        }
                        .help(provider.rawValue)
                }
            }
            .padding(2)
            .background(
                Capsule()
                    .fill(theme.tabFill)
                    .overlay(Capsule().stroke(theme.tabBorder, lineWidth: 1))
            )
        }
    }
}
```

`AIProviderType` is already `Identifiable` with `id: String { rawValue }`, so the `ForEach` needs no explicit id.

- [ ] **Step 2: Place it in the header**

In `CCSwitcher/Views/MainMenuView.swift`, inside `headerView`, insert the switcher between the `Spacer()` and the loading indicator:

```swift
            Spacer()

            ProviderSwitcherView()

            if hub.surface.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
```

- [ ] **Step 3: Register CodexState with the hub**

In `CCSwitcher/CCSwitcherApp.swift`, add the state object and replace the Stage 1 `init()` filter. The Stage 1 version was:

```swift
    init() {
        let state = AppState()
        let available = ProviderRegistry.detect(
            claudeInstalled: true,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        _appState = StateObject(wrappedValue: state)
        _providerHub = StateObject(wrappedValue: ProviderHub(
            surfaces: [.claudeCode: state],
            available: available.filter { $0 == .claudeCode }
        ))
    }
```

Replace it with:

```swift
    init() {
        let claude = AppState()
        let codex = CodexState()
        let available = ProviderRegistry.detect(
            claudeInstalled: true,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        _appState = StateObject(wrappedValue: claude)
        _codexState = StateObject(wrappedValue: codex)
        _providerHub = StateObject(wrappedValue: ProviderHub(
            surfaces: [.claudeCode: claude, .codex: codex],
            available: available
        ))
    }
```

and add the declaration beside the others:

```swift
    @StateObject private var codexState: CodexState
```

- [ ] **Step 4: Verify end to end**

```bash
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build 2>&1 | tail -5
open ~/Library/Developer/Xcode/DerivedData/CCSwitcher-*/Build/Products/Debug/CCSwitcher.app
```

Check, in order:

1. The switcher appears in the header's top-right with two icons.
2. Claude mode is unchanged from Stage 1 — same numbers, same orange accent, same material background.
3. Selecting Codex turns the panel near-black, cards `#171717`, hairline borders, no orange anywhere, and the selected tab a grey capsule with white text.
4. The Codex Usage tab shows the plan badge (`Pro`), a weekly bar matching what `codex` reports, the `GPT-5.3-Codex-Spark` scoped row, and an extra-usage row.
5. The Codex Costs tab shows a today figure and a daily history.
6. The Codex Accounts tab lists one row with no add or switch buttons, because `capabilities` denies them.
7. The choice survives a relaunch.

Cross-check the limits against the CLI's own view:

```bash
python3 -c "
import json, os, urllib.request
a = json.load(open(os.path.expanduser('~/.codex/auth.json')))
r = urllib.request.Request('https://chatgpt.com/backend-api/codex/usage', headers={
    'Authorization': 'Bearer ' + a['tokens']['access_token'],
    'chatgpt-account-id': a['tokens']['account_id']})
d = json.loads(urllib.request.urlopen(r, timeout=20).read())
print('plan', d['plan_type'])
print('primary', d['rate_limit']['primary_window'])
print('additional', [(x['limit_name'], x['rate_limit']['primary_window']['used_percent']) for x in d.get('additional_rate_limits') or []])
"
```

The percentages in the popover must match this output.

- [ ] **Step 5: Verify the offline fallback**

Turn off networking (or block `chatgpt.com` in `/etc/hosts`), relaunch, and confirm the Codex card still shows limits with the "last snapshot Codex wrote locally" notice rather than an empty card. Restore networking afterwards.

- [ ] **Step 6: Commit**

```bash
git add CCSwitcher/Views/ProviderSwitcherView.swift CCSwitcher/Views/MainMenuView.swift CCSwitcher/CCSwitcherApp.swift
git commit -m "Add provider switcher and register Codex state"
```

---

### Task 10: Stage verification

**Files:** none — verification gate.

- [ ] **Step 1: Run the whole suite**

```bash
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **` across all eight test classes.

- [ ] **Step 2: Confirm nothing writes to ~/.codex**

```bash
grep -rn "authPath\|\.codex" CCSwitcher/Codex/ | grep -iE "write|create|remove|moveItem|copyItem" || echo "read-only confirmed"
```

Expected: `read-only confirmed`.

- [ ] **Step 3: Confirm Claude costs are unchanged**

```bash
Tools/verify_cost.sh 2>&1 | tail -20
```

Expected: the same figures as before Stage 2, proving the widened pricing table did not shift Claude lookups.

- [ ] **Step 4: Confirm steady-state refresh is cheap**

With the app running, watch two consecutive refreshes:

```bash
tail -20 ~/Library/Logs/CCSwitcher/*.log | grep CodexCache
```

Expected: the second refresh reports single-digit `reparsed` and tens of milliseconds. A first run over 940 files will be slow — that is expected and happens off the main thread.

- [ ] **Step 5: Commit any fixes**

```bash
git add -A
git commit -m "Verify read-only Codex provider against live account"
```

---

## Self-Review

**Spec coverage.** Stage 2's spec items all map to tasks: `CodexAuthService` (1), `CodexUsageResponse` / `CodexRateLimitSnapshot` (2), pricing widening (3), `CodexRolloutParser` and the delta/lines/turns rules (4), `CodexSessionCache` (5), `CodexUsageService` with live plus fallback plus last-known cache (6), the Codex theme (7), `CodexState` (8), the header switcher (9). The spec's `CodexTokenUsage.swift` is named `CodexTokenTotals.swift` here because the type holds accumulated totals, not a single usage event. `CodexAccountStore` is Stage 3, as the spec states.

**Placeholder scan.** One step is deliberately empirical rather than prescriptive: Task 6 Step 1 probes the endpoint to find the minimal header set. That is a measurement with an exact command, an exact decision rule, and a stated place to record the answer — not a deferred decision. Every code-producing step contains its code.

**Type consistency.** Verified across tasks: `CodexAuthService.claims(fromIDToken:)` and `isAccessTokenExpired(_:)` are used with those names in Tasks 1, 6 and 8. `CodexRateLimitSnapshot.Window.windowSeconds` (seconds, always — the minutes conversion happens at the parser boundary in Task 4) is consistent in Tasks 2, 4, 5 and 8. `CodexDisplayMapper.windows/scopedLimits/credits/notice/planBadge/tint(forModel:)` match between Tasks 2, 5 and 8. `CodexRolloutAggregate.tokens/turns/linesAdded/activeMinutes/latestSnapshot/latestEventAt/mtime` match between Tasks 4 and 5. `LiteLLMModelPricing.openAICost(inputTokens:cachedInputTokens:cacheWriteTokens:outputTokens:)` has one signature, used in Tasks 3 and 5. `PricingService.providerModels(from:)` replaces `claudeModels(from:)` at both of its call sites. `ProviderCapabilities` is constructed with all five fields in Task 8, matching Stage 1's definition.

**Known approximation, stated deliberately.** Per-model activity counts output tokens rather than message counts, because Codex rollouts have no per-model message counter. The Claude column counts messages. The two providers' per-model rows are therefore not directly comparable — but each is internally consistent and correctly ranks the models by how much work they did.

---

## Remaining Stages

Stage 3 (Codex account switching: `CodexAccountStore`, `auth.json` swapping, `codex login` integration, the desync guard, the Codex CLI settings tab) and Stage 4 (per-provider menu bar modules, generalized window labels, `scopedLimitBar`, provider-aware `WidgetData`) are specified in the design document but not yet planned in this detail.

They are intentionally left until Stage 2 is merged. Both stages write to `~/.codex` and drive a browser OAuth flow through a background process, and the exact shapes they must target — how `codex login` behaves non-interactively, and what `CodexState` looks like once its data paths are real rather than designed — are things Stage 2 establishes. Writing their steps now would mean writing code against assumed signatures and assumed CLI behaviour, which is the failure mode this plan format exists to prevent.
