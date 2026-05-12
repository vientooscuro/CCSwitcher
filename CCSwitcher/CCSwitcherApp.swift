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
    @StateObject private var appState = AppState()
    @StateObject private var updateChecker = UpdateChecker()
    @AppStorage("showAccountName") private var showAccountName = true
    @AppStorage("showFullEmail") private var showFullEmail = false
    @AppStorage("refreshInterval") private var refreshInterval: Double = 300
    @AppStorage("appLanguage") private var appLanguage = "auto"

    var body: some Scene {
        // Hidden 1×1 window to keep SwiftUI's lifecycle alive so `Settings` scene
        // shows the native toolbar tabs even though the UI is AppKit-based.
        WindowGroup("CCSwitcherKeepalive") {
            HiddenWindowView()
                .onAppear {
                    // Sparkle's SPUStandardUpdaterController(startingUpdater: true)
                    // schedules its own background update checks; no need to
                    // call checkForUpdates here.
                    _ = updateChecker
                    Task {
                        await appState.refresh()
                    }
                }
        }
        .defaultSize(width: 20, height: 20)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MainMenuView()
                .environmentObject(appState)
                .environmentObject(updateChecker)
                .environment(\.locale, currentLocale)
                .onAppear {
                    // Refresh-on-open + start periodic timer.
                    appState.menuDidAppear()
                    appState.startAutoRefresh(interval: refreshInterval)
                    Task { await appState.refresh() }
                }
                .onDisappear {
                    // Pause timer while popover is closed — no point burning
                    // CPU/network polling state nobody can see.
                    appState.menuDidDisappear()
                }
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(updateChecker)
                .environment(\.locale, currentLocale)
        }
    }

    private var currentLocale: Locale {
        appLanguage == "auto" ? .autoupdatingCurrent : Locale(identifier: appLanguage)
    }

    private var menuBarLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "brain.head.profile")
            if showAccountName {
                if let account = appState.activeAccount {
                    Text(account.effectiveDisplayName(obfuscated: !showFullEmail))
                        .font(.caption)
                }
            }
        }
    }
}
