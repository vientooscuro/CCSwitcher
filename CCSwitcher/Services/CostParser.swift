import Foundation

private let log = FileLog("CostParser")

/// Parses Claude Code session JSONL files to calculate token costs.
///
/// Memory strategy:
///   1. Files are streamed line-by-line via `JSONLStreamReader` — never loaded whole.
///   2. Each line is decoded with `JSONDecoder` into a typed struct (no NSDictionary bridging).
///   3. Per-file results are cached by (mtime, size); unchanged files are skipped on re-runs.
///   4. The whole pass runs inside an `autoreleasepool` so transient buffers drain immediately.
actor CostParser {
    static let shared = CostParser()

    private let claudeDir: String

    /// Per-file cache. Key = absolute file path.
    /// Value = (signature, deduped requestId → TokenUsage).
    private struct FileCacheEntry {
        let signature: JSONLStreamReader.FileSignature
        let entries: [String: TokenUsage]
    }
    private var fileCache: [String: FileCacheEntry] = [:]

    private init() {
        self.claudeDir = NSHomeDirectory() + "/.claude"
    }

    // MARK: - Public

    /// Compute cost summary from all session JSONL files.
    func getCostSummary() async -> CostSummary {
        let usages = await parseAllSessions()

        let formatter = Formatters.isoDay
        let todayStr = formatter.string(from: Date())

        var dateGroups: [String: [TokenUsage]] = [:]
        var dateSessionFiles: [String: Set<String>] = [:]
        for usage in usages {
            let dateStr = formatter.string(from: usage.timestamp)
            dateGroups[dateStr, default: []].append(usage)
            dateSessionFiles[dateStr, default: []].insert(usage.sessionFile)
        }

        var dailyCosts: [DailyCost] = []
        for (date, usages) in dateGroups {
            var modelCosts: [String: Double] = [:]
            var totalInput = 0, totalOutput = 0, totalCacheWrite = 0, totalCacheRead = 0

            for u in usages {
                let cost = u.cost
                let shortModel = Self.shortModelName(u.model)
                modelCosts[shortModel, default: 0] += cost
                totalInput += u.inputTokens
                totalOutput += u.outputTokens
                totalCacheWrite += u.cacheWriteTokens
                totalCacheRead += u.cacheReadTokens
            }

            // Pre-sort once per day; views read this without re-sorting.
            let sorted = modelCosts
                .map { (model: $0.key, cost: $0.value) }
                .sorted { $0.cost > $1.cost }

            dailyCosts.append(DailyCost(
                date: date,
                totalCost: modelCosts.values.reduce(0, +),
                modelBreakdown: modelCosts,
                sortedBreakdown: sorted,
                sessionCount: dateSessionFiles[date]?.count ?? 0,
                inputTokens: totalInput,
                outputTokens: totalOutput,
                cacheWriteTokens: totalCacheWrite,
                cacheReadTokens: totalCacheRead
            ))
        }

        dailyCosts.sort { $0.date > $1.date }

        let todayCost = dailyCosts.first(where: { $0.date == todayStr })?.totalCost ?? 0

        log.info("[getCostSummary] Parsed \(usages.count) entries, \(dailyCosts.count) days, today=$\(String(format: "%.2f", todayCost)), cache=\(self.fileCache.count) files")
        return CostSummary(todayCost: todayCost, dailyCosts: dailyCosts)
    }

    // MARK: - Parsing

    /// Streaming JSONL decoder model. Only the fields we need.
    private struct LineEntry: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?

        struct Message: Decodable {
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            /// Legacy aggregate (5m + 1h). Kept for backwards compat with
            /// older JSONL records that don't have the `cache_creation`
            /// breakdown.
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            /// Modern breakdown — present in current Claude Code logs.
            let cache_creation: CacheCreation?

            struct CacheCreation: Decodable {
                let ephemeral_5m_input_tokens: Int?
                let ephemeral_1h_input_tokens: Int?
            }
        }
    }

    private func parseAllSessions() async -> [TokenUsage] {
        // Single shared directory walk + signature gather (also used by ActivityParser).
        let entries = await JSONLDirectoryIndex.shared.entries()
        let decoder = JSONDecoder()
        var allUsages: [TokenUsage] = []
        var visited: Set<String> = []
        visited.reserveCapacity(entries.count)

        for entry in entries {
            visited.insert(entry.path)
            let sessionFile = String(entry.fileName.dropLast(".jsonl".count))

            // Cache hit — skip parsing entirely.
            if let cached = fileCache[entry.path], cached.signature == entry.signature {
                allUsages.append(contentsOf: cached.entries.values)
                continue
            }

            var requestEntries: [String: TokenUsage] = [:]

            autoreleasepool {
                JSONLStreamReader.forEachLine(path: entry.path) { line in
                    guard let lineData = line.data(using: .utf8),
                          let parsed = try? decoder.decode(LineEntry.self, from: lineData),
                          parsed.type == "assistant",
                          let message = parsed.message,
                          let model = message.model,
                          let usage = message.usage,
                          let timestampStr = parsed.timestamp,
                          let requestId = parsed.requestId else { return }

                    guard ModelPricing.forModel(model) != nil else { return }

                    let timestamp = Formatters.isoFractional.date(from: timestampStr)
                        ?? Formatters.iso.date(from: timestampStr)
                        ?? Date()

                    // Cache write breakdown: prefer the new sub-object; if
                    // absent (older logs), fall back to the legacy aggregate
                    // and treat it as 5-minute (the only tier that existed
                    // before the 1-hour tier shipped).
                    let cc = usage.cache_creation
                    let tokens5m: Int
                    let tokens1h: Int
                    if let cc {
                        tokens5m = cc.ephemeral_5m_input_tokens ?? 0
                        tokens1h = cc.ephemeral_1h_input_tokens ?? 0
                    } else {
                        tokens5m = usage.cache_creation_input_tokens ?? 0
                        tokens1h = 0
                    }

                    // Last entry per requestId wins (streaming → final counts).
                    requestEntries[requestId] = TokenUsage(
                        inputTokens: usage.input_tokens ?? 0,
                        outputTokens: usage.output_tokens ?? 0,
                        cacheWrite5mTokens: tokens5m,
                        cacheWrite1hTokens: tokens1h,
                        cacheReadTokens: usage.cache_read_input_tokens ?? 0,
                        model: model,
                        timestamp: timestamp,
                        sessionFile: sessionFile
                    )
                }
            }

            fileCache[entry.path] = FileCacheEntry(signature: entry.signature, entries: requestEntries)
            allUsages.append(contentsOf: requestEntries.values)
        }

        // Drop cache entries for files that no longer exist.
        if visited.count != fileCache.count {
            fileCache = fileCache.filter { visited.contains($0.key) }
        }

        return allUsages
    }

    // MARK: - Helpers

    /// "claude-opus-4-6" → "Opus"
    static func shortModelName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }
}
