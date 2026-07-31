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
