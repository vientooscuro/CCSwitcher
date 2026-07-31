import Foundation

private let log = FileLog("CodexUsage")

/// Fetches Codex rate limits.
///
/// Primary source is the live endpoint. When it is unreachable, the fallback is
/// the newest `rate_limits` block Codex itself wrote into a rollout file — data
/// derived from files Codex maintains for its own use, and therefore far more
/// stable than the undocumented endpoint.
///
/// This service never issues an OAuth refresh grant. The Codex access token
/// lives 10 days and the Codex CLI owns refreshing it; a second refresher would
/// risk the token-family revocation the project already avoids on the Claude
/// side, for no benefit.
actor CodexUsageService {
    static let shared = CodexUsageService()

    enum UsageError: LocalizedError {
        case needsReauth
        case rateLimited(retryAfter: TimeInterval)
        case transport(String)
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .needsReauth:
                return String(localized: "Codex session expired. Run `codex login` to sign in again.", bundle: L10n.bundle)
            case .rateLimited:
                return String(localized: "Codex API rate-limited. Retrying automatically.", bundle: L10n.bundle)
            case .transport(let detail):
                return String(localized: "Could not reach Codex: \(detail)", bundle: L10n.bundle)
            case .badStatus(let code):
                return String(localized: "Codex usage request failed (HTTP \(code)).", bundle: L10n.bundle)
            }
        }
    }

    struct Result: Sendable {
        let snapshot: CodexRateLimitSnapshot
        let email: String?
        /// True when the numbers came from a local rollout file rather than live.
        let isStale: Bool
        let observedAt: Date
    }

    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/usage")!

    private static var lastKnownURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("CCSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("codex-usage-last-known.json")
    }

    /// Live fetch with the given credentials. Throws rather than falling back,
    /// so the caller decides whether a stale local snapshot is acceptable.
    func fetchLive(accessToken: String, accountId: String?) async throws -> Result {
        guard !CodexAuthService.isAccessTokenExpired(accessToken) else {
            log.warning("fetchLive: access token expired locally, not sending request")
            throw UsageError.needsReauth
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: makeRequest(accessToken: accessToken, accountId: accountId))
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            let decoded: CodexUsageResponse
            do {
                decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            } catch {
                throw UsageError.transport("unexpected payload: \(error.localizedDescription)")
            }
            let result = Result(
                snapshot: CodexRateLimitSnapshot(response: decoded),
                email: decoded.email,
                isStale: false,
                observedAt: Date()
            )
            persistLastKnown(result)
            log.info("fetchLive: ok, plan=\(decoded.planType ?? "?") windows=\(result.snapshot.windows.count)")
            return result

        case 401, 403:
            log.warning("fetchLive: \(http.statusCode) — credentials rejected")
            throw UsageError.needsReauth

        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
            log.warning("fetchLive: 429, backing off \(Int(retryAfter))s")
            throw UsageError.rateLimited(retryAfter: retryAfter)

        default:
            log.warning("fetchLive: unexpected status \(http.statusCode)")
            throw UsageError.badStatus(http.statusCode)
        }
    }

    /// Local fallback: the newest snapshot Codex wrote, or the last live answer
    /// we persisted, whichever is newer. Used when the endpoint fails and to
    /// populate the popover before the first fetch completes.
    func localFallback() async -> Result? {
        let fromRollouts = await CodexSessionCache.shared.latestLocalSnapshot()
            .map { Result(snapshot: $0.snapshot, email: nil, isStale: true, observedAt: $0.observedAt) }
        let fromCache = loadLastKnown()

        switch (fromRollouts, fromCache) {
        case (let rollout?, let cached?):
            return rollout.observedAt >= cached.observedAt ? rollout : cached
        case (let rollout?, nil):
            return rollout
        case (nil, let cached?):
            return cached
        case (nil, nil):
            return nil
        }
    }

    // MARK: - Private

    private func makeRequest(accessToken: String, accountId: String?) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        // Header set confirmed against the live endpoint in Task 6 Step 1: a
        // bare `Authorization: Bearer <token>` already returns 200 from
        // URLSession — `chatgpt-account-id` and a `CCSwitcher/<version>` User-
        // Agent were also tried and accepted, but neither is required. Sending
        // them anyway scopes the request unambiguously and identifies us
        // honestly. `originator: codex_cli_rs` was never needed and is
        // deliberately omitted. Curl/urllib against the same endpoint get a
        // Cloudflare bot-management 403 regardless of headers (even on a bare
        // unauthenticated request) — that block keys off the client's TLS/HTTP
        // fingerprint, not our headers, and does not reproduce through
        // URLSession. Keep this list minimal: every extra header is one more
        // thing that can start being validated and break the request.
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId {
            request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        request.setValue("CCSwitcher/\(version)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        return request
    }

    private struct LastKnown: Codable {
        let snapshot: CodexRateLimitSnapshot
        let email: String?
        let observedAt: Date
    }

    private func persistLastKnown(_ result: Result) {
        let payload = LastKnown(snapshot: result.snapshot, email: result.email, observedAt: result.observedAt)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Self.lastKnownURL, options: .atomic)
    }

    private func loadLastKnown() -> Result? {
        guard let data = try? Data(contentsOf: Self.lastKnownURL),
              let payload = try? JSONDecoder().decode(LastKnown.self, from: data) else { return nil }
        return Result(snapshot: payload.snapshot, email: payload.email, isStale: true, observedAt: payload.observedAt)
    }
}
