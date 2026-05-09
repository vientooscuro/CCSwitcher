import Foundation

/// Streaming JSONL line reader. Reads file in 64 KB chunks and emits one
/// String per newline-terminated record without ever holding the whole
/// file (or its UTF-8 string representation) in memory.
enum JSONLStreamReader {
    static func forEachLine(path: String, _ handler: (String) -> Void) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }

        var leftover = Data()
        leftover.reserveCapacity(64 * 1024)
        let chunkSize = 64 * 1024

        while true {
            autoreleasepool {
                let chunk = fh.readData(ofLength: chunkSize)
                if chunk.isEmpty {
                    leftover.append(0xFF) // sentinel handled below
                    return
                }
                leftover.append(chunk)

                while let nl = leftover.firstIndex(of: 0x0A) {
                    let lineData = leftover.subdata(in: leftover.startIndex..<nl)
                    leftover.removeSubrange(leftover.startIndex...nl)
                    if !lineData.isEmpty,
                       let line = String(data: lineData, encoding: .utf8) {
                        handler(line)
                    }
                }
            }
            // Sentinel marks EOF
            if leftover.last == 0xFF {
                leftover.removeLast()
                break
            }
        }

        if !leftover.isEmpty, let line = String(data: leftover, encoding: .utf8), !line.isEmpty {
            handler(line)
        }
    }

    /// File metadata used as a cache key (mtime + size). Two files with the
    /// same path that share both values are treated as unchanged.
    struct FileSignature: Equatable {
        let mtime: Date
        let size: Int64
    }

    static func signature(forPath path: String) -> FileSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return FileSignature(mtime: mtime, size: size)
    }
}
