import Foundation

/// Drop-in replacement for os.Logger that writes to ~/Library/Logs/CCSwitcher-app.log.
///
/// Writes are coalesced: log lines accumulate in an in-memory buffer that is
/// flushed at most every 100ms, or eagerly when the buffer crosses 64 KB.
/// This collapses dozens of tiny `write()` syscalls per refresh into one.
///
/// Rotates at 5MB, keeps 2 prior files (.1 and .2) for ~15MB total cap.
/// Usage: `let log = FileLog("Category"); log.info("message")`
/// Read logs: `cat ~/Library/Logs/CCSwitcher-app.log`
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
    private let logsDir: String
    private let basePath: String
    private var fileHandle: FileHandle?
    private var bytesWritten: UInt64 = 0
    private let queue = DispatchQueue(label: "com.ccswitcher.filelog")
    private var pending = Data()
    private var flushScheduled = false

    /// Hard cap on pending bytes — flush eagerly when reached so a burst of
    /// log activity doesn't sit in memory.
    private static let flushThreshold = 64 * 1024
    /// Target latency from log call to disk.
    private static let flushDelay: DispatchTimeInterval = .milliseconds(100)

    private static let maxFileBytes: UInt64 = 5 * 1024 * 1024  // 5 MB
    private static let keepRotated = 2  // .1 and .2 → ~15MB total cap

    init() {
        let logsDir = NSHomeDirectory() + "/Library/Logs"
        self.logsDir = logsDir
        self.basePath = logsDir + "/CCSwitcher-app.log"

        // Remove the legacy log file from versions <= 1.4.4 (might contain a
        // captured Authorization Bearer token — see GH issue #11).
        try? FileManager.default.removeItem(atPath: logsDir + "/CCSwitcher.log")

        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        openHandle()
        writeSessionHeader()

        // Best-effort flush on graceful exit.
        atexit_b { [weak self] in
            self?.flushSync()
        }
    }

    private func openHandle() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: basePath) {
            fm.createFile(atPath: basePath, contents: nil)
            bytesWritten = 0
        } else {
            let attrs = try? fm.attributesOfItem(atPath: basePath)
            bytesWritten = (attrs?[.size] as? UInt64) ?? 0
        }
        fileHandle = FileHandle(forWritingAtPath: basePath)
        _ = try? fileHandle?.seekToEnd()
    }

    private func writeSessionHeader() {
        let ts = Formatters.isoFractional.string(from: Date())
        let header = "====== CCSwitcher launched \(ts) ======\n"
        if let data = header.data(using: .utf8) {
            fileHandle?.write(data)
            bytesWritten += UInt64(data.count)
        }
    }

    func write(_ level: String, _ category: String, _ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let ts = Formatters.isoFractional.string(from: Date())
            let line = "[\(ts)] [\(level)] [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            self.pending.append(data)

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
        bytesWritten += UInt64(data.count)
        if bytesWritten >= Self.maxFileBytes {
            rotate()
        }
    }

    /// Synchronous flush — used at process exit.
    fileprivate func flushSync() {
        queue.sync { flushLocked() }
    }

    /// Rotate: close current → bump .1→.2, .log→.1 (drop oldest) → open fresh.
    /// Called only on the serial queue; safe to mutate fileHandle.
    private func rotate() {
        try? fileHandle?.close()
        fileHandle = nil

        let fm = FileManager.default
        // Drop the oldest rotated file if it exists.
        let oldestPath = "\(basePath).\(Self.keepRotated)"
        try? fm.removeItem(atPath: oldestPath)

        // Shift .N-1 → .N, ..., .1 → .2.
        var idx = Self.keepRotated
        while idx > 1 {
            let from = "\(basePath).\(idx - 1)"
            let to = "\(basePath).\(idx)"
            if fm.fileExists(atPath: from) {
                try? fm.moveItem(atPath: from, toPath: to)
            }
            idx -= 1
        }

        // Move current → .1.
        let firstRotated = "\(basePath).1"
        try? fm.removeItem(atPath: firstRotated)
        if fm.fileExists(atPath: basePath) {
            try? fm.moveItem(atPath: basePath, toPath: firstRotated)
        }

        // Reopen a fresh active file.
        openHandle()
        let ts = Formatters.isoFractional.string(from: Date())
        let marker = "====== rotated at \(ts) ======\n"
        if let data = marker.data(using: .utf8) {
            fileHandle?.write(data)
            bytesWritten += UInt64(data.count)
        }
    }
}
