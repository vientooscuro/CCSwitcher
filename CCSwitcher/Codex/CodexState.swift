import SwiftUI

private let log = FileLog("CodexState")

enum CodexStatisticsScope: String {
    case allProfiles
    case currentAccount
}

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

    @Published private var costSeries: CostSeriesModel = .empty
    @Published private var activitySummary: ActivitySummaryModel = .empty
    @Published var statisticsScope: CodexStatisticsScope {
        didSet {
            guard oldValue != statisticsScope else { return }
            defaults.set(statisticsScope.rawValue, forKey: "codexStatisticsScope")
            invalidateStatistics()
        }
    }
    @Published private(set) var isStatisticsLoading = false
    private var statisticsGeneration = UUID()
    /// Set when the live `auth.json` fingerprint matches no known account —
    /// surfaced on the active account's card until the user imports it.
    @Published private var desyncNotice: String?

    /// Set by `ProviderHub` at init. Called once a refresh finishes.
    var didRefresh: (() -> Void)?

    private struct AccountUsage {
        var snapshot: CodexRateLimitSnapshot?
        var isStale = false
        var error: ProviderErrorModel?
        var rateLimitedUntil: Date?
    }
    @Published private var accountUsage: [UUID: AccountUsage] = [:]

    private let fetchUsage: @MainActor (CodexAuth, UUID) async throws -> CodexUsageService.Result
    private let cachedUsage: @MainActor (UUID) async -> CodexUsageService.Result?
    private var profileSessionCaches: [String: CodexSessionCache] = [:]
    private let defaults: UserDefaults
    let profiles: CodexDesktopProfiles
    private let openDesktop: (CodexDesktopProfile) async throws -> Void
    private let loadCLIBackup: @MainActor (String) async -> String?
    private let saveCLIBackup: @MainActor (String, String) async -> Bool
    private var loginTask: Task<Void, Never>?
    private var loginGeneration = UUID()
    private static let pendingLoginKey = "codexDesktopPendingLoginID"
    private static let pendingLoginPausedKey = "codexDesktopPendingLoginPaused"

    init(
        defaults: UserDefaults = .standard,
        profiles: CodexDesktopProfiles? = nil,
        openDesktop: @escaping (CodexDesktopProfile) async throws -> Void = CodexDesktopProfiles.open,
        loadCLIBackup: @escaping @MainActor (String) async -> String? = { accountID in
            CodexAccountStore.shared.backup(forAccountId: accountID)
        },
        saveCLIBackup: @escaping @MainActor (String, String) async -> Bool = { contents, accountID in
            CodexAccountStore.shared.saveBackup(contents, forAccountId: accountID)
        },
        fetchUsage: @escaping @MainActor (CodexAuth, UUID) async throws -> CodexUsageService.Result = { auth, id in
            try await CodexUsageService.shared.fetchLive(
                accessToken: auth.tokens.accessToken, accountId: auth.tokens.accountId, profileID: id
            )
        },
        cachedUsage: @escaping @MainActor (UUID) async -> CodexUsageService.Result? = { id in
            CodexUsageService.shared.localFallback(profileID: id)
        }
    ) {
        self.defaults = defaults
        self.profiles = profiles ?? CodexDesktopProfiles(defaults: defaults)
        self.openDesktop = openDesktop
        self.loadCLIBackup = loadCLIBackup
        self.saveCLIBackup = saveCLIBackup
        self.fetchUsage = fetchUsage
        self.cachedUsage = cachedUsage
        statisticsScope = defaults.string(forKey: "codexStatisticsScope").flatMap(CodexStatisticsScope.init(rawValue:)) ?? .allProfiles
        accounts = CodexAccountRegistry.load(from: defaults)
        hydrateFromWidgetCache()
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
            let usage = accountUsage[account.id]
            let effectiveSnapshot = usage?.snapshot
            let notice = (account.isActive ? desyncNotice : nil)
                ?? effectiveSnapshot.flatMap { CodexDisplayMapper.notice(from: $0, isStale: usage?.isStale == true) }
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
                error: usage?.error
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
                error: card?.error
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

        for account in accounts {
            await refreshLimits(for: account, force: force)
        }
        isLoading = false
        if force {
            await refreshCostAndActivity(notify: false)
        }

        lastRefresh = Date()
        didRefresh?()
    }

    private func refreshLimits(for account: Account, force: Bool) async {
        let id = account.id
        var usage = accountUsage[id] ?? AccountUsage()
        defer {
            if accounts.contains(where: { $0.id == id }) { accountUsage[id] = usage }
        }
        let auth: CodexAuth
        do {
            auth = try Self.loadAuth(from: profiles.profile(for: id))
        } catch {
            usage.error = ProviderErrorModel(message: error.localizedDescription, needsReauth: true, isRateLimited: false)
            usage.isStale = true
            if usage.snapshot == nil { usage.snapshot = await cachedUsage(id)?.snapshot }
            if account.isActive { errorMessage = error.localizedDescription }
            return
        }
        let claims = CodexAuthService.claims(fromIDToken: auth.tokens.idToken)
        guard claims?.email == account.email else {
            usage = AccountUsage(error: ProviderErrorModel(
                message: "This Codex profile is signed in to a different account. Open it and sign in as \(account.email).",
                needsReauth: true, isRateLimited: false
            ))
            return
        }
        syncAccountFields(id: id, claims: claims, plan: usage.snapshot?.planType)
        if !force, let until = usage.rateLimitedUntil, until > Date() { return }

        do {
            let result = try await fetchUsage(auth, id)
            usage = AccountUsage(snapshot: result.snapshot, isStale: result.isStale)
            syncAccountFields(id: id, claims: claims, plan: result.snapshot.planType)
            return
        } catch CodexUsageService.UsageError.rateLimited(let retryAfter) {
            usage.rateLimitedUntil = Date().addingTimeInterval(retryAfter)
            usage.error = ProviderErrorModel(
                message: CodexUsageService.UsageError.rateLimited(retryAfter: retryAfter).localizedDescription,
                needsReauth: false,
                isRateLimited: true
            )
        } catch CodexUsageService.UsageError.needsReauth {
            usage.error = ProviderErrorModel(
                message: CodexUsageService.UsageError.needsReauth.localizedDescription,
                needsReauth: true,
                isRateLimited: false
            )
        } catch {
            usage.error = ProviderErrorModel(message: error.localizedDescription, needsReauth: false, isRateLimited: false)
        }
        usage.isStale = true
        if usage.snapshot == nil { usage.snapshot = await cachedUsage(id)?.snapshot }
        syncAccountFields(id: id, claims: claims, plan: usage.snapshot?.planType)
    }

    private func invalidateStatistics() {
        statisticsGeneration = UUID()
        costSeries = .empty
        activitySummary = .empty
        isStatisticsLoading = false
    }

    func refreshCostAndActivity(notify: Bool = true) async {
        guard let generation = beginStatisticsRefreshIfIdle() else { return }
        defer {
            finishStatisticsRefresh(generation: generation)
        }
        let profile = selectedProfile
        let scope = statisticsScope
        let homes = scope == .allProfiles ? profiles.statisticsHomes : [profile.home]
        let roots = homes.flatMap { home in
            [home.appendingPathComponent("sessions").path, home.appendingPathComponent("archived_sessions").path]
        }.sorted()
        let key = roots.joined(separator: "\n")
        let sessionCache: CodexSessionCache
        if let cached = profileSessionCaches[key] {
            sessionCache = cached
        } else {
            let cacheURL = scope == .allProfiles
                ? profiles.defaultProfile.home.appendingPathComponent("ccswitcher-all-session-cache.json")
                : profile.home.appendingPathComponent("ccswitcher-session-cache.json")
            sessionCache = CodexSessionCache(
                sessionRoots: roots, cacheURL: cacheURL
            )
            profileSessionCaches[key] = sessionCache
        }
        await PricingService.shared.reloadIfFreshChanged()
        PricingService.shared.refreshInBackground()
        await sessionCache.refreshFromFilesystem()
        let cost = await sessionCache.costSeries()
        let activity = await sessionCache.activityToday()
        await sessionCache.releaseResidentData()
        guard statisticsGeneration == generation, statisticsScope == scope, selectedProfile == profile else { return }
        costSeries = cost
        activitySummary = activity
        if notify { didRefresh?() }
        log.info("[refresh] today=$\(String(format: "%.2f", costSeries.todayCost)) turns=\(activitySummary.turns)")
    }

    func beginStatisticsRefreshIfIdle() -> UUID? {
        guard !isStatisticsLoading else { return nil }
        let generation = UUID()
        statisticsGeneration = generation
        isStatisticsLoading = true
        return generation
    }

    func finishStatisticsRefresh(generation: UUID) {
        guard statisticsGeneration == generation else { return }
        isStatisticsLoading = false
    }

    private func hydrateFromWidgetCache() {
        guard let cached = WidgetData.load(), cached.provider == AIProviderType.codex.rawValue else { return }
        costSeries = CostSeriesModel(todayCost: cached.todayCost, daily: [])
        activitySummary = ActivitySummaryModel(
            turns: cached.conversationTurns,
            activeTimeText: cached.activeCodingTime,
            linesWritten: cached.linesWritten,
            perModel: cached.modelUsage.map { name, count in
                ModelUsageEntry(displayName: name, count: count, tint: CodexDisplayMapper.tint(forModel: name))
            }.sorted { $0.count > $1.count }
        )
        lastRefresh = cached.lastUpdated
    }

    private func syncAccountFields(id: UUID, claims: CodexIDTokenClaims?, plan: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let displayName = claims?.name ?? accounts[index].displayName
        // Cached/live plans take precedence over potentially outdated ID-token claims.
        let planType = plan ?? accounts[index].subscriptionType ?? claims?.planType
        guard accounts[index].displayName != displayName
            || accounts[index].subscriptionType != planType else { return }
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
            errorMessage = "This profile is signed in to a different account. Sign in as \(target.email) in its Codex window."
            return
        }
        selectAccount(accountId)
        await refresh(force: true)
    }

    func activateCLI(accountId: UUID) async {
        guard !isLoading, !isAuthenticating,
              let target = accounts.first(where: { $0.id == accountId }) else { return }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        let targetProfile = profiles.profile(for: accountId)
        let profileCredentials = CodexAuthWriter.read(at: targetProfile.authURL.path)
        let targetCredentials: String?
        if let profileCredentials, Self.credentials(profileCredentials, belongTo: target.email) {
            targetCredentials = profileCredentials
        } else {
            targetCredentials = await loadCLIBackup(accountId.uuidString)
        }

        guard let targetCredentials,
              Self.credentials(targetCredentials, belongTo: target.email) else {
            errorMessage = "No valid Codex CLI credentials for \(target.email). Sign in to this account again."
            return
        }

        let destination = profiles.defaultProfile.authURL.path
        if let liveCredentials = CodexAuthWriter.read(at: destination) {
            guard let liveAccount = accounts.first(where: {
                Self.credentials(liveCredentials, belongTo: $0.email)
            }) else {
                errorMessage = "The current Codex CLI credentials do not match a saved account. They were left unchanged."
                return
            }
            guard await saveCLIBackup(liveCredentials, liveAccount.id.uuidString) else {
                errorMessage = "Could not preserve the current Codex CLI credentials."
                return
            }
        }

        guard CodexAuthWriter.write(targetCredentials, to: destination) else {
            errorMessage = "Could not write Codex CLI credentials."
            return
        }

        selectAccount(accountId)
        refreshBackupPresence()
        didRefresh?()
    }

    private static func credentials(_ contents: String, belongTo email: String) -> Bool {
        guard let auth = try? CodexAuthService.decode(authJSON: Data(contents.utf8)),
              let credentialEmail = CodexAuthService.claims(fromIDToken: auth.tokens.idToken)?.email else {
            return false
        }
        return credentialEmail.caseInsensitiveCompare(email) == .orderedSame
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
                errorMessage = "Login did not match \(existing.email). Switch accounts inside that Codex window."
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
        desyncNotice = nil
        invalidateStatistics()
    }

    func removeAccount(id: UUID) {
        guard !isAuthenticating, !isLoading else { return }
        accounts.removeAll { $0.id == id }
        accountUsage[id] = nil
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
