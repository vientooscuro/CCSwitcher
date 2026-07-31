import SwiftUI

private let log = FileLog("CodexState")

/// Codex provider state. Read-only in stage 2: it observes `~/.codex` and the
/// usage endpoint but writes nothing. Account switching arrives in stage 3,
/// gated by `capabilities`.
@MainActor
final class CodexState: ObservableObject, ProviderSurface {

    @Published private(set) var isLoading = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefresh: Date?

    @Published private var snapshot: CodexRateLimitSnapshot?
    @Published private var snapshotIsStale = false
    @Published private var email: String?
    @Published private var name: String?
    @Published private var planType: String?
    @Published private var usageError: ProviderErrorModel?
    @Published private var costSeries: CostSeriesModel = .empty
    @Published private var activitySummary: ActivitySummaryModel = .empty

    /// Identity for the single Codex account stage 2 knows about. Derived from
    /// the account id so it is stable across launches without persistence,
    /// which stage 3 replaces with real per-account records.
    private var accountId: UUID = UUID()

    /// Per-account 429 back-off, matching the Claude behaviour: a rate limit
    /// blocks refreshes but must not discard numbers already fetched.
    private var rateLimitedUntil: Date?

    private let usageService = CodexUsageService.shared
    private let sessionCache = CodexSessionCache.shared

    var providerType: AIProviderType { .codex }

    var isAvailable: Bool { CodexAuthService.isInstalled }

    var capabilities: ProviderCapabilities {
        // Stage 2 is read-only. Stage 3 flips the first four flags on.
        ProviderCapabilities(
            canSwitchAccounts: false,
            canImportCurrent: false,
            canLoginNewAccount: false,
            canReauthenticate: false,
            managesAccounts: false,
            tracksLinesWritten: true
        )
    }

    var header: AccountHeaderModel? {
        guard let email else { return nil }
        let obfuscate = !UserDefaults.standard.bool(forKey: "showFullEmail")
        return AccountHeaderModel(
            title: name ?? (obfuscate ? email.obfuscatedEmail() : email),
            subtitle: obfuscate ? email.obfuscatedEmail() : email,
            planBadge: CodexDisplayMapper.planBadge(from: planType)
        )
    }

    var accountCards: [UsageCardModel] {
        guard let email else { return [] }
        let obfuscate = !UserDefaults.standard.bool(forKey: "showFullEmail")
        let displayEmail = obfuscate ? email.obfuscatedEmail() : email
        let snapshot = snapshot ?? .empty
        return [UsageCardModel(
            id: accountId,
            title: name ?? displayEmail,
            subtitle: displayEmail,
            planBadge: CodexDisplayMapper.planBadge(from: planType),
            isActive: true,
            windows: CodexDisplayMapper.windows(from: snapshot),
            scopedLimits: CodexDisplayMapper.scopedLimits(from: snapshot),
            credits: self.snapshot == nil ? nil : CodexDisplayMapper.credits(from: snapshot),
            notice: CodexDisplayMapper.notice(from: snapshot, isStale: snapshotIsStale),
            error: usageError
        )]
    }

    var accountRows: [AccountRowModel] {
        guard let email else { return [] }
        let obfuscate = !UserDefaults.standard.bool(forKey: "showFullEmail")
        let displayEmail = obfuscate ? email.obfuscatedEmail() : email
        return [AccountRowModel(
            id: accountId,
            title: name ?? displayEmail,
            email: displayEmail,
            planBadge: CodexDisplayMapper.planBadge(from: planType),
            isActive: true,
            lastUsedText: nil,
            hasStoredCredentials: true,
            rawLabel: nil
        )]
    }

    var activity: ActivitySummaryModel { activitySummary }

    var cost: CostSeriesModel { costSeries }

    // MARK: - Refresh

