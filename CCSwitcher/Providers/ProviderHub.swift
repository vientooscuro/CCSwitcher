import SwiftUI
import Combine

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

    private func installForwarders() {
        forwarders = surfaces.values.map { surface in
            surface.objectWillChange.sink { [weak self] _ in
                // The surface has not applied its mutation yet, so bounce to the
                // next turn of the main loop before republishing.
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            }
        }
    }
}
