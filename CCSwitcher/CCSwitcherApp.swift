import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        // Apply saved language preference before any UI loads
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        if lang != "auto" {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App starts as agent/accessory due to LSUIElement
    }
}

@main
struct CCSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState: AppState
    @StateObject private var codexState: CodexState
    @StateObject private var providerHub: ProviderHub
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var menuBarConfig = MenuBarConfig.shared
    @AppStorage("refreshInterval") private var refreshInterval: Double = 300
    @AppStorage("appLanguage") private var appLanguage = "auto"

    @State private var statusItemController = StatusItemController()
    @State private var didBootstrap = false

    init() {
        let claude = AppState()
        let codex = CodexState()
        let available = ProviderRegistry.detect(
            claudeInstalled: true,   // corrected asynchronously via AppState.claudeAvailable
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        _appState = StateObject(wrappedValue: claude)
        _codexState = StateObject(wrappedValue: codex)
        _providerHub = StateObject(wrappedValue: ProviderHub(
            surfaces: [.claudeCode: claude, .codex: codex],
            available: available
        ))
    }

    /// CCSwitcherTests is a hosted test bundle, so `xcodebuild test` launches this
    /// real app process. Skip bootstrap there — otherwise every test run forks the
    /// `claude` CLI and hits the live usage endpoint, burning rate-limit budget.
    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        // Hidden 1×1 window to keep SwiftUI's lifecycle alive so `Settings` scene
        // shows the native toolbar tabs even though the UI is AppKit-based.
        WindowGroup("CCSwitcherKeepalive") {
            HiddenWindowView()
                .onAppear {
                    guard !didBootstrap, !isRunningUnitTests else { return }
                    didBootstrap = true
                    // Sparkle's SPUStandardUpdaterController(startingUpdater: true)
                    // schedules its own background update checks; no need to
                    // call checkForUpdates here.
                    _ = updateChecker
                    statusItemController.install(
                        appState: appState,
                        hub: providerHub,
                        config: menuBarConfig,
                        locale: currentLocale
                    )
                    // Kick off background usage tracking immediately upon app start
                    Task {
                        await appState.refresh()
                        appState.startAutoRefresh(interval: refreshInterval)
                    }
                }
                .onChange(of: appLanguage) { _, _ in
                    statusItemController.updateLocale(currentLocale)
                }
        }
        .defaultSize(width: 20, height: 20)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(providerHub)
                .environmentObject(updateChecker)
                .environmentObject(menuBarConfig)
                .environment(\.locale, currentLocale)
        }
    }

    private var currentLocale: Locale {
        appLanguage == "auto" ? .autoupdatingCurrent : Locale(identifier: appLanguage)
    }
}
