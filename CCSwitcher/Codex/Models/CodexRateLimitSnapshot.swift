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
