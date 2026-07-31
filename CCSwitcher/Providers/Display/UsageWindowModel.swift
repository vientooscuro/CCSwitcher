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
        case .session: "session"
        case .weekly: "weekly"
        case .other(let seconds): "other-\(Int(seconds))"
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
