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
