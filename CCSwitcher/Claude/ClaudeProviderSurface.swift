import Foundation

/// Adapts `AppState` — which owns all Claude credential, refresh and rate-limit
/// logic — to the shared `ProviderSurface` the popover consumes. Mapping only:
/// no behaviour lives here.
extension AppState: ProviderSurface {
    var providerType: AIProviderType { .claudeCode }

    var isAvailable: Bool { claudeAvailable }

    var isAuthenticating: Bool { isLoggingIn }

    var lastRefresh: Date? { lastUsageRefresh }

    var capabilities: ProviderCapabilities { .claude }

    private var obfuscateEmails: Bool {
        !UserDefaults.standard.bool(forKey: "showFullEmail")
    }

    var header: AccountHeaderModel? {
        activeAccount.map { ClaudeDisplayMapper.header(account: $0, obfuscate: obfuscateEmails) }
    }

    var accountCards: [UsageCardModel] {
        let obfuscate = obfuscateEmails
        return accounts.map { account in
            ClaudeDisplayMapper.card(
                account: account,
                usage: accountUsage[account.id],
                error: accountUsageErrors[account.id].map(ProviderErrorModel.init(claude:)),
                obfuscate: obfuscate
            )
        }
    }

    var accountRows: [AccountRowModel] {
        let obfuscate = obfuscateEmails
        return accounts.map { account in
            ClaudeDisplayMapper.row(
                account: account,
                hasStoredCredentials: accountsWithBackups.contains(account.id),
                obfuscate: obfuscate
            )
        }
    }

    var activity: ActivitySummaryModel { ClaudeDisplayMapper.activity(activityStats) }

    var cost: CostSeriesModel { ClaudeDisplayMapper.cost(costSummary) }

    // MARK: - Actions

    func refresh(force: Bool) async {
        await refresh(knownStatus: nil, force: force)
    }

    func switchTo(accountId: UUID) async {
        guard let account = accounts.first(where: { $0.id == accountId }) else { return }
        await switchTo(account)
    }

    func importCurrentAccount() async {
        await addAccount()
    }

    func removeAccount(id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        removeAccount(account)
    }

    func reauthenticate(id: UUID) async {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        await reauthenticateAccount(account)
    }

    func setLabel(_ label: String?, forAccount id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        updateAccountLabel(account, label: label)
    }
}

extension ProviderErrorModel {
    /// `AppState.UsageErrorState` is nested inside a `@MainActor` type, so the
    /// conversion lives here rather than in the pure mapper.
    init(claude state: AppState.UsageErrorState) {
        self.init(message: state.message, needsReauth: state.isExpired, isRateLimited: state.isRateLimited)
    }
}
