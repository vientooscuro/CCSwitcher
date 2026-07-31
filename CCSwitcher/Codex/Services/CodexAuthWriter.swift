import Foundation

private let log = FileLog("CodexAuthWriter")

/// The only code in the project that writes credentials to a plaintext file.
enum CodexAuthWriter {

    /// Atomic, owner-only write. Writes a sibling temp file, chmods it to 0600,
    /// then renames over the target — so a crash mid-write can never leave Codex
    /// with a truncated credential file, and the credential is never briefly
    /// world-readable.
    static func write(_ contents: String, to path: String) -> Bool {
        let destination = URL(fileURLWithPath: path)
        let tempURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")

        let created = FileManager.default.createFile(
            atPath: tempURL.path,
            contents: Data(contents.utf8),
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            log.error("[write] Failed to create temp file at \(tempURL.path)")
            return false
        }

        // rename(2) is atomic on the same volume and replaces the destination
        // in place, unlike replaceItemAt(_:withItemAt:) which can carry over
        // the original file's attributes instead of the temp file's.
        let renamed = tempURL.path.withCString { tempC in
            destination.path.withCString { destC in
                rename(tempC, destC) == 0
            }
        }
        guard renamed else {
            log.error("[write] rename failed for \(destination.path): \(String(cString: strerror(errno)))")
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }

        log.info("[write] Wrote \(contents.count) bytes to \(destination.path)")
        return true
    }

    static func read(at path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}
