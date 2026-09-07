# Codex Usage Resilience and Account Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement task-by-task.

**Goal:** Preserve each Codex account's usage when an optional live-payload field changes, and make account cards compact and stable.

**Architecture:** Decode each undocumented response branch independently. Render a flexible identity column beside a fixed-width action column.

**Tech Stack:** Swift 5.7, SwiftUI, XCTest, XcodeGen.

## Global Constraints

- Project configuration comes only from project.yml, never CCSwitcher.xcodeproj.
- Refresh does not write credentials or open Codex.
- Test decoder drift red-green before production code.
- Use short English commit titles.

---

### Task 1: Tolerate Codex usage payload drift

**Files:**
- Modify: CCSwitcherTests/CodexUsageMappingTests.swift
- Modify: CCSwitcher/Codex/Models/CodexUsageResponse.swift

**Interfaces:**
- Consumes: JSONDecoder().decode(CodexUsageResponse.self, from:).
- Produces: valid rate limits even if an unrelated optional field changes shape.

- [ ] **Step 1: Write the failing test**

~~~swift
func testOptionalPayloadDriftPreservesRateLimits() throws {
    let json = #"{"plan_type":"team","rate_limit":{"primary_window":{"used_percent":"100","limit_window_seconds":"604800","reset_at":1786033302}},"additional_rate_limits":["unsupported",{"limit_name":"GPT-5","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000}}}],"credits":{"has_credits":false,"balance":0}}"#
    let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    XCTAssertEqual(usage.planType, "team")
    XCTAssertEqual(usage.rateLimit?.primaryWindow?.usedPercent, 100)
    XCTAssertEqual(usage.rateLimit?.primaryWindow?.limitWindowSeconds, 604_800)
    XCTAssertEqual(usage.additionalRateLimits?.count, 1)
    XCTAssertEqual(usage.credits?.balance, "0")
}
~~~

- [ ] **Step 2: Run the focused test to verify RED**

Run: xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -only-testing:CCSwitcherTests/CodexUsageMappingTests/testOptionalPayloadDriftPreservesRateLimits

Expected: failure from synthesized Codable rejecting the type-drifted optional values.

- [ ] **Step 3: Add the minimal decoder**

~~~swift
private extension KeyedDecodingContainer {
    func lossy<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
    func flexibleDouble(forKey key: Key) -> Double? {
        lossy(Double.self, forKey: key) ?? lossy(String.self, forKey: key).flatMap(Double.init)
    }
    func flexibleString(forKey key: Key) -> String? {
        lossy(String.self, forKey: key) ?? lossy(Double.self, forKey: key).map(String.init)
    }
}
~~~

Give Window, RateLimit, AdditionalLimit, Credits, SpendControl, and CodexUsageResponse explicit decoding initializers. Decode additional limits through an unkeyed lossy array, retaining valid entries.

- [ ] **Step 4: Run the focused test to verify GREEN**

Run: xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -only-testing:CCSwitcherTests/CodexUsageMappingTests/testOptionalPayloadDriftPreservesRateLimits

Expected: TEST SUCCEEDED.

- [ ] **Step 5: Run the mapping suite**

Run: xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -only-testing:CCSwitcherTests/CodexUsageMappingTests

Expected: all usage mapping tests pass.

- [ ] **Step 6: Commit**

~~~bash
git add CCSwitcher/Codex/Models/CodexUsageResponse.swift CCSwitcherTests/CodexUsageMappingTests.swift
git commit -m "Tolerate Codex usage payload drift"
~~~

### Task 2: Stabilize account-card columns

**Files:**
- Modify: CCSwitcher/Views/AccountSwitcherView.swift

**Interfaces:**
- Consumes: AccountRowModel, ProviderSurface, and provider theme.
- Produces: a truncating identity area with non-wrapping trailing actions.

- [ ] **Step 1: Separate identity and actions**

~~~swift
HStack(alignment: .center, spacing: 12) {
    ProviderIcon(provider: hub.activeProvider, size: 22)
        .frame(width: 32, height: 32)
    accountIdentity(row)
        .frame(maxWidth: .infinity, alignment: .leading)
    accountActions(row)
        .fixedSize(horizontal: true, vertical: false)
}
~~~

Move name, active badge, email, plan and provider into accountIdentity(_:). Title and email use one line with tail truncation; plan and provider share one compact metadata line. Move the existing open/switch, re-authenticate and delete buttons into accountActions(_:), preserving help text, disabled state, and tasks.

- [ ] **Step 2: Keep editing contained and improve hierarchy**

~~~swift
.padding(14)
.background(
    RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(row.isActive ? theme.cardFillStrong : theme.cardFill)
        .strokeBorder(row.isActive ? theme.accent.opacity(0.35) : theme.cardBorder, lineWidth: 1)
)
~~~

The rename field and confirm/cancel controls remain in the flexible identity column.

- [ ] **Step 3: Generate and compile**

Run: xcodegen generate && xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

~~~bash
git add CCSwitcher/Views/AccountSwitcherView.swift
git commit -m "Improve account card layout"
~~~

### Task 3: Integrate branches into main

**Files:**
- No source changes expected.

**Interfaces:**
- Consumes: fix/codex-desktop-profiles, which already contains feature/codex-provider.
- Produces: main with both branch histories and these fixes.

- [ ] **Step 1: Run the complete suite**

Run: xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher

Expected: TEST SUCCEEDED.

- [ ] **Step 2: Fast-forward main**

~~~bash
git switch main
git merge --ff-only fix/codex-desktop-profiles
~~~

Expected: no separate feature merge is needed because it is already an ancestor.

- [ ] **Step 3: Verify and push**

~~~bash
git status --short --branch
git log --oneline origin/main..main
git push origin main
~~~

Expected: clean main and successful push.
