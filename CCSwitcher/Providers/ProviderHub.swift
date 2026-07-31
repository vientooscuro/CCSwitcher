import SwiftUI
import Combine
import WidgetKit

private let log = FileLog("ProviderHub")

/// Owns every provider surface and exposes the active one.
///
/// SwiftUI cannot inject an `EnvironmentObject` by protocol existential, so a
/// concrete hub is the single observable object views see. It forwards each
/// surface's `objectWillChange` so a view that observes only the hub still
/// re-renders when the underlying provider's data changes.
///
/// Adding a provider is one `surfaces` entry plus one `ProviderTheme` case.
@MainActor
final class ProviderHub: ObservableObject {
    @Published private(set) var available: [AIProviderType]
    @Published private(set) var activeProvider: AIProviderType

    private var surfaces: [AIProviderType: any ProviderSurface]
    private var forwarders: [AnyCancellable] = []
    private var periodicRefreshTimer: Timer?
    private var periodicRefreshInterval: TimeInterval = 300

    /// Hash of the last widget snapshot written — skips
    /// `WidgetCenter.reloadAllTimelines` when nothing meaningful changed.
    private var lastWidgetSnapshotHash: Int?

    private static let persistenceKey = "activeProvider"

    var surface: any ProviderSurface {
        // `available` is never empty and every available provider has a
        // registered surface, so this is total. The fallback keeps the app
        // rendering instead of trapping if that invariant is ever broken.
        surfaces[activeProvider] ?? surfaces.values.first!
    }

    var theme: ProviderTheme { .theme(for: activeProvider) }

    /// Whether to show the switcher at all. A Claude-only machine keeps today's
    /// header exactly as it is.
    var showsSwitcher: Bool { available.count > 1 }

    init(surfaces: [AIProviderType: any ProviderSurface], available: [AIProviderType]) {
        precondition(!surfaces.isEmpty, "ProviderHub requires at least one surface")
        let registered = available.filter { surfaces[$0] != nil }
        let effective = registered.isEmpty ? Array(surfaces.keys) : registered

        self.surfaces = surfaces
        self.available = effective
        self.activeProvider = ProviderRegistry.resolveActive(
            persisted: UserDefaults.standard.string(forKey: Self.persistenceKey),
            available: effective
        )
        installForwarders()
        wireWidgetSnapshotUpdates()
        // MenuBarConfig.shared defaults to Claude; sync it here too so a
        // relaunch with, say, Codex persisted as active does not leave the
        // strip's module list stuck on Claude's until the user switches away
        // and back.
        MenuBarConfig.shared.setActive(provider: self.activeProvider)
        log.info("[init] available=\(effective.map(\.rawValue)) active=\(self.activeProvider.rawValue)")
    }

    func select(_ provider: AIProviderType) {
        guard provider != activeProvider, surfaces[provider] != nil else { return }
        activeProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.persistenceKey)
        MenuBarConfig.shared.setActive(provider: provider)
        log.info("[select] active=\(provider.rawValue)")
        Task { await surfaces[provider]?.refresh(force: false) }
        startPeriodicRefresh(interval: periodicRefreshInterval)
    }

    /// Refresh only the visible provider. Polling a provider the user is not
    /// looking at spends CPU and, worse, rate-limit budget.
    func refreshActive(force: Bool) async {
        await surface.refresh(force: force)
    }

    /// Periodic refresh for the active provider. Claude has its own timer in
    /// `AppState` (it also feeds the widget), so this only runs for other
    /// providers — refreshing Claude here as well would double every fetch
    /// against a rate-limited endpoint.
    func startPeriodicRefresh(interval: TimeInterval) {
        periodicRefreshInterval = interval
        stopPeriodicRefresh()
        guard activeProvider != .claudeCode else { return }

        // `withTimeInterval:repeats:` does not fire immediately — `select(_:)`
        // already kicks its own one-off refresh, so an immediate fire here
        // would double that first fetch.
        periodicRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshActive(force: false)
            }
        }
    }

    func stopPeriodicRefresh() {
        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = nil
    }

    /// The active provider owns the widget snapshot. Writing from both would
    /// make the widget flicker between providers on every refresh.
    func updateWidgetSnapshot() {
        let data = surface.widgetSnapshot
        data.save()

        let hash = Self.widgetSnapshotHash(data)
        guard hash != lastWidgetSnapshotHash else {
            log.debug("[updateWidgetSnapshot] unchanged, skipping reload")
            return
        }
        lastWidgetSnapshotHash = hash
        WidgetCenter.shared.reloadAllTimelines()
        log.debug("[updateWidgetSnapshot] reloaded (data changed, provider=\(data.provider ?? "nil"))")
    }

    private func installForwarders() {
        forwarders = surfaces.values.map { surface in
            surface.objectWillChange.sink { [weak self] _ in
                // The surface has not applied its mutation yet, so bounce to the
                // next turn of the main loop before republishing.
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            }
        }
    }

    /// Every surface calls `didRefresh` once its own refresh finishes —
    /// whether that refresh was triggered through this hub or, for Claude,
    /// its own internal timer. Wiring it here (rather than in each surface)
    /// keeps the "who writes the widget" decision in one place.
    private func wireWidgetSnapshotUpdates() {
        surfaces.values.forEach { surface in
            surface.didRefresh = { [weak self] in self?.updateWidgetSnapshot() }
        }
    }

    /// Hashes the fields that matter for the widget's rendered content.
    /// `lastUpdated` is excluded so the timestamp alone never triggers a
    /// needless reload.
    private static func widgetSnapshotHash(_ data: WidgetData) -> Int {
        var hasher = Hasher()
        hasher.combine(data.provider ?? "")
        hasher.combine(data.todayCost)
        hasher.combine(data.conversationTurns)
        hasher.combine(data.activeCodingTime)
        hasher.combine(data.linesWritten)
        for (k, v) in data.modelUsage.sorted(by: { $0.key < $1.key }) {
            hasher.combine(k); hasher.combine(v)
        }
        for w in data.accounts {
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
            for s in w.scopedLimits ?? [] {
                hasher.combine(s.modelName)
                hasher.combine(Int(s.utilization))
                hasher.combine(s.resetTime ?? "")
            }
        }
        return hasher.finalize()
    }
}
