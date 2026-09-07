import Foundation

private extension KeyedDecodingContainer {
    func lossy<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    func flexibleDouble(forKey key: Key) -> Double? {
        lossy(Double.self, forKey: key) ?? lossy(String.self, forKey: key).flatMap(Double.init)
    }

    func flexibleString(forKey key: Key) -> String? {
        if let value = lossy(String.self, forKey: key) { return value }
        if let value = lossy(Int.self, forKey: key) { return String(value) }
        return lossy(Double.self, forKey: key).map { String($0) }
    }
}

private struct LossyElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) {
        value = try? Value(from: decoder)
    }
}

private struct LossyArray<Value: Decodable>: Decodable {
    let values: [Value]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = try container.decode([LossyElement<Value>].self).compactMap(\.value)
    }
}

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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = container.flexibleDouble(forKey: .usedPercent)
            limitWindowSeconds = container.flexibleDouble(forKey: .limitWindowSeconds)
            resetAfterSeconds = container.flexibleDouble(forKey: .resetAfterSeconds)
            resetAt = container.flexibleDouble(forKey: .resetAt)
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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            allowed = container.lossy(Bool.self, forKey: .allowed)
            limitReached = container.lossy(Bool.self, forKey: .limitReached)
            primaryWindow = container.lossy(Window.self, forKey: .primaryWindow)
            secondaryWindow = container.lossy(Window.self, forKey: .secondaryWindow)
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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limitName = container.flexibleString(forKey: .limitName)
            meteredFeature = container.flexibleString(forKey: .meteredFeature)
            rateLimit = container.lossy(RateLimit.self, forKey: .rateLimit)
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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = container.lossy(Bool.self, forKey: .hasCredits)
            unlimited = container.lossy(Bool.self, forKey: .unlimited)
            overageLimitReached = container.lossy(Bool.self, forKey: .overageLimitReached)
            balance = container.flexibleString(forKey: .balance)
        }
    }

    struct SpendControl: Codable, Sendable {
        let reached: Bool?
        let individualLimit: Double?

        enum CodingKeys: String, CodingKey {
            case reached
            case individualLimit = "individual_limit"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            reached = container.lossy(Bool.self, forKey: .reached)
            individualLimit = container.flexibleDouble(forKey: .individualLimit)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = container.flexibleString(forKey: .userId)
        accountId = container.flexibleString(forKey: .accountId)
        email = container.flexibleString(forKey: .email)
        planType = container.flexibleString(forKey: .planType)
        rateLimit = container.lossy(RateLimit.self, forKey: .rateLimit)
        additionalRateLimits = container.lossy(LossyArray<AdditionalLimit>.self, forKey: .additionalRateLimits)?.values
        credits = container.lossy(Credits.self, forKey: .credits)
        spendControl = container.lossy(SpendControl.self, forKey: .spendControl)
        rateLimitReachedType = container.flexibleString(forKey: .rateLimitReachedType)
    }
}
