import Foundation

private let log = FileLog("CodexCLI")

enum CodexCLIError: LocalizedError {
    case notFound
    case failed(exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "codex CLI not found"
        case .failed(let exitCode, let stderr):
            return "codex exited with code \(exitCode): \(stderr)"
        }
    }
}

/// Wraps the `codex` CLI: binary resolution, login/logout, and version detection.
/// Mirrors `ClaudeService`'s process-running approach, including its PATH
/// augmentation, so a Homebrew- or npm-installed `codex` resolves the same way.
actor CodexCLIService {
    static let shared = CodexCLIService()

    /// User override, else the first hit from curated install locations, else shell PATH.
    static let binaryPathPreferenceKey = "codexBinaryPathPreference"

    /// User override, else the first curated candidate that exists, else a shell PATH lookup.
    func resolvedBinaryPath() -> String? {
        let preference = UserDefaults.standard.string(forKey: Self.binaryPathPreferenceKey) ?? ""
        if !preference.isEmpty, FileManager.default.isExecutableFile(atPath: preference) {
            return preference
        }
        if let curated = Self.curatedCandidates().first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return curated
        }
        return Self.shellPathLookup()
    }

    func isAvailable() -> Bool {
        resolvedBinaryPath() != nil
    }

    /// `codex login` — opens the browser, returns when the process exits.
    func login() async throws {
        guard let path = resolvedBinaryPath() else { throw CodexCLIError.notFound }
        log.info("[login] Starting `codex login`... (will open browser)")
        _ = try await Self.run(path: path, args: ["login"])
        log.info("[login] `codex login` process exited")
    }

    /// `codex logout`.
    func logout() async throws {
        guard let path = resolvedBinaryPath() else { throw CodexCLIError.notFound }
        log.info("[logout] Running `codex logout`...")
        _ = try await Self.run(path: path, args: ["logout"])
        log.info("[logout] Logout complete")
    }

    /// `codex login status` — read-only, returns its stdout trimmed.
    func loginStatus() async -> String? {
        guard let path = resolvedBinaryPath() else { return nil }
        guard let output = try? await Self.run(path: path, args: ["login", "status"], timeout: 5.0) else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run `<path> --version` and return the first semver-looking token.
    /// Returns nil on launch failure, non-zero exit, timeout, or no version found.
    static func readVersion(at path: String) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        guard let output = try? await run(path: path, args: ["--version"], timeout: 5.0) else { return nil }
        return extractSemver(from: output)
    }

    // MARK: - Detection

    private static func curatedCandidates() -> [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/opt/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex"
        ]
    }

    private static func shellPathLookup() -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v codex"]
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            log.warning("[shellPathLookup] Failed to launch /bin/zsh: \(error.localizedDescription)")
            return nil
        }

        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            log.warning("[shellPathLookup] zsh exceeded 3s timeout; aborting")
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let candidate = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard candidate.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: candidate) else {
            return nil
        }
        return candidate
    }

    private static func buildEnvironment(binaryPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let homeDir = NSHomeDirectory()

        var extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDir)/.local/bin",
            "\(homeDir)/.npm-global/bin"
        ]
        if binaryPath.contains("/") {
            // Resolve symlinks once so an NVM-installed CLI finds `node` on PATH.
            let resolved = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path
            let resolvedBinDir = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
            extraPaths.insert(resolvedBinDir, at: 0)
        }
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        env["HOME"] = homeDir
        return env
    }

    // MARK: - CLI Runner

    /// Runs `path args…` off the actor's executor, on a background queue, with the
    /// same PATH augmentation as `ClaudeService`. `timeout` bounds read-only calls
    /// (version, status); `login`/`logout` pass nil since browser OAuth can take a while.
    private static func run(path: String, args: [String], timeout: TimeInterval? = nil) async throws -> String {
        let env = buildEnvironment(binaryPath: path)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                // One pipe for both streams — `codex login status` writes its
                // human-readable line to stderr, not stdout, so keeping them
                // separate would silently drop it.
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe
                process.environment = env

                do {
                    try process.run()
                } catch {
                    log.warning("[run] launch failed for \(path): \(error.localizedDescription)")
                    continuation.resume(throwing: CodexCLIError.notFound)
                    return
                }

                if let timeout {
                    let deadline = Date().addingTimeInterval(timeout)
                    while process.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if process.isRunning {
                        process.terminate()
                        log.warning("[run] \(path) \(args.joined(separator: " ")) timed out after \(timeout)s")
                        continuation.resume(throwing: CodexCLIError.failed(exitCode: -1, stderr: "timed out"))
                        return
                    }
                } else {
                    process.waitUntilExit()
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: CodexCLIError.failed(exitCode: process.terminationStatus, stderr: output))
                    return
                }
                continuation.resume(returning: output)
            }
        }
    }

    /// Extract the first dotted-ASCII-numeric token from a string
    /// (e.g. "0.145.0" out of "codex-cli 0.145.0").
    private static func extractSemver(from text: String) -> String? {
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isNumber || $0 == ".") }
        for token in text.split(whereSeparator: { !allowed($0) }) {
            let s = String(token)
            guard isPureSemver(s) else { continue }
            return s
        }
        return nil
    }

    /// True if the whole string is ASCII digits separated by dots (e.g. "0.145.0").
    private static func isPureSemver(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 32 else { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for p in parts {
            guard !p.isEmpty else { return false }
            for ch in p {
                guard ch.isASCII, ch.isNumber else { return false }
            }
        }
        return true
    }
}
