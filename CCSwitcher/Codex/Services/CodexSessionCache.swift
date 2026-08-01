import Foundation

private let log = FileLog("CodexCache")

/// Incrementally aggregates `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// A real install measured 940 files totalling 2 GB, so re-reading the tree on
/// every 5-minute refresh is not an option. Files are keyed by path and mtime;
/// unchanged files contribute their previously computed aggregate without being
/// opened. This mirrors `SessionParseCacheV2`, which solved the same problem for
/// Claude after re-parsing pegged the CPU on idle.
actor CodexSessionCache {
    static let shared = CodexSessionCache()

    private struct Envelope: Codable {
        let version: Int
        var files: [String: CodexRolloutAggregate]
    }

    /// Bump whenever the parser's output changes meaning, so cached aggregates
    /// computed by the old logic are discarded rather than trusted.
    /// v2: the parser matched `custom_tool_call` on the event envelope instead of
    /// inside `payload`, so every cached `linesAdded` was zero.
    /// v3: usage seen before a file's first `turn_context` was attributed to an
    /// "unknown" model, which showed a bogus row and priced those tokens at zero.
    /// v4: a resumed session's rollout file replays every earlier `token_count`
    /// event, so summing each file's own per-file totals across a session's
    /// files multiplied shared history by the number of files. Cached files now
    /// carry raw `tokenObservations` instead, deduplicated across a session's
    /// files before being turned into deltas.
    private static let currentVersion = 4

    private var files: [String: CodexRolloutAggregate] = [:]
    private var loaded = false

    private static let cacheURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("CCSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("codex-session-cache.json")
    }()

    private static var sessionsRoot: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
    }

    private struct ScanResult {
        let seenPaths: Set<String>
        let updates: [String: CodexRolloutAggregate]
        let reparsed: Int
    }

    /// Synchronous, non-actor-isolated walk. `FileManager.enumerator`'s
    /// `Sequence` conformance (`for-in`) is unavailable from async contexts
    /// under Swift 6 strict concurrency, so — as in `SessionParseCacheV2` —
    /// the walk lives in a plain static function driven by `nextObject()`,
    /// and only its result crosses back onto the actor.
    private static func scan(root: String, cachedMtimes: [String: Double]) -> ScanResult {
        var seen: Set<String> = []
        var updates: [String: CodexRolloutAggregate] = [:]
        var reparsed = 0

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return ScanResult(seenPaths: [], updates: [:], reparsed: 0) }

        while let url = walker.nextObject() as? URL {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }

            let path = url.path
            seen.insert(path)
            let mtime = modified.timeIntervalSince1970

            if let cachedMtime = cachedMtimes[path], cachedMtime == mtime { continue }

            if let aggregate = CodexRolloutParser.parse(contentsOf: path, relativePath: name, mtime: mtime) {
                updates[path] = aggregate
                reparsed += 1
            }
        }

        return ScanResult(seenPaths: seen, updates: updates, reparsed: reparsed)
    }

    /// Walk the tree, re-parsing only files whose mtime changed. Runs on the
    /// actor's executor, which is on the cooperative pool rather than the main
    /// thread, so awaiting this never blocks the UI.
    func refreshFromFilesystem() async {
        ensureLoaded()

        let root = Self.sessionsRoot
        guard FileManager.default.fileExists(atPath: root) else {
            log.info("refresh: no sessions directory")
            return
        }

        let start = Date()
        let cachedMtimes: [String: Double] = files.mapValues { $0.mtime }
        let result = Self.scan(root: root, cachedMtimes: cachedMtimes)

        for (path, aggregate) in result.updates { files[path] = aggregate }

        // Drop entries for files the user archived or deleted, otherwise their
        // costs haunt the totals forever.
        let removed = files.keys.filter { !result.seenPaths.contains($0) }
        for path in removed { files.removeValue(forKey: path) }

        log.info("refresh: \(result.seenPaths.count) files, \(result.reparsed) reparsed, \(removed.count) dropped in \(Int(Date().timeIntervalSince(start) * 1000))ms")
        save()
    }

    /// Cost per day, priced with the current LiteLLM table. Prices are resolved
    /// in a single hop so a concurrent pricing reload cannot mix old and new
    /// rates into one answer.
    func costSeries() async -> CostSeriesModel {
        ensureLoaded()
        let tokensByDayAndModel = Self.mergedTokensByDayAndModel(from: Array(files.values))

        // `sessions` counts distinct rollout files with any usage on a date —
        // one file is one Codex session, matching what the Claude side reports.
        // Unaffected by the session-aware dedup below: it's a file count, not a
        // token sum.
        var byDate: [String: (cost: Double, models: [String: Double], totals: CodexTokenTotals, sessions: Int)] = [:]
        for aggregate in files.values {
            for day in Set(aggregate.tokenObservationRuns.map(\.day)) {
                byDate[day, default: (0, [:], CodexTokenTotals(), 0)].sessions += 1
            }
        }

        var modelIds: Set<String> = []
        for (_, models) in tokensByDayAndModel { modelIds.formUnion(models.keys) }

        let pricingService = PricingService.shared
        await pricingService.ensureLoaded()
        let prices = await pricingService.prices(for: Array(modelIds))

        for (date, models) in tokensByDayAndModel {
            var entry = byDate[date] ?? (0, [:], CodexTokenTotals(), 0)
            for (model, totals) in models {
                let cost = (prices[model] ?? nil)?.openAICost(
                    inputTokens: totals.inputTokens,
                    cachedInputTokens: totals.cachedInputTokens,
                    cacheWriteTokens: totals.cacheWriteTokens,
                    outputTokens: totals.outputTokens
                ) ?? 0
                entry.cost += cost
                entry.models[model, default: 0] += cost
                entry.totals = entry.totals + totals
            }
            byDate[date] = entry
        }

        let today = Formatters.isoDay.string(from: Date())
        let daily = byDate
            .map { date, entry in
                DailyCostEntry(
                    date: date,
                    cost: entry.cost,
                    sessionCount: entry.sessions,
                    modelBreakdown: entry.models,
                    inputTokens: entry.totals.inputTokens,
                    outputTokens: entry.totals.outputTokens,
                    cacheWriteTokens: entry.totals.cacheWriteTokens,
                    cacheReadTokens: entry.totals.cachedInputTokens
                )
            }
            .sorted { $0.date > $1.date }

        return CostSeriesModel(todayCost: byDate[today]?.cost ?? 0, daily: daily)
    }

    /// Deltas per day and model, deduplicated across every rollout file of the
    /// same session. A resumed or subagent file replays earlier `token_count`
    /// events verbatim, so naively summing each file's own per-file totals (as
    /// this used to do) multiplies shared history by however many files the
    /// session has — one real session measured 44 files sharing one
    /// `session_id`, inflating a day's tokens by roughly 24x.
    ///
    /// A free function of the aggregates rather than a method reading `files`,
    /// so it's directly unit-testable without touching the on-disk cache.
    /// Static members of an actor aren't actor-isolated, so this needs no await.
    static func mergedTokensByDayAndModel(from aggregates: [CodexRolloutAggregate]) -> [String: [String: CodexTokenTotals]] {
        var bySession: [String: [CodexTokenObservation]] = [:]
        for (index, aggregate) in aggregates.enumerated() {
            // An aggregate without a session_id (shouldn't happen, but parsing
            // is best-effort) falls back to a key unique to it, i.e. no
            // cross-file merge — the same as today's behavior for that file.
            let flattened = aggregate.tokenObservationRuns.flatMap { run in
                run.cumulatives.map { CodexTokenObservation(day: run.day, model: run.model, cumulative: $0) }
            }
            bySession[aggregate.sessionId ?? "unkeyed-\(index)", default: []].append(contentsOf: flattened)
        }

        var result: [String: [String: CodexTokenTotals]] = [:]
        for observations in bySession.values {
            // Two files of the same session see identical cumulative snapshots
            // for shared history — dedup on the snapshot itself, then sort by
            // its magnitude to recover the session-wide chronology before
            // diffing. (Sorting by magnitude rather than timestamp is safe here
            // because a session's counter only ever grows; per-file timestamp
            // handling for the rare within-file counter reset stays in
            // `CodexRolloutParser`.)
            var seen: Set<CodexTokenTotals> = []
            let unique = observations
                .filter { seen.insert($0.cumulative).inserted }
                .sorted { $0.cumulative.totalBillableTokens < $1.cumulative.totalBillableTokens }

            var previous: CodexTokenTotals?
            for observation in unique {
                defer { previous = observation.cumulative }
                guard let base = previous,
                      let delta = CodexRolloutParser.difference(observation.cumulative, minus: base) else { continue }
                var models = result[observation.day] ?? [:]
                models[observation.model] = (models[observation.model] ?? CodexTokenTotals()) + delta
                result[observation.day] = models
            }
        }
        return result
    }

    /// Today's activity. Per-file active minutes are summed, which means
    /// parallel sessions stack — the same approximation the Claude parser makes
    /// and the same one the UI tooltip already describes.
    func activityToday() -> ActivitySummaryModel {
        ensureLoaded()
        let today = Formatters.isoDay.string(from: Date())

        var turns = 0
        var minutes = 0
        var lines = 0
        var perModelTokens: [String: Int] = [:]

        for aggregate in files.values {
            turns += aggregate.turns[today] ?? 0
            minutes += aggregate.activeMinutes[today] ?? 0
            lines += aggregate.linesAdded[today] ?? 0
        }
        for (model, totals) in Self.mergedTokensByDayAndModel(from: Array(files.values))[today] ?? [:] {
            // Output tokens are the closest Codex analogue to "how much did
            // this model actually produce today".
            perModelTokens[model, default: 0] += totals.outputTokens
        }

        let entries = perModelTokens
            .sorted { $0.value > $1.value }
            .map { ModelUsageEntry(displayName: $0.key, count: $0.value, tint: CodexDisplayMapper.tint(forModel: $0.key)) }

        return ActivitySummaryModel(
            turns: turns,
            activeTimeText: Self.durationText(minutes: minutes),
            linesWritten: lines,
            perModel: entries
        )
    }

    /// Newest `rate_limits` block across all files, for the offline fallback.
    func latestLocalSnapshot() -> (snapshot: CodexRateLimitSnapshot, observedAt: Date)? {
        ensureLoaded()
        var best: (CodexRateLimitSnapshot, Double)?
        for aggregate in files.values {
            guard let snapshot = aggregate.latestSnapshot else { continue }
            if best == nil || aggregate.latestEventAt > best!.1 {
                best = (snapshot, aggregate.latestEventAt)
            }
        }
        return best.map { ($0.0, Date(timeIntervalSince1970: $0.1)) }
    }

    // MARK: - Disk I/O

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.currentVersion else {
            log.info("ensureLoaded: no usable cache, starting empty")
            return
        }
        files = envelope.files
        log.info("ensureLoaded: \(files.count) cached files")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Envelope(version: Self.currentVersion, files: files)) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    private static func durationText(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
    }
}
