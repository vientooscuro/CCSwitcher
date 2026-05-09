import Foundation

private let log = FileLog("ActivityParser")

/// Parses Claude Code session JSONL files to extract today's coding activity stats.
///
/// Memory strategy:
///   1. Files modified before today's local midnight are skipped via mtime check (no I/O).
///   2. The remaining files are streamed line-by-line via `JSONLStreamReader`.
///   3. Each line is decoded with `JSONDecoder` into a typed struct (no NSDictionary bridging).
///   4. Per-file activity aggregates are cached by (mtime, size); unchanged files are reused.
///   5. The whole pass runs inside `autoreleasepool` blocks so transient buffers drain immediately.
actor ActivityParser {
    static let shared = ActivityParser()

    private let claudeDir: String

    /// Per-file aggregate. Already filtered to "today" — caching is safe because
    /// the file signature changes whenever new lines are appended.
    private struct FileAggregate {
        let signature: JSONLStreamReader.FileSignature
        var turns: Int
        var sessionTimestamps: [String: [Date]]
        var toolCounts: [String: Int]
        var linesWritten: Int
        var modelCounts: [String: Int]
    }
    private var fileCache: [String: FileAggregate] = [:]
    private var cacheDay: String?

    private init() {
        self.claudeDir = NSHomeDirectory() + "/.claude"
    }

    // MARK: - Public

    func getTodayStats() async -> ActivityStats {
        let entries = await JSONLDirectoryIndex.shared.entries()

        let dateFormatter = Formatters.isoDay
        let todayStr = dateFormatter.string(from: Date())

        // Reset cache when the day rolls over.
        if cacheDay != todayStr {
            fileCache.removeAll(keepingCapacity: false)
            cacheDay = todayStr
        }

        // Anything written before today's local midnight cannot contain today's events.
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let decoder = JSONDecoder()

        // Aggregated totals (across all files).
        var turns = 0
        var sessionTimestamps: [String: [Date]] = [:]
        var toolCounts: [String: Int] = [:]
        var linesWritten = 0
        var modelCounts: [String: Int] = [:]
        var visited: Set<String> = []

        for entry in entries {
            let file = entry.fileName
            if file.contains("subagent") { continue }
            if entry.path.contains("/subagents/") { continue }

            // mtime predates today → no events for today possible.
            if entry.signature.mtime < startOfToday { continue }

            visited.insert(entry.path)

            let aggregate: FileAggregate
            if let cached = fileCache[entry.path], cached.signature == entry.signature {
                aggregate = cached
            } else {
                aggregate = parseFile(
                    path: entry.path,
                    fileName: file,
                    signature: entry.signature,
                    todayStr: todayStr,
                    dateFormatter: dateFormatter,
                    decoder: decoder
                )
                fileCache[entry.path] = aggregate
            }

            // Merge into totals
            turns += aggregate.turns
            linesWritten += aggregate.linesWritten
            for (k, v) in aggregate.toolCounts { toolCounts[k, default: 0] += v }
            for (sid, dates) in aggregate.sessionTimestamps {
                sessionTimestamps[sid, default: []].append(contentsOf: dates)
            }
            // requestId is unique per JSONL file, so per-file modelCounts
            // can be summed across files without cross-file dedup.
            for (k, v) in aggregate.modelCounts { modelCounts[k, default: 0] += v }
        }

        // Drop stale cache entries (files removed/rotated).
        if visited.count != fileCache.count {
            fileCache = fileCache.filter { visited.contains($0.key) }
        }

        let activeMinutes = Self.calculateActiveMinutes(from: sessionTimestamps)

        log.info("[getTodayStats] turns=\(turns) active=\(activeMinutes)m tools=\(toolCounts.values.reduce(0,+)) lines=\(linesWritten) models=\(modelCounts) cache=\(self.fileCache.count) files")
        return ActivityStats(
            conversationTurns: turns,
            activeCodingMinutes: activeMinutes,
            toolUsage: toolCounts,
            linesWritten: linesWritten,
            modelUsage: modelCounts
        )
    }

    // MARK: - Per-file parsing

    private func parseFile(
        path: String,
        fileName: String,
        signature: JSONLStreamReader.FileSignature,
        todayStr: String,
        dateFormatter: DateFormatter,
        decoder: JSONDecoder
    ) -> FileAggregate {
        var turns = 0
        var sessionTimestamps: [String: [Date]] = [:]
        var toolCounts: [String: Int] = [:]
        var linesWritten = 0
        var modelCounts: [String: Int] = [:]
        var seenRequests: Set<String> = []

        autoreleasepool {
            JSONLStreamReader.forEachLine(path: path) { line in
                guard let lineData = line.data(using: .utf8),
                      let entry = try? decoder.decode(ActivityLineEntry.self, from: lineData),
                      let timestampStr = entry.timestamp,
                      let timestamp = Formatters.isoFractional.date(from: timestampStr) ?? Formatters.iso.date(from: timestampStr) else { return }

                guard dateFormatter.string(from: timestamp) == todayStr else { return }

                let type = entry.type ?? ""
                let sessionId = entry.sessionId ?? fileName
                sessionTimestamps[sessionId, default: []].append(timestamp)

                switch type {
                case "user":
                    if let content = entry.message?.content {
                        switch content {
                        case .string(let s):
                            if !s.isEmpty { turns += 1 }
                        case .blocks(let arr):
                            let hasToolResult = arr.contains { $0.type == "tool_result" }
                            if !hasToolResult { turns += 1 }
                        case .other:
                            break
                        }
                    }

                case "assistant":
                    guard let message = entry.message else { return }

                    if let model = message.model,
                       let requestId = entry.requestId,
                       !seenRequests.contains(requestId) {
                        seenRequests.insert(requestId)
                        let shortName = CostParser.shortModelName(model)
                        modelCounts[shortName, default: 0] += 1
                    }

                    if case .blocks(let arr) = message.content {
                        for block in arr where block.type == "tool_use" {
                            guard let toolName = block.name else { continue }
                            toolCounts[toolName, default: 0] += 1
                            if let input = block.input {
                                linesWritten += Self.estimateLines(tool: toolName, input: input)
                            }
                        }
                    }

                default:
                    break
                }
            }
        }

        return FileAggregate(
            signature: signature,
            turns: turns,
            sessionTimestamps: sessionTimestamps,
            toolCounts: toolCounts,
            linesWritten: linesWritten,
            modelCounts: modelCounts
        )
    }

    // MARK: - Decoder model

    private struct ActivityLineEntry: Decodable {
        let type: String?
        let timestamp: String?
        let sessionId: String?
        let requestId: String?
        let message: Message?

        struct Message: Decodable {
            let model: String?
            let content: Content?
        }

        enum Content: Decodable {
            case string(String)
            case blocks([Block])
            case other

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .string(s); return }
                if let a = try? c.decode([Block].self) { self = .blocks(a); return }
                self = .other
            }
        }

        struct Block: Decodable {
            let type: String?
            let name: String?
            let input: ToolInput?
        }

        struct ToolInput: Decodable {
            let content: String?
            let new_string: String?
            let old_string: String?
        }
    }

    // MARK: - Helpers

    private static func estimateLines(tool: String, input: ActivityLineEntry.ToolInput) -> Int {
        switch tool {
        case "Write":
            let content = input.content ?? ""
            return content.split(separator: "\n", omittingEmptySubsequences: false).count
        case "Edit":
            let newStr = input.new_string ?? ""
            let oldStr = input.old_string ?? ""
            let added = newStr.split(separator: "\n", omittingEmptySubsequences: false).count
            let removed = oldStr.split(separator: "\n", omittingEmptySubsequences: false).count
            return max(0, added - removed)
        default:
            return 0
        }
    }

    private static func calculateActiveMinutes(from sessionTimestamps: [String: [Date]]) -> Int {
        let maxGap: TimeInterval = 10 * 60
        let tailPadding: TimeInterval = 2 * 60

        var totalSeconds: TimeInterval = 0

        for (_, timestamps) in sessionTimestamps {
            guard timestamps.count >= 2 else {
                if !timestamps.isEmpty { totalSeconds += tailPadding }
                continue
            }

            let sorted = timestamps.sorted()
            var periodStart = sorted[0]
            var periodEnd = sorted[0]

            for i in 1..<sorted.count {
                let gap = sorted[i].timeIntervalSince(periodEnd)
                if gap <= maxGap {
                    periodEnd = sorted[i]
                } else {
                    totalSeconds += periodEnd.timeIntervalSince(periodStart) + tailPadding
                    periodStart = sorted[i]
                    periodEnd = sorted[i]
                }
            }
            totalSeconds += periodEnd.timeIntervalSince(periodStart) + tailPadding
        }

        return totalSeconds > 0 ? max(1, Int(totalSeconds / 60)) : 0
    }
}
