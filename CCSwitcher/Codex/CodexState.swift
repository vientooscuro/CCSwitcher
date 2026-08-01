import SwiftUI

private let log = FileLog("CodexState")

/// Codex provider state. Stage 2 was read-only; stage 3 adds real per-account
/// records, import, switching and the desync guard. `loginNewAccount()` and
/// `reauthenticate(id:)` are implemented but kept behind `capabilities` —
/// the user has exactly one ChatGPT account, and `codex login` would sign
/// them out with nothing to fall back to.
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
    private let sessionCache = CodexSessionCache.shared
    private let accountStore = CodexAccountStore.shared

    init() {
        accounts = CodexAccountRegistry.load()
        Task { await refreshBackupPresence() }
    }

    var providerType: AIProviderType { .codex }

    var isAvailable: Bool { CodexAuthService.isInstalled }

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            canSwitchAccounts: true,
            canImportCurrent: true,
            // Implemented below, but the user has exactly one ChatGPT account
            // right now: `codex login` would sign them out with no second
            // account to fall back to. Keep the affordance hidden until there
            // is a second account to switch to.
            canLoginNewAccount: false,
            canReauthenticate: false,
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
                hasStoredCredentials: accountsWithBackups.contains(account.id),
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
            await reconcileActiveAccount(with: loaded)
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
        CodexAccountRegistry.save(accounts)
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

    private func reconcileActiveAccount(with auth: CodexAuth) async {
        // First run, or an upgrade from a build that fabricated the account:
        // adopt whoever Codex is signed in as. Requiring an explicit "Add
        // current account" click here would show an empty popover to a user who
        // is plainly signed in, which is what the Claude side already avoids by
        // auto-creating its first account in `updateActiveAccount`.
        if accounts.isEmpty {
            await adoptCurrentAccount(auth: auth, reason: "no accounts stored yet")
            return
        }

        guard let activeId = accounts.first(where: \.isActive)?.id else {
            desyncNotice = nil
            return
        }

        var knownFingerprints: [UUID: String] = [:]
        for account in accounts {
            guard let text = await accountStore.backup(forAccountId: account.id.uuidString),
                  let backupAuth = try? CodexAuthService.decode(authJSON: Data(text.utf8)) else { continue }
            knownFingerprints[account.id] = CodexAuthService.fingerprint(for: backupAuth)
        }

        let liveFingerprint = CodexAuthService.fingerprint(for: auth)
        switch Self.desyncDecision(liveFingerprint: liveFingerprint, activeAccountId: activeId, knownFingerprints: knownFingerprints) {
        case .matches:
            desyncNotice = nil
        case .adopt(let id):
            accounts = CodexAccountRegistry.markActive(id: id, in: accounts)
            CodexAccountRegistry.save(accounts)
            desyncNotice = nil
            log.info("[reconcile] live auth.json now matches known account \(accounts.first { $0.id == id }?.email ?? "?"); switched active flag")
        case .unknown:
            desyncNotice = String(localized: "Codex is signed in as an account CCSwitcher does not know. Use Add current account to adopt it.", bundle: L10n.bundle)
            log.warning("[reconcile] live auth.json fingerprint matches no known account")
        }
    }

    private func refreshBackupPresence() async {
        let ids = await accountStore.backedUpAccountIds()
        accountsWithBackups = Set(ids.compactMap(UUID.init(uuidString:)))
    }

    // MARK: - Actions

    /// Adopt whichever account `~/.codex/auth.json` is currently signed in as.
    /// Create a record for whoever `auth.json` currently belongs to and make it
    /// active. Deliberately does NOT call `refresh` — it runs from inside one,
    /// and re-entering would recurse.
    @discardableResult
    private func adoptCurrentAccount(auth: CodexAuth, reason: String) async -> Bool {
        let claims = CodexAuthService.claims(fromIDToken: auth.tokens.idToken)
        guard let email = claims?.email else {
            log.warning("[adopt] no email in id_token claims, cannot adopt (\(reason))")
            return false
        }
        guard let authText = CodexAuthWriter.read(at: CodexAuthService.authPath) else {
            log.warning("[adopt] could not read auth.json text (\(reason))")
            return false
        }

        let account = Account(
            email: email,
            displayName: claims?.name ?? email,
            provider: .codex,
            subscriptionType: claims?.planType,
            isActive: true
        )
        accounts = accounts.map { var a = $0; a.isActive = false; return a }
        accounts.append(account)
        _ = await accountStore.saveBackup(authText, forAccountId: account.id.uuidString)
        CodexAccountRegistry.save(accounts)
        await refreshBackupPresence()
        desyncNotice = nil
        log.info("[adopt] adopted \(email) (\(reason)), total=\(accounts.count)")
        return true
    }

    func importCurrentAccount() async {
        guard isAvailable else {
            errorMessage = String(localized: "Codex is not signed in on this Mac.", bundle: L10n.bundle)
            return
        }

        do {
            let auth = try CodexAuthService.loadCurrent()
            let claims = CodexAuthService.claims(fromIDToken: auth.tokens.idToken)
            guard let email = claims?.email else {
                errorMessage = String(localized: "Could not determine the signed-in account's email.", bundle: L10n.bundle)
                log.error("[importCurrentAccount] Aborted: no email in id_token claims")
                return
            }
            guard !Self.wouldDuplicate(email: email, in: accounts) else {
                errorMessage = String(localized: "Account already exists", bundle: L10n.bundle)
                log.warning("[importCurrentAccount] Aborted: duplicate account for \(email)")
                return
            }
            guard let authText = CodexAuthWriter.read(at: CodexAuthService.authPath) else {
                errorMessage = String(localized: "Could not read Codex credentials.", bundle: L10n.bundle)
                log.error("[importCurrentAccount] Aborted: could not read auth.json text")
                return
            }

            let account = Account(
                email: email,
                displayName: claims?.name ?? email,
                provider: .codex,
                subscriptionType: claims?.planType,
                isActive: true
            )
            accounts = accounts.map { var a = $0; a.isActive = false; return a }
            accounts.append(account)
            _ = await accountStore.saveBackup(authText, forAccountId: account.id.uuidString)
            CodexAccountRegistry.save(accounts)
            await refreshBackupPresence()
            log.info("[importCurrentAccount] Imported \(email) as new active account, total=\(accounts.count)")

            await refresh(force: true)
        } catch {
            errorMessage = error.localizedDescription
            log.error("[importCurrentAccount] Error: \(error.localizedDescription)")
        }
    }

    /// Run `codex login`'s browser OAuth flow and add the result as a new
    /// account. Implemented, but gated off by `capabilities.canLoginNewAccount`
    /// until there is a second ChatGPT account to fall back to — this call
    /// must never be exercised while that gate is closed.
    func loginNewAccount() async {
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        if let active = accounts.first(where: \.isActive), let liveText = CodexAuthWriter.read(at: CodexAuthService.authPath) {
            _ = await accountStore.saveBackup(liveText, forAccountId: active.id.uuidString)
        }

        do {
            try await CodexCLIService.shared.login()
        } catch {
            errorMessage = error.localizedDescription
            log.error("[loginNewAccount] `codex login` failed: \(error.localizedDescription)")
            return
        }

        await importCurrentAccount()
        log.info("[loginNewAccount] Completed")
    }

    /// Backs up the live credential file to `target`, writes `target`'s stored
    /// backup over it, and marks `target` active. The only path in this class
    /// that writes `~/.codex/auth.json` — safe only because the bytes it
    /// writes are a backup the app itself captured.
    func switchTo(accountId: UUID) async {
        guard let targetIndex = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        let target = accounts[targetIndex]

        guard let targetBackupText = await accountStore.backup(forAccountId: target.id.uuidString) else {
            errorMessage = String(localized: "No stored credentials for \(target.email). Use re-authenticate to fix.", bundle: L10n.bundle)
            log.error("[switchTo] ABORT: no backup for \(target.email)")
            return
        }
        guard (try? CodexAuthService.decode(authJSON: Data(targetBackupText.utf8))) != nil else {
            errorMessage = String(localized: "Stored credentials for \(target.email) are corrupt. Re-authenticate to fix.", bundle: L10n.bundle)
            log.error("[switchTo] ABORT: backup for \(target.email) does not parse as CodexAuth")
            return
        }

        isLoading = true
        errorMessage = nil
        log.info("[switchTo] ===== Switching to \(target.email) =====")

        // Back up the live file to the account we currently believe is
        // active — but only if the live fingerprint still matches it (or no
        // backup exists yet). If it has drifted, the user switched accounts
        // inside Codex Desktop/CLI, and overwriting that account's backup
        // with the wrong session would poison it for next time.
        if let active = accounts.first(where: \.isActive) {
            if let liveText = CodexAuthWriter.read(at: CodexAuthService.authPath),
               let liveAuth = try? CodexAuthService.decode(authJSON: Data(liveText.utf8)) {
                let liveFingerprint = CodexAuthService.fingerprint(for: liveAuth)
                let backupFingerprint = await accountStore.backup(forAccountId: active.id.uuidString)
                    .flatMap { try? CodexAuthService.decode(authJSON: Data($0.utf8)) }
                    .map(CodexAuthService.fingerprint(for:))
                if backupFingerprint == nil || liveFingerprint == backupFingerprint {
                    _ = await accountStore.saveBackup(liveText, forAccountId: active.id.uuidString)
                } else {
                    log.warning("[switchTo] live auth.json no longer matches \(active.email); skipping backup overwrite")
                }
            }
        }

        guard CodexAuthWriter.write(targetBackupText, to: CodexAuthService.authPath) else {
            errorMessage = String(localized: "Could not write Codex credentials.", bundle: L10n.bundle)
            isLoading = false
            log.error("[switchTo] write failed for \(target.email)")
            return
        }

        accounts = CodexAccountRegistry.markActive(id: target.id, in: accounts)
        if let updatedIndex = accounts.firstIndex(where: { $0.id == target.id }) {
            accounts[updatedIndex].lastUsed = Date()
        }
        CodexAccountRegistry.save(accounts)
        usageError = nil
        desyncNotice = nil
        log.info("[switchTo] ===== Switch completed =====")

        isLoading = false
        await refresh(force: true)
    }

    /// Drops the registry row and the store entry. If this was the active
    /// account, the live `auth.json` is left untouched — only the bookkeeping
    /// flag is cleared. Deleting a user's live credentials because they
    /// removed a row would be indefensible.
    func removeAccount(id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        log.info("[removeAccount] Removing \(account.email) (active=\(account.isActive))")
        accounts.removeAll { $0.id == id }
        accountSnapshots[id] = nil
        CodexAccountRegistry.save(accounts)
        Task {
            await accountStore.removeBackup(forAccountId: id.uuidString)
            await refreshBackupPresence()
        }
        log.info("[removeAccount] Done. Remaining accounts: \(accounts.count)")
    }

    /// Runs `codex login` and, only if the resulting session matches
    /// `target`'s email, refreshes its stored backup. Implemented, but gated
    /// off by `capabilities.canReauthenticate` for the same reason as
    /// `loginNewAccount()` — must never be exercised while that gate is closed.
    func reauthenticate(id: UUID) async {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let target = accounts[index]

        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        if let active = accounts.first(where: \.isActive), active.id != target.id,
           let liveText = CodexAuthWriter.read(at: CodexAuthService.authPath) {
            _ = await accountStore.saveBackup(liveText, forAccountId: active.id.uuidString)
        }

        do {
            try await CodexCLIService.shared.login()
        } catch {
            errorMessage = error.localizedDescription
            log.error("[reauthenticate] `codex login` failed: \(error.localizedDescription)")
            return
        }

        guard let auth = try? CodexAuthService.loadCurrent(),
              let email = CodexAuthService.claims(fromIDToken: auth.tokens.idToken)?.email,
              email == target.email else {
            errorMessage = String(localized: "Login did not match the expected account.", bundle: L10n.bundle)
            log.error("[reauthenticate] post-login email did not match \(target.email)")
            return
        }

        guard let liveText = CodexAuthWriter.read(at: CodexAuthService.authPath) else { return }
        _ = await accountStore.saveBackup(liveText, forAccountId: target.id.uuidString)
        accounts = CodexAccountRegistry.markActive(id: target.id, in: accounts)
        CodexAccountRegistry.save(accounts)
        await refreshBackupPresence()
        log.info("[reauthenticate] Refreshed backup for \(target.email)")

        await refresh(force: true)
    }

    func setLabel(_ label: String?, forAccount id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        accounts[index].customLabel = (trimmed?.isEmpty == true) ? nil : trimmed
        CodexAccountRegistry.save(accounts)
        log.info("[setLabel] \(accounts[index].email): \(trimmed ?? "nil")")
    }
}
