import AppKit

struct CodexDesktopProfile: Equatable, Sendable {
    let home: URL
    let userData: URL
    let isDefault: Bool

    var authURL: URL { home.appendingPathComponent("auth.json") }
    var launchArguments: [String] { ["--user-data-dir=\(userData.path)"] }

    func environment(inheriting source: [String: String]) -> [String: String] {
        let allowed = Set(["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING"])
        var environment = source.filter { allowed.contains($0.key) }
        environment["CODEX_HOME"] = home.path
        environment["CODEX_ELECTRON_USER_DATA_PATH"] = userData.path
        return environment
    }
}

@MainActor
final class CodexDesktopProfiles {
    private static let defaultAccountKey = "codexDesktopDefaultAccountID"
    private let userHome: URL
    private let defaults: UserDefaults

    init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard) {
        self.userHome = userHome
        self.defaults = defaults
    }

    var defaultAccountID: UUID? {
        defaults.string(forKey: Self.defaultAccountKey).flatMap(UUID.init(uuidString:))
    }

    var defaultProfile: CodexDesktopProfile {
        CodexDesktopProfile(
            home: userHome.appendingPathComponent(".codex", isDirectory: true),
            userData: userHome.appendingPathComponent("Library/Application Support/Codex", isDirectory: true),
            isDefault: true
        )
    }

    func bindDefault(to id: UUID) {
        guard defaultAccountID == nil else { return }
        defaults.set(id.uuidString, forKey: Self.defaultAccountKey)
    }

    func profile(for id: UUID) -> CodexDesktopProfile {
        guard id != defaultAccountID else { return defaultProfile }
        let root = userHome.appendingPathComponent("Library/Application Support/CCSwitcher/CodexProfiles/\(id.uuidString)")
        return CodexDesktopProfile(
            home: root.appendingPathComponent("home", isDirectory: true),
            userData: root.appendingPathComponent("desktop", isDirectory: true),
            isDefault: false
        )
    }

    func prepare(_ profile: CodexDesktopProfile) throws {
        guard !profile.isDefault else { return }
        let manager = FileManager.default
        for directory in [profile.home.deletingLastPathComponent(), profile.home, profile.userData] {
            if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let config = profile.home.appendingPathComponent("config.toml")
        if !manager.fileExists(atPath: config.path) {
            let contents = Data("cli_auth_credentials_store = \"file\"\n".utf8)
            guard manager.createFile(atPath: config.path, contents: contents, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    static func open(_ profile: CodexDesktopProfile) async throws {
        guard let applicationURL = applicationURL else {
            throw NSError(domain: "CodexDesktop", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install Codex in /Applications before opening a desktop account."])
        }
        // Electron's lock identifies the exact profile even after CCSwitcher restarts.
        if let running = runningInstance(for: profile) {
            running.activate(options: [.activateAllWindows])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // Chromium checks its native singleton before Electron reads the environment.
        configuration.arguments = profile.launchArguments
        configuration.environment = profile.environment(inheriting: ProcessInfo.processInfo.environment)
        _ = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
        for _ in 0..<50 {
            if runningInstance(for: profile) != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "CodexDesktop", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Codex did not start the isolated profile. Your existing login is unchanged."
        ])
    }

    private static func runningInstance(for profile: CodexDesktopProfile) -> NSRunningApplication? {
        guard let lock = try? FileManager.default.destinationOfSymbolicLink(atPath: profile.userData.appendingPathComponent("SingletonLock").path),
              let pidString = lock.split(separator: "-").last,
              let pid = Int32(pidString),
              let running = NSRunningApplication(processIdentifier: pid),
              running.bundleIdentifier == "com.openai.codex", !running.isTerminated else { return nil }
        return running
    }

    static var applicationURL: URL? {
        // Codex was renamed to ChatGPT; the old bundle may still be installed beside it.
        let installed = ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
        return installed.lazy.map { URL(fileURLWithPath: $0) }
            .first { Bundle(url: $0)?.bundleIdentifier == "com.openai.codex" }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
    }
}
