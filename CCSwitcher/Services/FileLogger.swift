import Foundation

/// Drop-in replacement for os.Logger that writes to ~/Library/Logs/CCSwitcher-app.log.
/// Usage: `let log = FileLog("Category"); log.info("message")`
/// Read logs: `cat ~/Library/Logs/CCSwitcher-app.log` or `tail -f ~/Library/Logs/CCSwitcher-app.log`
struct FileLog: Sendable {
    private static let shared = FileLogWriter()
    private let category: String

    init(_ category: String) {
        self.category = category
    }

    func info(_ message: String) { FileLog.shared.write("INFO", category, message) }
    func warning(_ message: String) { FileLog.shared.write("WARN", category, message) }
    func error(_ message: String) { FileLog.shared.write("ERROR", category, message) }
    func debug(_ message: String) { FileLog.shared.write("DEBUG", category, message) }
}

private final class FileLogWriter: @unchecked Sendable {
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.ccswitcher.filelog")
    private let dateFormatter: ISO8601DateFormatter

    init() {
        let logsDir = NSHomeDirectory() + "/Library/Logs"
        let path = logsDir + "/CCSwitcher-app.log"

        // Remove the legacy log file from versions <= 1.4.4, which may contain
        // an Authorization Bearer token captured by the old getUsageLimits log
        // (see GitHub issue #11). Best-effort; ignore errors if it doesn't exist.
        try? FileManager.default.removeItem(atPath: logsDir + "/CCSwitcher.log")

        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Truncate on launch so we always see the current session
        FileManager.default.createFile(atPath: path, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: path)

        let ts = dateFormatter.string(from: Date())
        let header = "====== CCSwitcher launched \(ts) ======\n"
        if let data = header.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    func write(_ level: String, _ category: String, _ message: String) {
        queue.async { [weak self] in
            guard let self, let fh = self.fileHandle else { return }
            let ts = self.dateFormatter.string(from: Date())
            let line = "[\(ts)] [\(level)] [\(category)] \(message)\n"
            if let data = line.data(using: .utf8) {
                fh.write(data)
            }
        }
    }
}
