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
