import Foundation

private let log = FileLog("Claude")

/// Interacts with the Claude CLI to get auth status and manage accounts.
final class ClaudeService: Sendable {
    static let shared = ClaudeService()

    /// Resolved lazily on a background queue so app launch never blocks on
    /// `/bin/zsh -ilc` (which can take seconds with a heavy `.zshrc`).
    private let pathTask: Task<String, Never>

    /// Pre-built process environment (PATH + HOME). Computed once after path
    /// resolution and reused for every `runClaude` invocation.
    private let envTask: Task<[String: String], Never>

    /// Custom URLSession with a 10s request timeout — `URLSession.shared`'s
    /// default 60s causes `refresh()` to hang for up to a minute when the API
    /// endpoint is unresponsive.
    private let session: URLSession

    private init() {
        let curated = Self.curatedPaths()
        let immediate = curated.first { FileManager.default.fileExists(atPath: $0) }

        // Path resolution: try curated paths synchronously (cheap — just
        // `fileExists`), and only fork zsh in the background if we have to.
        let pathTask = Task<String, Never>.detached(priority: .userInitiated) {
            if let immediate {
                log.info("Claude binary path: \(immediate) (curated)")
                return immediate
            }
            if let shellPath = Self.shellPathLookup() {
                log.info("Claude binary path: \(shellPath) (resolved via user shell PATH)")
                return shellPath
            }
            log.warning("Claude binary not found; falling back to bare 'claude'")
            return "claude"
        }
        self.pathTask = pathTask

        self.envTask = Task<[String: String], Never>.detached(priority: .userInitiated) {
            let path = await pathTask.value
            return Self.buildEnvironment(claudePath: path)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Path discovery

    private static func curatedPaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/opt/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.volta/bin/claude",
            "\(home)/Library/pnpm/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.yarn/bin/claude"
        ] + nvmPaths()
    }

