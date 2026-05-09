import SwiftUI
import Combine
import WidgetKit

private let log = FileLog("AppState")

/// Central app state managing accounts, usage data, and active sessions.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var activeAccount: Account?
    @Published var accountUsage: [UUID: UsageAPIResponse] = [:]
    @Published var activeSessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var isLoggingIn = false
    @Published var errorMessage: String?
    @Published var claudeAvailable = false
    @Published var lastUsageRefresh: Date?
    @Published var costSummary: CostSummary = .empty
    @Published var activityStats: ActivityStats = .empty

    struct UsageErrorState {
        let isExpired: Bool
        let isRateLimited: Bool
        let message: String
    }

    @Published var accountUsageErrors: [UUID: UsageErrorState] = [:]

    // MARK: - Services

    private let claudeService = ClaudeService.shared
    private let statsParser = StatsParser.shared
    private let costParser = CostParser.shared
    private let activityParser = ActivityParser.shared
    private let keychain = KeychainService.shared

    private let accountsKey = "com.ccswitcher.accounts"
    private var refreshTimer: Timer?

    /// Debounce token for `saveAccounts` — small mutations like `lastUsed`
    /// shouldn't trigger a synchronous JSONEncoder + UserDefaults write.
    private var pendingSaveTask: Task<Void, Never>?

    /// Hash of the last widget snapshot we wrote — used to skip
    /// `WidgetCenter.reloadAllTimelines` when nothing meaningful changed.
    private var lastWidgetSnapshotHash: Int?

    /// True when the popover is visible. While false, the auto-refresh timer
    /// pauses so we don't spend CPU/network when the user can't see the UI.
    private var menuVisible: Bool = false

    private var refreshIntervalSeconds: TimeInterval = 300

    // MARK: - Initialization

    init() {
        log.info("[init] Loading accounts from UserDefaults...")
        loadAccounts()
        log.info("[init] Loaded \(self.accounts.count) accounts, active: \(self.activeAccount?.id.uuidString ?? "none")")

        // Hydrate from last-known widget snapshot so the UI has something to
        // show before the first refresh completes.
        hydrateFromWidgetCache()

        // Run the (non-essential) keychain health diagnostic once at startup,
        // off the main thread. Used to run on every refresh — totally
        // unnecessary every 5 minutes.
        Task.detached(priority: .background) { [weak self] in
            await self?.diagnoseTokenHealth()
        }
    }

    // MARK: - Refresh

    /// Refresh all derived state.
    /// - Parameter knownStatus: pass a freshly-obtained `AuthStatus` to skip
    ///   re-running `claude auth status` (an expensive CLI fork). Used by
    ///   `switchTo` and `loginNewAccount` to avoid double-querying.
    func refresh(knownStatus: AuthStatus? = nil) async {
        guard !isLoggingIn else {
            log.info("[refresh] Skipping: login in progress")
            return
        }
        isLoading = true
        errorMessage = nil

        if let knownStatus {
            claudeAvailable = true
            await updateActiveAccount(from: knownStatus)
        } else {
            claudeAvailable = await claudeService.isClaudeAvailable()
            log.info("[refresh] Claude available: \(self.claudeAvailable)")

            if claudeAvailable {
                do {
                    let status = try await claudeService.getAuthStatus()
                    await updateActiveAccount(from: status)
                } catch {
                    log.error("[refresh] getAuthStatus failed: \(error.localizedDescription)")
                    errorMessage = error.localizedDescription
                }
            }
        }

        await fetchAllAccountUsage()
        lastUsageRefresh = Date()

        // Heavy JSONL parsing + session scan — all off main, then publish results.
        async let sessions = statsParser.getActiveSessions()
        async let cost = costParser.getCostSummary()
        async let activity = activityParser.getTodayStats()
        let (sessionsResult, costResult, activityResult) = await (sessions, cost, activity)
        activeSessions = sessionsResult
        costSummary = costResult
        activityStats = activityResult

        log.debug("[refresh] \(self.activeSessions.count) sessions, today=$\(String(format: "%.2f", costResult.todayCost)) turns=\(activityResult.conversationTurns)")

        updateWidgetData()
        isLoading = false
    }

    func startAutoRefresh(interval: TimeInterval = 300) {
        refreshIntervalSeconds = interval
        // Only actually run the timer when the menu is visible. The visibility
        // hooks (`menuDidAppear`/`menuDidDisappear`) drive scheduling.
        if menuVisible {
            scheduleRefreshTimer()
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Called when the menu bar popover is opened. Triggers an immediate
    /// refresh and (re)starts the periodic timer.
    func menuDidAppear() {
        menuVisible = true
        scheduleRefreshTimer()
    }

    /// Called when the popover is dismissed. Pauses the periodic refresh —
    /// no point spending CPU/network polling state nobody can see.
    func menuDidDisappear() {
        menuVisible = false
        stopAutoRefresh()
    }

    private func scheduleRefreshTimer() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    private func hydrateFromWidgetCache() {
        guard let cached = WidgetData.load() else { return }
        log.info("[init] Hydrating from widget cache: today=$\(String(format: "%.2f", cached.todayCost)), turns=\(cached.conversationTurns)")
        // Only fields that map cleanly; the rest will fill in on first refresh.
        costSummary = CostSummary(todayCost: cached.todayCost, dailyCosts: [])
        activityStats = ActivityStats(
            conversationTurns: cached.conversationTurns,
            activeCodingMinutes: 0,
            toolUsage: [:],
            linesWritten: cached.linesWritten,
            modelUsage: cached.modelUsage
        )
        lastUsageRefresh = cached.lastUpdated
    }

    // MARK: - Account Management

    func addAccount() async {
        log.info("[addAccount] Starting add current account flow...")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[addAccount] Aborted: Claude CLI not found")
            return
        }

        do {
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Not logged in to Claude. Run 'claude auth login' first.", bundle: L10n.bundle)
                log.error("[addAccount] Aborted: not logged in")
                return
            }
            log.info("[addAccount] Current auth: logged in, sub=\(status.subscriptionType ?? "nil")")

            if accounts.contains(where: { $0.email == email }) {
                errorMessage = String(localized: "Account already exists", bundle: L10n.bundle)
                log.warning("[addAccount] Aborted: duplicate account")
                return
            }

            var account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: accounts.isEmpty
            )
            log.info("[addAccount] Created account model, id=\(account.id)")

            log.info("[addAccount] Capturing token from keychain...")
            let captured = await claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            if !captured {
                errorMessage = String(localized: "Could not capture auth token from keychain", bundle: L10n.bundle)
                log.error("[addAccount] Token capture failed!")
                return
            }
            log.info("[addAccount] Token captured successfully")

            if accounts.isEmpty {
                account.isActive = true
                activeAccount = account
                log.info("[addAccount] First account, setting as active")
            }

            accounts.append(account)
            scheduleSave()
            log.info("[addAccount] Account saved. Total accounts: \(self.accounts.count)")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[addAccount] Error: \(error.localizedDescription)")
        }
    }

    func loginNewAccount() async {
        log.info("[loginNewAccount] ===== Starting login new account flow =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[loginNewAccount] Aborted: Claude CLI not found")
            return
        }

        isLoggingIn = true
        errorMessage = nil

        do {
            if let current = activeAccount {
                log.info("[loginNewAccount] Step 1: Backing up current account (\(current.email))...")
                let backed = await claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString)
                log.info("[loginNewAccount] Step 1: Backup result: \(backed)")
            } else {
                log.info("[loginNewAccount] Step 1: No active account, skipping backup")
            }

            log.info("[loginNewAccount] Step 2: Running `claude auth login`...")
            try await claudeService.login()
            log.info("[loginNewAccount] Step 2: Login process completed")

            log.info("[loginNewAccount] Step 3: Reading post-login state...")
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 3: Not logged in after login!")
                isLoggingIn = false
                return
            }
            log.info("[loginNewAccount] Step 3: Logged in as \(email)")

            if let existing = accounts.firstIndex(where: { $0.email == email }) {
                log.info("[loginNewAccount] Step 4: Account already exists, refreshing backup")
                _ = await claudeService.captureCurrentCredentials(forAccountId: accounts[existing].id.uuidString)
                errorMessage = String(localized: "Account already exists - credentials refreshed", bundle: L10n.bundle)
                isLoggingIn = false
                return
            }

            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            log.info("[loginNewAccount] Step 5: Created account, id=\(account.id)")

            let captured = await claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            if !captured {
                errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 5: Capture failed!")
                isLoggingIn = false
                return
            }

            for i in accounts.indices {
                accounts[i].isActive = false
            }
            accounts.append(account)
            activeAccount = account
            scheduleSave()
            log.info("[loginNewAccount] Step 6: New account active. Total: \(self.accounts.count)")

            isLoggingIn = false
            // Pass the freshly-known status so refresh skips a second
            // `claude auth status` fork.
            await refresh(knownStatus: status)
            log.info("[loginNewAccount] ===== Login completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoggingIn = false
            log.error("[loginNewAccount] Error: \(error.localizedDescription)")
        }
    }

    func updateAccountLabel(_ account: Account, label: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        accounts[index].customLabel = (trimmed?.isEmpty == true) ? nil : trimmed
        if accounts[index].isActive {
            activeAccount = accounts[index]
        }
        scheduleSave()
        updateWidgetData()
        log.info("[updateAccountLabel] Set label for \(account.email): \(trimmed ?? "nil")")
    }

    func removeAccount(_ account: Account) {
        log.info("[removeAccount] Removing account \(account.id)")
        Task { await keychain.removeAccountBackup(forAccountId: account.id.uuidString) }
        accounts.removeAll { $0.id == account.id }
        if account.isActive, let first = accounts.first {
            accounts[accounts.startIndex].isActive = true
            activeAccount = accounts.first
            log.info("[removeAccount] Removed active account, switching to first remaining")
            Task { await switchTo(first) }
        }
        scheduleSave()
        log.info("[removeAccount] Done. Remaining accounts: \(self.accounts.count)")
    }

    func switchTo(_ account: Account) async {
        guard let currentActive = activeAccount, currentActive.id != account.id else {
            log.info("[switchTo] No switch needed (same account or no active account)")
            return
        }

        log.info("[switchTo] ===== Switching from \(currentActive.email) to \(account.email) =====")

        guard await keychain.getAccountBackup(forAccountId: account.id.uuidString) != nil else {
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = String(localized: "No stored credentials for \(account.email). Use re-authenticate to fix.", bundle: L10n.bundle)
            return
        }

        isLoading = true
        do {
            // switchAccount returns the verified status — pass it to refresh
            // so we don't fork `claude auth status` a second time.
            let status = try await claudeService.switchAccount(from: currentActive, to: account)

            for i in accounts.indices {
                accounts[i].isActive = (accounts[i].id == account.id)
                if accounts[i].id == account.id {
                    accounts[i].lastUsed = Date()
                }
            }
            activeAccount = account
            scheduleSave()

            await refresh(knownStatus: status)
            log.info("[switchTo] ===== Switch completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            log.error("[switchTo] Switch failed: \(error.localizedDescription)")
        }
    }

    /// Re-authenticate an account by running `claude auth login` and capturing fresh credentials.
    func reauthenticateAccount(_ account: Account) async {
        log.info("[reauth] ===== Re-authenticating account \(account.id) (\(account.email)) =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            return
        }

        isLoggingIn = true
        errorMessage = nil

        do {
            if let current = activeAccount, current.id != account.id {
                log.info("[reauth] Backing up current account before login...")
                _ = await claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString)
            }

            log.info("[reauth] Running `claude auth login`...")
            try await claudeService.login()

            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                isLoggingIn = false
                return
            }

            guard email == account.email else {
                errorMessage = String(localized: "Logged in as \(email), but expected \(account.email). Credentials not updated.", bundle: L10n.bundle)
                log.error("[reauth] Email mismatch: got \(email), expected \(account.email)")
                isLoggingIn = false
                return
            }

            let captured = await claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            log.info("[reauth] Token capture result: \(captured)")

            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].orgName = status.orgName
                accounts[index].subscriptionType = status.subscriptionType

                for i in accounts.indices {
                    accounts[i].isActive = (i == index)
                }
                activeAccount = accounts[index]
                scheduleSave()
            }

            isLoggingIn = false
            await refresh(knownStatus: status)
            log.info("[reauth] ===== Re-authentication completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoggingIn = false
            log.error("[reauth] Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Usage

    private func fetchAllAccountUsage() async {
        accountUsageErrors.removeAll()

        // Collect tokens up front (sequentially — keychain is a serial actor).
        var requests: [(account: Account, accessToken: String)] = []
        for account in accounts {
            let tokenJSON: String?
            if account.isActive {
                tokenJSON = await keychain.readClaudeToken()
            } else {
                tokenJSON = await keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
            }
            guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
                log.warning("[fetchUsage] No token for \(account.email), skipping")
                continue
            }
            requests.append((account, accessToken))
        }

        // Fire all HTTP requests in parallel.
        struct Result {
            let accountId: UUID
            let isActive: Bool
            let email: String
            let payload: Swift.Result<UsageAPIResponse, Error>
        }

        let results: [Result] = await withTaskGroup(of: Result.self) { group in
            for req in requests {
                group.addTask { [claudeService] in
                    do {
                        let usage = try await claudeService.getUsageLimits(accessToken: req.accessToken)
                        return Result(accountId: req.account.id, isActive: req.account.isActive, email: req.account.email, payload: .success(usage))
                    } catch {
                        return Result(accountId: req.account.id, isActive: req.account.isActive, email: req.account.email, payload: .failure(error))
                    }
                }
            }
            var collected: [Result] = []
            for await r in group { collected.append(r) }
            return collected
        }

        for r in results {
            switch r.payload {
            case .success(let usage):
                accountUsage[r.accountId] = usage
                accountUsageErrors[r.accountId] = nil
                log.info("[fetchUsage] \(r.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")

            case .failure(let error):
                if let usageError = error as? ClaudeService.UsageError {
                    switch usageError {
                    case .expired:
                        log.warning("[fetchUsage] Token expired for \(r.email)")
                        if r.isActive {
                            // Active account: try a delegated refresh via `claude auth status`,
                            // then retry the usage call once.
                            do {
                                _ = try await claudeService.getAuthStatus()
                                if let refreshedJSON = await keychain.readClaudeToken(),
                                   let refreshedToken = ClaudeService.extractAccessToken(from: refreshedJSON),
                                   let usage = try? await claudeService.getUsageLimits(accessToken: refreshedToken) {
                                    accountUsage[r.accountId] = usage
                                    accountUsageErrors[r.accountId] = nil
                                    log.info("[fetchUsage] Recovered \(r.email) via delegated refresh.")
                                    continue
                                }
                            } catch {
                                log.error("[fetchUsage] Delegated refresh failed: \(error.localizedDescription)")
                            }
                            accountUsage[r.accountId] = nil
                            accountUsageErrors[r.accountId] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Token expired. Switch to refresh.", bundle: L10n.bundle))
                        } else {
                            accountUsage[r.accountId] = nil
                            accountUsageErrors[r.accountId] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Token expired. Switch to this account to refresh.", bundle: L10n.bundle))
                        }

                    case .network(let msg) where msg.contains("429"):
                        accountUsage[r.accountId] = nil
                        accountUsageErrors[r.accountId] = UsageErrorState(isExpired: false, isRateLimited: true, message: String(localized: "API Rate Limited. Try again later.", bundle: L10n.bundle))

                    default:
                        accountUsage[r.accountId] = nil
                        accountUsageErrors[r.accountId] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "Could not fetch usage: \(error.localizedDescription)", bundle: L10n.bundle))
                    }
                } else {
                    accountUsage[r.accountId] = nil
                    accountUsageErrors[r.accountId] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "Could not fetch usage: \(error.localizedDescription)", bundle: L10n.bundle))
                }
            }
        }
    }

    // MARK: - Diagnostics

    /// Passive health check — runs once at startup and after login/switch.
    private func diagnoseTokenHealth() async {
        guard !accounts.isEmpty else { return }

        log.info("[diagnose] === Health Check ===")
        log.info("[diagnose] Accounts: \(self.accounts.count), active: \(self.activeAccount?.email ?? "none")")

        if let liveOAuth = await keychain.readOAuthAccount() {
            let liveEmail = (liveOAuth["emailAddress"]?.value as? String) ?? "?"
            log.info("[diagnose] Live oauthAccount: \(liveEmail)")
        } else {
            log.warning("[diagnose] Live oauthAccount: MISSING")
        }

        for account in accounts {
            if let backup = await keychain.getAccountBackup(forAccountId: account.id.uuidString) {
                let backupEmail = (backup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
                log.info("[diagnose] Backup [\(account.email)]: OK (email=\(backupEmail))")
            } else {
                log.warning("[diagnose] Backup [\(account.email)]: MISSING — switch will fail")
            }
        }

        log.info("[diagnose] === End Health Check ===")
    }

    // MARK: - Widget

    private func updateWidgetData() {
        let showFullEmail = UserDefaults.standard.bool(forKey: "showFullEmail")
        let widgetAccounts = accounts.map { account in
            let usage = accountUsage[account.id]
            let error = accountUsageErrors[account.id]
            return WidgetAccountData(
                email: account.displayEmail(obfuscated: !showFullEmail),
                displayName: account.effectiveDisplayName(obfuscated: !showFullEmail),
                subscriptionType: account.displaySubscriptionType,
                isActive: account.isActive,
                sessionUtilization: usage?.fiveHour?.utilization,
                sessionResetTime: usage?.fiveHour?.resetTimeString,
                weeklyUtilization: usage?.sevenDay?.utilization,
                weeklyResetTime: usage?.sevenDay?.resetTimeString,
                extraUsageEnabled: usage?.extraUsage?.isEnabled,
                hasError: error != nil,
                errorMessage: error?.message
            )
        }

        // Hash the meaningful fields. `lastUpdated` is excluded so the
        // timestamp alone never triggers a needless widget reload.
        var hasher = Hasher()
        hasher.combine(costSummary.todayCost)
        hasher.combine(activityStats.conversationTurns)
        hasher.combine(activityStats.activeCodingTimeString)
        hasher.combine(activityStats.linesWritten)
        for (k, v) in activityStats.modelUsage.sorted(by: { $0.key < $1.key }) {
            hasher.combine(k); hasher.combine(v)
        }
        for w in widgetAccounts {
            hasher.combine(w.email)
            hasher.combine(w.displayName)
            hasher.combine(w.subscriptionType ?? "")
            hasher.combine(w.isActive)
            hasher.combine(w.sessionUtilization ?? -1)
            hasher.combine(w.sessionResetTime ?? "")
            hasher.combine(w.weeklyUtilization ?? -1)
            hasher.combine(w.weeklyResetTime ?? "")
            hasher.combine(w.extraUsageEnabled ?? false)
            hasher.combine(w.hasError)
            hasher.combine(w.errorMessage ?? "")
        }
        let hash = hasher.finalize()

        let data = WidgetData(
            accounts: widgetAccounts,
            todayCost: costSummary.todayCost,
            conversationTurns: activityStats.conversationTurns,
            activeCodingTime: activityStats.activeCodingTimeString,
            linesWritten: activityStats.linesWritten,
            modelUsage: activityStats.modelUsage,
            lastUpdated: Date()
        )
        data.save()

        if hash != lastWidgetSnapshotHash {
            lastWidgetSnapshotHash = hash
            WidgetCenter.shared.reloadAllTimelines()
            log.debug("[updateWidgetData] Widget reloaded (data changed)")
        } else {
            log.debug("[updateWidgetData] Widget data unchanged, skipping reload")
        }
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            log.info("[loadAccounts] No saved accounts found")
            return
        }
        accounts = decoded
        activeAccount = accounts.first(where: \.isActive)
        log.info("[loadAccounts] Loaded \(decoded.count) accounts")
    }

    /// Coalesce rapid mutations (e.g. `lastUsed = Date()` + `isActive` flips
    /// during a switch) into a single 200ms-debounced write.
    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.saveAccountsImmediate()
        }
    }

    private func saveAccountsImmediate() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
            log.debug("[saveAccounts] Saved \(self.accounts.count) accounts to UserDefaults")
        }
    }

    private func updateActiveAccount(from status: AuthStatus) async {
        guard status.loggedIn, let email = status.email else { return }

        if let index = accounts.firstIndex(where: { $0.email == email }) {
            for i in accounts.indices {
                accounts[i].isActive = (i == index)
            }
            accounts[index].orgName = status.orgName
            accounts[index].subscriptionType = status.subscriptionType
            activeAccount = accounts[index]
            scheduleSave()
            log.info("[updateActiveAccount] Matched existing account at index \(index)")
        } else if accounts.isEmpty {
            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            accounts.append(account)
            activeAccount = account
            _ = await claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            scheduleSave()
            log.info("[updateActiveAccount] Auto-created first account, id=\(account.id)")
        } else {
            log.info("[updateActiveAccount] Logged-in account not in our list (might be new)")
        }
    }
}
