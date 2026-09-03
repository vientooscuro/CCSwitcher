import SwiftUI

private let log = FileLog("CodexState")

/// Desktop accounts keep independent live credentials; snapshots are never restored.
@MainActor
final class CodexState: ObservableObject, ProviderSurface {

    @Published private(set) var isLoading = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefresh: Date?

    @Published private(set) var accounts: [Account] = []
    /// Ids that currently have a stored `auth.json` backup, from one store read.
    @Published private(set) var accountsWithBackups: Set<UUID> = []

    @Published private var snapshot: CodexRateLimitSnapshot?
    @Published private var snapshotIsStale = false
    @Published private var email: String?
    @Published private var name: String?
    @Published private var planType: String?
    @Published private var usageError: ProviderErrorModel?
    @Published private var costSeries: CostSeriesModel = .empty
    @Published private var activitySummary: ActivitySummaryModel = .empty
    /// Set when the live `auth.json` fingerprint matches no known account —
    /// surfaced on the active account's card until the user imports it.
    @Published private var desyncNotice: String?

    /// Set by `ProviderHub` at init. Called once a refresh finishes.
    var didRefresh: (() -> Void)?

    /// Last-known numbers for accounts that are not currently active, so
    /// switching away from an account does not blank its card.
    private var accountSnapshots: [UUID: CodexRateLimitSnapshot] = [:]

    /// Per-account 429 back-off, matching the Claude behaviour: a rate limit
    /// blocks refreshes but must not discard numbers already fetched.
    private var rateLimitedUntil: Date?

    private let usageService = CodexUsageService.shared
    private var profileSessionCaches: [String: CodexSessionCache] = [:]
    private let defaults: UserDefaults
    let profiles: CodexDesktopProfiles
    private let openDesktop: (CodexDesktopProfile) async throws -> Void
    private var loginTask: Task<Void, Never>?
    private var loginGeneration = UUID()
    private static let pendingLoginKey = "codexDesktopPendingLoginID"
    private static let pendingLoginPausedKey = "codexDesktopPendingLoginPaused"

    init(
        defaults: UserDefaults = .standard,
        profiles: CodexDesktopProfiles? = nil,
        openDesktop: @escaping (CodexDesktopProfile) async throws -> Void = CodexDesktopProfiles.open
    ) {
        self.defaults = defaults
        self.profiles = profiles ?? CodexDesktopProfiles(defaults: defaults)
        self.openDesktop = openDesktop
        accounts = CodexAccountRegistry.load(from: defaults)
    }

    var selectedProfile: CodexDesktopProfile {
        accounts.first(where: \.isActive).map { profiles.profile(for: $0.id) } ?? profiles.defaultProfile
    }

    var pendingLoginID: UUID? {
        defaults.string(forKey: Self.pendingLoginKey).flatMap(UUID.init(uuidString:))
    }

    var providerType: AIProviderType { .codex }