    private static func nvmPaths() -> [String] {
        let nvmDir = "\(NSHomeDirectory())/.nvm/versions/node"
        guard FileManager.default.fileExists(atPath: nvmDir) else { return [] }
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) else { return [] }
        return versions
            .filter { !$0.hasPrefix(".") }
            .map { "\(nvmDir)/\($0)/bin/claude" }
    }

    private static func shellPathLookup() -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v claude"]
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            log.warning("[shellPathLookup] Failed to launch /bin/zsh: \(error.localizedDescription)")
            return nil
        }

        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            log.warning("[shellPathLookup] zsh exceeded 3s timeout; aborting")
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let candidate = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard candidate.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: candidate) else {
            return nil
        }
        return candidate
    }

    private static func buildEnvironment(claudePath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let homeDir = NSHomeDirectory()

        var extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDir)/.local/bin",
            "\(homeDir)/.npm-global/bin"
        ]
        if claudePath.contains("/") {
            // Resolve symlinks once so NVM-installed CLIs find `node` on PATH.
            let resolved = URL(fileURLWithPath: claudePath).resolvingSymlinksInPath().path
            let resolvedBinDir = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
            extraPaths.insert(resolvedBinDir, at: 0)
        }
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        env["HOME"] = homeDir
        return env
    }

    // MARK: - Auth Status

    func getAuthStatus() async throws -> AuthStatus {
        log.info("[getAuthStatus] Fetching auth status...")
        let output = try await runClaude(args: ["auth", "status"])
        guard let data = output.data(using: .utf8) else {
            log.error("[getAuthStatus] Invalid output (not UTF-8)")
            throw ClaudeServiceError.invalidOutput
        }
        let status = try JSONDecoder().decode(AuthStatus.self, from: data)
        log.info("[getAuthStatus] loggedIn=\(status.loggedIn), provider=\(status.apiProvider ?? "nil"), sub=\(status.subscriptionType ?? "nil")")
        return status
    }

    func isClaudeAvailable() async -> Bool {
        do {
            let version = try await runClaude(args: ["--version"])
            log.info("[isClaudeAvailable] YES, version: \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
            return true
        } catch {
            log.error("[isClaudeAvailable] NO, error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Usage API

    enum UsageError: Error {
        case expired
        /// HTTP 429 from the usage endpoint. `retryAfter` is the suggested
        /// back-off in seconds (parsed from the `Retry-After` header, or 60s
        /// when the server didn't send one).
        case rateLimited(retryAfter: TimeInterval)
        case network(String)
        case decode(String)
    }

    /// Fetch usage for a specific access token
    func getUsageLimits(accessToken: String) async throws -> UsageAPIResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { throw UsageError.network("invalid url") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        log.debug("[getUsageLimits] REQUEST URL: \(url.absoluteString)")

        let (responseData, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        guard httpResponse?.statusCode == 200 else {
            let responseString = String(data: responseData, encoding: .utf8) ?? ""
            let status = httpResponse?.statusCode ?? 0
            log.error("[getUsageLimits] HTTP \(status)")

            if status == 401 || responseString.contains("token_expired") {
                throw UsageError.expired
            }
            if status == 429 {
                // Honor Retry-After when present (seconds or HTTP-date; we
                // only handle the integer-seconds form here).
                let retryAfter: TimeInterval = (httpResponse?.value(forHTTPHeaderField: "Retry-After"))
                    .flatMap(TimeInterval.init) ?? 60
                log.warning("[getUsageLimits] 429 rate limited, Retry-After=\(retryAfter)s")
                throw UsageError.rateLimited(retryAfter: retryAfter)
            }
            throw UsageError.network("HTTP \(status)")
        }

        do {
            let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: responseData)
            log.info("[getUsageLimits] session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
            return usage
        } catch {
            log.error("[getUsageLimits] Decode Error: \(error.localizedDescription)")
            throw UsageError.decode(error.localizedDescription)
        }
    }

    /// Extract access token string from a token JSON (keychain format).
    /// Shape: `{ "claudeAiOauth": { "accessToken": "...", "refreshToken": "...", "expiresAt": <ms> } }`.
    private struct TokenEnvelope: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let refreshToken: String?
            // Stored as integer milliseconds since epoch in the keychain blob.
            let expiresAt: Double?
        }
        let claudeAiOauth: OAuth
    }

    /// Parsed credentials extracted from a keychain token JSON.
    struct TokenCredentials: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    static func extractAccessToken(from tokenJSON: String) -> String? {
        extractCredentials(from: tokenJSON)?.accessToken
    }

    static func extractCredentials(from tokenJSON: String) -> TokenCredentials? {
        guard let data = tokenJSON.data(using: .utf8),
              let env = try? JSONDecoder().decode(TokenEnvelope.self, from: data) else { return nil }
        let oauth = env.claudeAiOauth
        let exp = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        return TokenCredentials(accessToken: oauth.accessToken, refreshToken: oauth.refreshToken, expiresAt: exp)
    }

    // MARK: - OAuth Token Refresh
    //
    // Performs the OAuth refresh-token grant against Claude's token endpoint
    // directly, so an expired access token can be silently revived without
    // making the user switch accounts. The endpoint URL and client_id below
    // are the same values shipped inside the public `claude` CLI binary
    // (see `strings $(which claude) | grep oauth/token`).
    private static let oauthTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    enum RefreshError: Error {
        /// No `refreshToken` in the stored envelope — the user must re-auth.
        case noRefreshToken
        /// Server rejected the refresh_token (HTTP 4xx). Often means the
        /// token has been revoked or rotated past it; user must re-auth.
        case invalidGrant
        case network(String)
        case decode(String)
    }

    /// Refreshes the OAuth access token in-place. Reads `refreshToken` from
    /// `currentTokenJSON`, hits Claude's token endpoint, and returns a new
    /// keychain-ready JSON blob with `accessToken` / `refreshToken` /
    /// `expiresAt` replaced and every other field (`scopes`, `subscriptionType`,
    /// `rateLimitTier`, …) preserved.
    ///
    /// Caller is responsible for writing `mergedJSON` back via
    /// `KeychainService.writeClaudeToken` (active account) or
    /// `saveAccountBackup` (inactive account).
    func refreshOAuthToken(currentTokenJSON: String) async throws -> (accessToken: String, mergedJSON: String) {
        guard let data = currentTokenJSON.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String,
              !refreshToken.isEmpty
        else {
            log.warning("[refreshOAuthToken] No refresh_token in stored envelope")
            throw RefreshError.noRefreshToken
        }

        var req = URLRequest(url: Self.oauthTokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let payload: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientId,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        log.info("[refreshOAuthToken] POST \(Self.oauthTokenURL.absoluteString)")

        let respData: Data
        let response: URLResponse
        do {
            (respData, response) = try await session.data(for: req)
        } catch {
            log.error("[refreshOAuthToken] Network error: \(error.localizedDescription)")
            throw RefreshError.network(error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            let bodyPreview = String(data: respData, encoding: .utf8)?.prefix(300) ?? ""
            let status = http?.statusCode ?? -1
            log.error("[refreshOAuthToken] HTTP \(status): \(bodyPreview)")
            if (400...499).contains(status) {
                throw RefreshError.invalidGrant
            }
            throw RefreshError.network("HTTP \(status)")
        }

        struct RefreshResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        let parsed: RefreshResponse
        do {
            parsed = try JSONDecoder().decode(RefreshResponse.self, from: respData)
        } catch {
            log.error("[refreshOAuthToken] Decode failed: \(error.localizedDescription)")
            throw RefreshError.decode(error.localizedDescription)
        }

        oauth["accessToken"] = parsed.accessToken
        if let newRefresh = parsed.refreshToken { oauth["refreshToken"] = newRefresh }
        if let ttlSeconds = parsed.expiresIn {
            // Keep the format the keychain blob already uses: ms since epoch.
            oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + Double(ttlSeconds)) * 1000)
        }
        root["claudeAiOauth"] = oauth

        guard let mergedData = try? JSONSerialization.data(withJSONObject: root),
              let mergedJSON = String(data: mergedData, encoding: .utf8) else {
            throw RefreshError.decode("re-serialize")
        }

        log.info("[refreshOAuthToken] OK, ttl=\(parsed.expiresIn ?? 0)s, rotatedRefresh=\(parsed.refreshToken != nil)")
        return (parsed.accessToken, mergedJSON)
    }

    // MARK: - Account Switching

    /// Switches credentials and verifies. Returns the verified `AuthStatus`
    /// so the caller can avoid running `claude auth status` a second time.
    @discardableResult
    func switchAccount(from currentAccount: Account, to targetAccount: Account) async throws -> AuthStatus {
        let keychain = KeychainService.shared

        log.info("[switchAccount] Switching from \(currentAccount.id) to \(targetAccount.id)")

        log.info("[switchAccount] Step 1: Backing up current account...")
        if let currentToken = await keychain.readClaudeToken(),
           let currentOAuth = await keychain.readOAuthAccount() {
            let email = (currentOAuth["emailAddress"]?.value as? String) ?? "?"
            if email == currentAccount.email {
                let saved = await keychain.saveAccountBackup(token: currentToken, oauthAccount: currentOAuth, forAccountId: currentAccount.id.uuidString)
                log.info("[switchAccount] Step 1: Backup saved: \(saved)")
            } else {
                log.warning("[switchAccount] Step 1: oauthAccount email (\(email)) != source (\(currentAccount.email)), skipping backup")
            }
        } else {
            log.warning("[switchAccount] Step 1: Could not read current token or oauthAccount")
        }

        log.info("[switchAccount] Step 2: Reading backup for target account...")
        guard let targetBackup = await keychain.getAccountBackup(forAccountId: targetAccount.id.uuidString) else {
            log.error("[switchAccount] Step 2: No backup found for target account!")
            throw ClaudeServiceError.noTokenForAccount(targetAccount.id.uuidString)
        }
        let targetEmail = (targetBackup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
        log.info("[switchAccount] Step 2: Target backup found (email=\(targetEmail))")

        log.info("[switchAccount] Step 3: Writing target credentials...")
        guard await keychain.writeClaudeToken(targetBackup.token) else {
            log.error("[switchAccount] Step 3: Failed to write token to keychain!")
            throw ClaudeServiceError.keychainWriteFailed
        }
        guard await keychain.writeOAuthAccount(targetBackup.oauthAccount) else {
            log.error("[switchAccount] Step 3: Failed to write oauthAccount to ~/.claude.json!")
            throw ClaudeServiceError.oauthAccountWriteFailed
        }
        log.info("[switchAccount] Step 3: Both token and oauthAccount written")

        log.info("[switchAccount] Step 4: Verifying with `claude auth status`...")
        let status = try await getAuthStatus()
        guard status.loggedIn else {
            log.error("[switchAccount] Step 4: Not logged in after switch!")
            throw ClaudeServiceError.switchVerificationFailed
        }
        if status.email != targetAccount.email {
            log.error("[switchAccount] Step 4: Logged in as \(status.email ?? "nil") instead of \(targetAccount.email)")
            throw ClaudeServiceError.switchWrongAccount(expected: targetAccount.email, actual: status.email ?? "unknown")
        }
        log.info("[switchAccount] Step 4: Switch verified — logged in as \(status.email ?? "")")
        return status
    }

    /// Capture the current Claude auth token + oauthAccount and associate with an account
    func captureCurrentCredentials(forAccountId accountId: String) async -> Bool {
        log.info("[capture] Capturing credentials for account \(accountId)...")
        let keychain = KeychainService.shared
        guard let token = await keychain.readClaudeToken() else {
            log.error("[capture] Failed: no token found in keychain")
            return false
        }
        guard let oauthAccount = await keychain.readOAuthAccount() else {
            log.error("[capture] Failed: no oauthAccount found in ~/.claude.json")
            return false
        }
        let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
        log.info("[capture] Token + oauthAccount found (email=\(email)), saving backup...")
        let result = await keychain.saveAccountBackup(token: token, oauthAccount: oauthAccount, forAccountId: accountId)
        log.info("[capture] Save result: \(result)")
        return result
    }

    /// Run `claude auth login` which opens browser for OAuth.
    func login() async throws {
        log.info("[login] Starting `claude auth login`... (will open browser)")
        _ = try await runClaude(args: ["auth", "login"])
        log.info("[login] `claude auth login` process exited")

        try await Task.sleep(for: .seconds(1))
        log.info("[login] Post-login delay complete, ready for token capture")
    }

    /// Run `claude auth logout`
    func logout() async throws {
        log.info("[logout] Running `claude auth logout`...")
        _ = try await runClaude(args: ["auth", "logout"])
        log.info("[logout] Logout complete")
    }

    // MARK: - CLI Runner

    private func runClaude(args: [String]) async throws -> String {
        let claudePath = await pathTask.value
        let env = await envTask.value
        log.debug("[runClaude] Running: claude \(args.joined(separator: " "))")

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe
                process.environment = env

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        log.debug("[runClaude] Success (exit 0), output length: \(output.count)")
                        continuation.resume(returning: output)
                    } else {
                        log.error("[runClaude] Failed (exit \(process.terminationStatus))")
                        continuation.resume(throwing: ClaudeServiceError.cliError("exit \(process.terminationStatus)"))
                    }
                } catch {
                    log.error("[runClaude] Process launch failed: \(error.localizedDescription)")
                    continuation.resume(throwing: ClaudeServiceError.processLaunchFailed(error))
                }
            }
        }
    }
}

// MARK: - Errors

enum ClaudeServiceError: LocalizedError {
    case invalidOutput
    case cliError(String)
    case processLaunchFailed(Error)
    case noTokenForAccount(String)
    case keychainWriteFailed
    case oauthAccountWriteFailed
    case switchVerificationFailed
    case switchWrongAccount(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidOutput:
            return "Invalid output from Claude CLI"
        case .cliError(let msg):
            return "Claude CLI error: \(msg)"
        case .processLaunchFailed(let error):
            return "Failed to launch Claude: \(error.localizedDescription)"
        case .noTokenForAccount:
            return "No stored backup for target account"
        case .keychainWriteFailed:
            return "Failed to write token to keychain"
        case .oauthAccountWriteFailed:
            return "Failed to write oauthAccount to ~/.claude.json"
        case .switchVerificationFailed:
            return "Account switch verification failed"
        case .switchWrongAccount(let expected, let actual):
            return "Switch failed: expected \(expected) but got \(actual). Try removing and re-adding the account."
        }
    }
}
