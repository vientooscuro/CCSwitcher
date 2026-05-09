import Foundation

/// Reads `~/.claude/sessions/*.json` to surface currently-active sessions.
///
/// `actor` so the directory walk + per-file JSON decode never block the main
/// thread (refresh runs on `@MainActor`).
actor StatsParser {
    static let shared = StatsParser()

    private let sessionsDir: String

    private init() {
        self.sessionsDir = NSHomeDirectory() + "/.claude/sessions"
    }

    func getActiveSessions() -> [SessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            return []
        }

        let decoder = JSONDecoder()
        return files.compactMap { filename -> SessionInfo? in
            guard filename.hasSuffix(".json") else { return nil }
            let path = sessionsDir + "/" + filename
            guard let data = fm.contents(atPath: path) else { return nil }
            return try? decoder.decode(SessionInfo.self, from: data)
        }
    }
}
