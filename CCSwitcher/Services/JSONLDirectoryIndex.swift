import Foundation

/// Single source of truth for the contents of `~/.claude/projects/`.
///
/// CostParser and ActivityParser used to walk the directory independently —
/// each refresh did N projects × M `contentsOfDirectory` + `attributesOfItem`
/// calls twice. This actor caches the file list (with mtime + size signatures)
/// and serves both parsers from one snapshot per refresh.
actor JSONLDirectoryIndex {
    static let shared = JSONLDirectoryIndex()

    struct Entry: Sendable {
        let path: String
        let fileName: String      // basename including ".jsonl"
        let projectDir: String
        let signature: JSONLStreamReader.FileSignature
    }

    private var cachedEntries: [Entry] = []
    private var cachedAt: Date = .distantPast
    /// Re-scan the directory at most once per second (the FS itself doesn't
    /// change that often during a single refresh).
    private let staleAfter: TimeInterval = 1.0

    private init() {}

    func entries() -> [Entry] {
        if Date().timeIntervalSince(cachedAt) < staleAfter, !cachedEntries.isEmpty {
            return cachedEntries
        }

        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            cachedEntries = []
            cachedAt = Date()
            return []
        }

        var result: [Entry] = []
        result.reserveCapacity(cachedEntries.count)
        for projectDir in projectDirs {
            let projectPath = projectsDir + "/" + projectDir
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = projectPath + "/" + file
                guard let signature = JSONLStreamReader.signature(forPath: filePath) else { continue }
                result.append(Entry(
                    path: filePath,
                    fileName: file,
                    projectDir: projectDir,
                    signature: signature
                ))
            }
        }

        cachedEntries = result
        cachedAt = Date()
        return result
    }
}
