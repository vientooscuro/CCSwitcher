import Foundation
import Combine

/// What a provider can actually do. Views hide affordances rather than calling
/// methods that silently no-op — Codex ships read-only in stage 2 and gains
/// switching in stage 3, and the UI must follow without edits.
struct ProviderCapabilities {
    let canSwitchAccounts: Bool
    let canImportCurrent: Bool
    let canLoginNewAccount: Bool
    let canReauthenticate: Bool
    /// Whether the provider owns its account list at all. False for a read-only
    /// provider, which must not offer rename or remove either — a delete button
    /// on a provider we cannot manage is worse than misleading.
    let managesAccounts: Bool
    let tracksLinesWritten: Bool

    static let claude = ProviderCapabilities(
        canSwitchAccounts: true,
        canImportCurrent: true,
        canLoginNewAccount: true,
        canReauthenticate: true,
        managesAccounts: true,
        tracksLinesWritten: true
    )
}

/// Everything the popover asks of a provider. Implemented by `AppState` for
/// Claude and by `CodexState` for Codex.
@MainActor
protocol ProviderSurface: AnyObject, ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var providerType: AIProviderType { get }
    /// The provider's CLI or config was found on this machine.
    var isAvailable: Bool { get }
    var isLoading: Bool { get }
    /// A browser OAuth round trip is in flight; the UI blocks account actions.
    var isAuthenticating: Bool { get }
    var errorMessage: String? { get }
    var lastRefresh: Date? { get }
    var capabilities: ProviderCapabilities { get }

    var header: AccountHeaderModel? { get }
    var accountCards: [UsageCardModel] { get }
    var accountRows: [AccountRowModel] { get }
    var activity: ActivitySummaryModel { get }
    var cost: CostSeriesModel { get }
    /// This surface's data, flattened for the desktop widget.
    var widgetSnapshot: WidgetData { get }
    /// Set by `ProviderHub` at init. Every surface calls this once a refresh
    /// finishes so the hub can write the widget snapshot — regardless of
    /// whether the refresh was triggered through the hub or, for Claude, its
    /// own internal timer.
    var didRefresh: (() -> Void)? { get set }

    func refresh(force: Bool) async
    func switchTo(accountId: UUID) async
    /// Adopt whichever account the provider's CLI is already signed in as.
    func importCurrentAccount() async
    /// Run a browser OAuth flow and add the result as a new account.
    func loginNewAccount() async
    func removeAccount(id: UUID)
    func reauthenticate(id: UUID) async
    func setLabel(_ label: String?, forAccount id: UUID)
}