    func refresh(force: Bool) async {
        guard isAvailable else {
            errorMessage = String(localized: "Codex is not signed in on this Mac.", bundle: L10n.bundle)
            return
        }

        isLoading = true
        errorMessage = nil

        // Identity first: it comes from a local file and must render even if the
        // network is unavailable.
        let auth: CodexAuth?
        do {
            let loaded = try CodexAuthService.loadCurrent()
            auth = loaded
            let claims = CodexAuthService.claims(fromIDToken: loaded.tokens.idToken)
            email = claims?.email
            name = claims?.name
            // Provisional: the live endpoint's plan is authoritative and
            // overwrites this below. The id_token was observed reporting a
            // stale `prolite` where the endpoint said `pro`.
            if planType == nil { planType = claims?.planType }
        } catch {
            auth = nil
            errorMessage = error.localizedDescription
            log.error("[refresh] credentials unreadable: \(error.localizedDescription)")
        }

        await refreshLimits(auth: auth, force: force)
        await refreshCostAndActivity()

        lastRefresh = Date()
        isLoading = false
    }

    private func refreshLimits(auth: CodexAuth?, force: Bool) async {
        if !force, let until = rateLimitedUntil, until > Date() {
            log.info("[refresh] skipping limits — rate limited for \(Int(until.timeIntervalSinceNow))s more")
            return
        }

        guard let auth else {
            await applyFallback()
            return
        }

        do {
            let result = try await usageService.fetchLive(
                accessToken: auth.tokens.accessToken,
                accountId: auth.tokens.accountId
            )
            snapshot = result.snapshot
            snapshotIsStale = false
            planType = result.snapshot.planType ?? planType
            if let live = result.email { email = live }
            usageError = nil
            rateLimitedUntil = nil
        } catch CodexUsageService.UsageError.rateLimited(let retryAfter) {
            rateLimitedUntil = Date().addingTimeInterval(retryAfter)
            // Keep existing numbers; a 429 blocks refresh, it does not
            // invalidate what we already have.
            usageError = ProviderErrorModel(
                message: CodexUsageService.UsageError.rateLimited(retryAfter: retryAfter).localizedDescription,
                needsReauth: false,
                isRateLimited: true
            )
            if snapshot == nil { await applyFallback() }
        } catch CodexUsageService.UsageError.needsReauth {
            usageError = ProviderErrorModel(
                message: CodexUsageService.UsageError.needsReauth.localizedDescription,
                needsReauth: true,
                isRateLimited: false
            )
            await applyFallback()
        } catch {
            log.warning("[refresh] live limits failed: \(error.localizedDescription)")
            await applyFallback()
            if snapshot == nil {
                usageError = ProviderErrorModel(message: error.localizedDescription, needsReauth: false, isRateLimited: false)
            }
        }
    }

    private func applyFallback() async {
        guard let fallback = await usageService.localFallback() else { return }
        snapshot = fallback.snapshot
        snapshotIsStale = true
        planType = fallback.snapshot.planType ?? planType
        if email == nil { email = fallback.email }
        log.info("[refresh] using local snapshot from \(fallback.observedAt)")
    }

    private func refreshCostAndActivity() async {
        await PricingService.shared.reloadIfFreshChanged()
        PricingService.shared.refreshInBackground()
        await sessionCache.refreshFromFilesystem()
        costSeries = await sessionCache.costSeries()
        activitySummary = await sessionCache.activityToday()
        log.info("[refresh] today=$\(String(format: "%.2f", costSeries.todayCost)) turns=\(activitySummary.turns)")
    }

    // MARK: - Actions (stage 3)

    func switchTo(accountId: UUID) async {
        log.warning("[switchTo] not supported until stage 3")
    }

    func importCurrentAccount() async {
        log.warning("[importCurrentAccount] not supported until stage 3")
    }

    func loginNewAccount() async {
        log.warning("[loginNewAccount] not supported until stage 3")
    }

    func removeAccount(id: UUID) {
        log.warning("[removeAccount] not supported until stage 3")
    }

    func reauthenticate(id: UUID) async {
        log.warning("[reauthenticate] not supported until stage 3")
    }

    func setLabel(_ label: String?, forAccount id: UUID) {
        log.warning("[setLabel] not supported until stage 3")
    }
}
