import Foundation

/// Shared, lazily-initialized formatters. `DateFormatter` and `ISO8601DateFormatter`
/// allocations are expensive (locale + calendar setup). Reuse a small set of
/// thread-safe instances instead of creating new ones inside `var body` or
/// per-iteration loops.
///
/// Apple confirms `DateFormatter` is thread-safe for reads since iOS 7 / macOS 10.9
/// when the formatter is not mutated concurrently. We never mutate these after init.
enum Formatters {
    /// "yyyy-MM-dd" — used everywhere date strings are stored / compared.
    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// "MMM d" — short display ("Nov 9").
    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// "EEE h:mm a" — weekday + time ("Mon 3:45 PM").
    static let weekdayTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return f
    }()

    /// Short time only.
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// ISO8601 with fractional seconds — for parsing API/JSONL timestamps.
    nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// ISO8601 without fractional seconds — fallback parser.
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `$1.23` for >= $1, `$0.0123` otherwise. Used in cost cards.
    static func currency(_ value: Double) -> String {
        value >= 1 ? String(format: "$%.2f", value) : String(format: "$%.4f", value)
    }
}
