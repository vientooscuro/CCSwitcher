import Foundation

// MARK: - Usage API Response (from /api/oauth/usage)

struct UsageAPIResponse: Codable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOauthApps: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let sevenDayCowork: UsageWindow?
    let iguanaNecktie: UsageWindow?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case iguanaNecktie = "iguana_necktie"
        case extraUsage = "extra_usage"
    }
}

struct UsageWindow: Codable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        return Formatters.isoFractional.date(from: resetsAt)
            ?? Formatters.iso.date(from: resetsAt)
    }

    var resetTimeString: String? {
        guard let date = resetsAtDate else { return nil }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "now" }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if hours > 24 {
            return Formatters.weekdayTime.string(from: date)
        } else if hours > 0 {
            return "\(hours) hr \(minutes) min"
        } else {
            return "\(minutes) min"
        }
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

// MARK: - Session Info (from ~/.claude/sessions/*.json)

struct SessionInfo: Codable, Identifiable {
    let pid: Int
    let sessionId: String
    let cwd: String?
    let startedAt: Double?

    var id: String { sessionId }

    var startDate: Date? {
        guard let startedAt else { return nil }
        return Date(timeIntervalSince1970: startedAt / 1000)
    }
}