    var isAvailable: Bool { CodexDesktopProfiles.applicationURL != nil || !accounts.isEmpty }

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            canSwitchAccounts: true,
            canImportCurrent: true,
            canLoginNewAccount: true,
            canReauthenticate: true,
            managesAccounts: true,
            tracksLinesWritten: true
        )
    }

    private var obfuscateEmails: Bool {
        !UserDefaults.standard.bool(forKey: "showFullEmail")
    }

    var header: AccountHeaderModel? {
        guard let account = accounts.first(where: \.isActive) else { return nil }
        let obfuscate = obfuscateEmails
        return AccountHeaderModel(
            title: account.effectiveDisplayName(obfuscated: obfuscate),
            subtitle: account.displayEmail(obfuscated: obfuscate),
            planBadge: account.displaySubscriptionType
        )
    }

    var accountCards: [UsageCardModel] {
        let obfuscate = obfuscateEmails
        return accounts.map { account in
            let effectiveSnapshot = account.isActive ? snapshot : accountSnapshots[account.id]
            let notice = account.isActive
                ? desyncNotice ?? effectiveSnapshot.flatMap { CodexDisplayMapper.notice(from: $0, isStale: snapshotIsStale) }
                : effectiveSnapshot.flatMap { CodexDisplayMapper.notice(from: $0, isStale: true) }
            return UsageCardModel(
                id: account.id,
                title: account.effectiveDisplayName(obfuscated: obfuscate),
                subtitle: account.displayEmail(obfuscated: obfuscate),
                planBadge: account.displaySubscriptionType,
                isActive: account.isActive,
                windows: effectiveSnapshot.map(CodexDisplayMapper.windows(from:)) ?? [],
                scopedLimits: effectiveSnapshot.map(CodexDisplayMapper.scopedLimits(from:)) ?? [],
                credits: effectiveSnapshot.flatMap(CodexDisplayMapper.credits(from:)),
                notice: notice,
                error: account.isActive ? usageError : nil
            )
        }
    }

    var accountRows: [AccountRowModel] {
        let obfuscate = obfuscateEmails
        return accounts.map { account in
            AccountRowModel(
                id: account.id,
                title: account.effectiveDisplayName(obfuscated: obfuscate),
                email: account.displayEmail(obfuscated: obfuscate),
                planBadge: account.displaySubscriptionType,
                isActive: account.isActive,
                lastUsedText: account.lastUsed.map { Formatters.monthDay.string(from: $0) },
                hasStoredCredentials: true,
                rawLabel: account.customLabel
            )
        }
    }

    var activity: ActivitySummaryModel { activitySummary }

    var cost: CostSeriesModel { costSeries }

    /// Flattens Codex state for the desktop widget. The per-account mapping
    /// (windows matched by `kind`, not position) lives in the pure
    /// `CodexDisplayMapper.widgetAccount`, unit-tested independently of this
    /// class's network/credential state.
    var widgetSnapshot: WidgetData {
        let card = accountCards.first { $0.isActive }
        let account = accounts.first { $0.isActive }
        let obfuscate = obfuscateEmails

        let widgetAccounts: [WidgetAccountData] = account.map { account in
            [CodexDisplayMapper.widgetAccount(
                email: account.displayEmail(obfuscated: obfuscate),
                displayName: account.effectiveDisplayName(obfuscated: obfuscate),
                planBadge: account.displaySubscriptionType,
                windows: card?.windows ?? [],
                scopedLimits: card?.scopedLimits ?? [],
                credits: card?.credits,
                error: usageError
            )]
        } ?? []

        return WidgetData(
            accounts: widgetAccounts,
            todayCost: costSeries.todayCost,
            conversationTurns: activitySummary.turns,
            activeCodingTime: activitySummary.activeTimeText,
            linesWritten: activitySummary.linesWritten ?? 0,
            modelUsage: Dictionary(uniqueKeysWithValues: activitySummary.perModel.map { ($0.displayName, $0.count) }),
            lastUpdated: Date(),
            provider: AIProviderType.codex.rawValue
        )
    }

    // MARK: - Refresh

    func refresh(force: Bool) async {
        guard !isLoading else { return }
        reconcileDefaultProfile()
        refreshBackupPresence()
        if pendingLoginID != nil, loginTask == nil, !defaults.bool(forKey: Self.pendingLoginPausedKey) {
            observePendingLogin()
        }
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
            let loaded = try Self.loadAuth(from: selectedProfile)
            if let active = accounts.first(where: \.isActive),
               CodexAuthService.claims(fromIDToken: loaded.tokens.idToken)?.email != active.email {
                throw NSError(domain: "CodexDesktop", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "This Codex profile is signed in to a different account. Open Codex and sign in to the expected account."
                ])
            }
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
        syncActiveAccountFields()
        if let activeId = accounts.first(where: \.isActive)?.id, let snapshot {
            accountSnapshots[activeId] = snapshot
        }

        lastRefresh = Date()
        isLoading = false
        didRefresh?()
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
            guard let profileID = accounts.first(where: \.isActive)?.id else { return }
            let result = try await usageService.fetchLive(
                accessToken: auth.tokens.accessToken,
                accountId: auth.tokens.accountId,
                profileID: profileID
            )
            snapshot = result.snapshot
            snapshotIsStale = false
            planType = result.snapshot.planType ?? planType
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
        guard let id = accounts.first(where: \.isActive)?.id,
              let fallback = await usageService.localFallback(profileID: id) else { return }
        snapshot = fallback.snapshot
        snapshotIsStale = true
        planType = fallback.snapshot.planType ?? planType
        log.info("[refresh] using local snapshot from \(fallback.observedAt)")
    }

    private func refreshCostAndActivity() async {
        let profile = selectedProfile
        let sessionCache: CodexSessionCache
        if profile.isDefault {
            sessionCache = .shared
        } else if let cached = profileSessionCaches[profile.home.path] {
            sessionCache = cached
        } else {
            sessionCache = CodexSessionCache(
                sessionsRoot: profile.home.appendingPathComponent("sessions").path,
                cacheURL: profile.home.appendingPathComponent("ccswitcher-session-cache.json")
            )
            profileSessionCaches[profile.home.path] = sessionCache
        }
        await PricingService.shared.reloadIfFreshChanged()
        PricingService.shared.refreshInBackground()
        await sessionCache.refreshFromFilesystem()
        costSeries = await sessionCache.costSeries()
        activitySummary = await sessionCache.activityToday()
        log.info("[refresh] today=$\(String(format: "%.2f", costSeries.todayCost)) turns=\(activitySummary.turns)")
    }

    /// Keeps the active account's persisted display fields (email/name/plan)
    /// in step with whatever the live credentials and usage endpoint just
    /// reported, so its row/card read correctly even before the next refresh.
    private func syncActiveAccountFields() {
        guard let index = accounts.firstIndex(where: \.isActive), let email else { return }
        let displayName = name ?? email
        guard accounts[index].email != email
            || accounts[index].displayName != displayName
            || accounts[index].subscriptionType != planType else { return }
        accounts[index].email = email
        accounts[index].displayName = displayName
        accounts[index].subscriptionType = planType
        CodexAccountRegistry.save(accounts, to: defaults)
    }

    // MARK: - Desync guard

    /// Pure decision for what to do when the live `auth.json` fingerprint
    /// disagrees with the account CCSwitcher believes is active. A mismatch
    /// almost always means the user switched accounts inside Codex Desktop or
    /// the CLI — clobbering that would fight them, so this never recommends a
    /// write. It only decides whether to silently relabel which known account
    /// is "active", or leave everything alone and surface a notice.
    enum DesyncDecision: Equatable {
        /// The live file still belongs to the account we think is active.
        case matches
        /// The live file belongs to a different account we already know about.
        case adopt(UUID)
        /// The live file belongs to nobody CCSwitcher has on record.
        case unknown
    }

    static func desyncDecision(
        liveFingerprint: String,
        activeAccountId: UUID,
        knownFingerprints: [UUID: String]
    ) -> DesyncDecision {
        if knownFingerprints[activeAccountId] == liveFingerprint {
            return .matches
        }
        if let match = knownFingerprints.first(where: { $0.value == liveFingerprint && $0.key != activeAccountId }) {
            return .adopt(match.key)
        }
        return .unknown
    }

    /// Refuse an import that would duplicate an already-known email.
    static func wouldDuplicate(email: String, in accounts: [Account]) -> Bool {
        accounts.contains { $0.email == email }
    }

    static func loadAuth(from profile: CodexDesktopProfile) throws -> CodexAuth {
        let data = try Data(contentsOf: profile.authURL)
        return try CodexAuthService.decode(authJSON: data)
    }

    /// Migration binds the existing home in place; no credentials are copied.
    func reconcileDefaultProfile() {
        if let boundID = profiles.defaultAccountID, accounts.contains(where: { $0.id == boundID }) { return }
        guard let auth = try? Self.loadAuth(from: profiles.defaultProfile),
              let claims = CodexAuthService.claims(fromIDToken: auth.tokens.idToken),
              let email = claims.email else { return }
        let id: UUID
        if profiles.defaultAccountID == nil, let existing = accounts.first(where: { $0.email == email }) {
            guard !FileManager.default.fileExists(atPath: profiles.profile(for: existing.id).home.path) else {
                desyncNotice = "The default Codex login matches an existing isolated profile. Its profile has not been changed."
                return
            }
            id = existing.id
        } else {
            let account = Account(id: profiles.defaultAccountID ?? UUID(), email: email, displayName: claims.name ?? email, provider: .codex,
                                  subscriptionType: claims.planType, isActive: true)
            accounts.append(account)
            id = account.id
        }
        profiles.bindDefault(to: id)
        accounts = CodexAccountRegistry.markActive(id: id, in: accounts)
        CodexAccountRegistry.save(accounts, to: defaults)
    }

    private func refreshBackupPresence() {
        accountsWithBackups = Set(accounts.filter {
            FileManager.default.fileExists(atPath: profiles.profile(for: $0.id).authURL.path)
        }.map(\.id))
    }

    // MARK: - Desktop actions

    func importCurrentAccount() async {
        reconcileDefaultProfile()
        if profiles.defaultAccountID == nil {
            errorMessage = "Sign in to the default Codex app first, or use Login New Account."
            return
        }
        await refresh(force: true)
    }

    func loginNewAccount() async {
        guard !isLoading, !isAuthenticating else { return }
        reconcileDefaultProfile()
        let id = pendingLoginID.flatMap { pending in accounts.contains(where: { $0.id == pending }) ? nil : pending } ?? UUID()
        await openForLogin(id: id)
    }

    /// Opening a profile never replaces auth.json, even with a stored legacy backup.
    func switchTo(accountId: UUID) async {
        guard !isLoading, !isAuthenticating,
              let target = accounts.first(where: { $0.id == accountId }) else { return }
        reconcileDefaultProfile()
        let profile = profiles.profile(for: accountId)
        errorMessage = nil
        isLoading = true
        do {
            try profiles.prepare(profile)
            try await openDesktop(profile)
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            return
        }
        isLoading = false
        guard let auth = try? Self.loadAuth(from: profile) else {
            defaults.set(accountId.uuidString, forKey: Self.pendingLoginKey)
            defaults.set(false, forKey: Self.pendingLoginPausedKey)
            observePendingLogin()
            return
        }
        guard CodexAuthService.claims(fromIDToken: auth.tokens.idToken)?.email == target.email else {
            errorMessage = "This profile is signed in to a different account. Sign in to the expected account in its Codex window."
            return
        }
        selectAccount(accountId)
        await refresh(force: true)
    }

    func reauthenticate(id: UUID) async {
        guard !isLoading, !isAuthenticating, accounts.contains(where: { $0.id == id }) else { return }
        reconcileDefaultProfile()
        let profile = profiles.profile(for: id)
        guard (try? Self.loadAuth(from: profile)) != nil else {
            await openForLogin(id: id)
            return
        }
        isAuthenticating = true
        let generation = UUID()
        loginGeneration = generation
        defer { if loginGeneration == generation { isAuthenticating = false } }
        do {
            try profiles.prepare(profile)
            try await openDesktop(profile)
            guard loginGeneration == generation else { return }
            errorMessage = "To renew this account, sign out and sign in inside this Codex window. Other profiles are unchanged."
        } catch {
            guard loginGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func openForLogin(id: UUID) async {
        let profile = profiles.profile(for: id)
        errorMessage = nil
        isAuthenticating = true
        let generation = UUID()
        loginGeneration = generation
        do {
            try profiles.prepare(profile)
            defaults.set(id.uuidString, forKey: Self.pendingLoginKey)
            defaults.set(false, forKey: Self.pendingLoginPausedKey)
            try await openDesktop(profile)
            guard loginGeneration == generation else { return }
            observePendingLogin()
        } catch {
            guard loginGeneration == generation else { return }
            isAuthenticating = false
            defaults.set(true, forKey: Self.pendingLoginPausedKey)
            errorMessage = error.localizedDescription
        }
    }

    private func observePendingLogin() {
        guard let id = pendingLoginID, loginTask == nil else { return }
        isAuthenticating = true
        loginTask = Task { [weak self] in
            for _ in 0..<300 {
                guard !Task.isCancelled else { return }
                if let self, !self.isLoading, self.acceptLoginIfReady(id: id) {
                    self.isAuthenticating = false
                    self.loginTask = nil
                    await self.refresh(force: true)
                    return
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
            guard let self else { return }
            self.isAuthenticating = false
            self.loginTask = nil
            self.defaults.set(true, forKey: Self.pendingLoginPausedKey)
            self.errorMessage = "Login is still pending. Use Login New Account to resume, or Open Codex for an existing account."
        }
    }

    /// Identity comes from the selected live profile, never a Keychain snapshot.
    @discardableResult
    func acceptLoginIfReady(id: UUID) -> Bool {
        guard let auth = try? Self.loadAuth(from: profiles.profile(for: id)),
              let claims = CodexAuthService.claims(fromIDToken: auth.tokens.idToken),
              let email = claims.email else { return false }
        if let existing = accounts.first(where: { $0.id == id }) {
            guard existing.email == email else {
                errorMessage = "Login did not match the expected account. Switch accounts inside that Codex window."
                return false
            }
        } else {
            guard !Self.wouldDuplicate(email: email, in: accounts) else {
                errorMessage = "That account already exists. Sign in to the other account in the new Codex window."
                return false
            }
            accounts.append(Account(id: id, email: email, displayName: claims.name ?? email,
                                    provider: .codex, subscriptionType: claims.planType))
        }
        defaults.removeObject(forKey: Self.pendingLoginKey)
        defaults.removeObject(forKey: Self.pendingLoginPausedKey)
        selectAccount(id)
        refreshBackupPresence()
        return true
    }

    func cancelLogin() {
        loginGeneration = UUID()
        loginTask?.cancel()
        loginTask = nil
        isAuthenticating = false
        defaults.set(true, forKey: Self.pendingLoginPausedKey)
        // Retain the pending profile so a completed login is recoverable after relaunch.
    }

    private func selectAccount(_ id: UUID) {
        accounts = CodexAccountRegistry.markActive(id: id, in: accounts)
        if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index].lastUsed = Date() }
        CodexAccountRegistry.save(accounts, to: defaults)
        snapshot = accountSnapshots[id]
        snapshotIsStale = snapshot != nil
        email = nil
        name = nil
        planType = nil
        usageError = nil
        desyncNotice = nil
        rateLimitedUntil = nil
        costSeries = .empty
        activitySummary = .empty
    }

    func removeAccount(id: UUID) {
        guard !isAuthenticating, !isLoading else { return }
        accounts.removeAll { $0.id == id }
        accountSnapshots[id] = nil
        CodexAccountRegistry.save(accounts, to: defaults)
        refreshBackupPresence()
        // Profile directories and legacy Keychain entries are retained, not logged out or deleted.
    }

    func setLabel(_ label: String?, forAccount id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        accounts[index].customLabel = (trimmed?.isEmpty == true) ? nil : trimmed
        CodexAccountRegistry.save(accounts, to: defaults)
        log.info("[setLabel] \(accounts[index].email): \(trimmed ?? "nil")")
    }
}
