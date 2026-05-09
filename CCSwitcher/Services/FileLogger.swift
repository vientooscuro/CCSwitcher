import Foundation

/// Drop-in replacement for os.Logger that writes to ~/Library/Logs/CCSwitcher-app.log.
///
/// Writes are coalesced: log lines accumulate in an in-memory buffer that is
/// flushed at most every 100ms, or eagerly when the buffer crosses 64 KB.
/// This collapses dozens of tiny `write()` syscalls per refresh into one.
struct FileLog: Sendable {
    private static let shared = FileLogWriter()
    private let category: String

    init(_ category: String) {
        self.category = category
    }

    /// Always written. Use sparingly — flow checkpoints, important state transitions.
    func info(_ message: String) { FileLog.shared.write("INFO", category, message) }
    /// Always written.
    func warning(_ message: String) { FileLog.shared.write("WARN", category, message) }
    /// Always written.
    func error(_ message: String) { FileLog.shared.write("ERROR", category, message) }

    /// Debug-only — compiled out in Release. Use for `[runClaude]`, `[runSecurity]`,
    /// per-iteration spam that helped during development but bloats the log + costs
    /// `Date()`/formatter work on every refresh in the hands of users.
    @inlinable
    func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        FileLog.shared.write("DEBUG", category, message())
        #endif
    }
}

private final class FileLogWriter: @unchecked Sendable {
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.ccswitcher.filelog")
    private var pending = Data()
    private var flushScheduled = false

    /// Hard cap on pending bytes — flush eagerly when reached so a burst of
    /// log activity doesn't sit in memory.
    private static let flushThreshold = 64 * 1024
    /// Target latency from log call to disk.
    private static let flushDelay: DispatchTimeInterval = .milliseconds(100)

    init() {
        let logsDir = NSHomeDirectory() + "/Library/Logs"
        let path = logsDir + "/CCSwitcher-app.log"

        // Remove the legacy log file from versions <= 1.4.4 (might contain a
        // captured Authorization Bearer token — see GH issue #11).
        try? FileManager.default.removeItem(atPath: logsDir + "/CCSwitcher.log")

        FileManager.default.createFile(atPath: path, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: path)

        let ts = Formatters.isoFractional.string(from: Date())
        let header = "====== CCSwitcher launched \(ts) ======\n"
        if let data = header.data(using: .utf8) {
            fileHandle?.write(data)
        }

        // Best-effort flush on graceful exit.
        atexit_b { [weak self] in
            self?.flushSync()
        }
    }

    func write(_ level: String, _ category: String, _ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let ts = Formatters.isoFractional.string(from: Date())
            let line = "[\(ts)] [\(level)] [\(category)] \(message)\n"
            if let data = line.data(using: .utf8) {
                self.pending.append(data)
            }

            if self.pending.count >= Self.flushThreshold {
                self.flushLocked()
            } else if !self.flushScheduled {
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + Self.flushDelay) { [weak self] in
                    self?.flushLocked()
                }
            }
        }
    }

    /// Must be called only from `queue`.
    private func flushLocked() {
        flushScheduled = false
        guard !pending.isEmpty, let fh = fileHandle else { return }
        let data = pending
        pending.removeAll(keepingCapacity: true)
        fh.write(data)
    }

    /// Synchronous flush — used at process exit.
    fileprivate func flushSync() {
        queue.sync { flushLocked() }
    }
}
