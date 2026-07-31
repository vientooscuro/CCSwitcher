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
