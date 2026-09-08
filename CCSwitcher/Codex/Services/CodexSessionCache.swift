import Foundation

private let log = FileLog("CodexCache")

/// One day's turns/lines/active-minutes, already deduplicated across a
/// session's replayed rollout files. See `CodexSessionCache.mergedActivityByDay`.
struct CodexActivityTotals: Sendable {
    var turns: Int = 0
    var linesAdded: Int = 0
    var activeMinutes: Int = 0
}

/// Incrementally aggregates active and archived rollout files from selected homes.
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
    /// v5: `turns`, `linesAdded` and `activeMinutes` had the same defect as
    /// tokens above — a replayed rollout file's `task_started`/`apply_patch`
    /// events and its every-event timestamps were summed per file instead of
    /// deduplicated per session. Cached files now carry the raw
    /// `turnTimestampsByDay`/`patchEventsByDay`/`activeMinuteBucketsByDay`
    /// needed to dedup those, same shape as v4's token fix.
    /// v6: request deltas and timestamp identities replace magnitude-sorted
    /// cumulative counters, which merged independent agent usage incorrectly.
    /// v7: stable turn identities deduplicate fork replay with rewritten timestamps.
    private static let currentVersion = 7

    private var files: [String: CodexRolloutAggregate] = [:]
    private var loaded = false

    private static let defaultCacheURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("CCSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("codex-session-cache.json")
    }()

    private let sessionsRoots: [String]
    private let cacheURL: URL

    init(sessionsRoot: String = NSHomeDirectory() + "/.codex/sessions", cacheURL: URL? = nil) {
        self.sessionsRoots = [sessionsRoot, URL(fileURLWithPath: sessionsRoot).deletingLastPathComponent().appendingPathComponent("archived_sessions").path]
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
    }

    init(sessionRoots: [String], cacheURL: URL) {
        self.sessionsRoots = sessionRoots
        self.cacheURL = cacheURL
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

            let parsed = autoreleasepool {
                CodexRolloutParser.parse(contentsOf: path, relativePath: name, mtime: mtime)
            }
            if let aggregate = parsed {
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

        let start = Date()
        let cachedMtimes: [String: Double] = files.mapValues { $0.mtime }
        var seen: Set<String> = []
        var updates: [String: CodexRolloutAggregate] = [:]
        var reparsed = 0
        for root in sessionsRoots {
            let scan = Self.scan(root: root, cachedMtimes: cachedMtimes)
            seen.formUnion(scan.seenPaths)
            updates.merge(scan.updates) { _, new in new }
            reparsed += scan.reparsed
        }
        let result = ScanResult(seenPaths: seen, updates: updates, reparsed: reparsed)

        for (path, aggregate) in result.updates { files[path] = aggregate }

        // Archiving moves a file between scanned roots; only deleted files disappear.
        let removed = files.keys.filter { !result.seenPaths.contains($0) }
        for path in removed { files.removeValue(forKey: path) }

        log.info("refresh: \(result.seenPaths.count) files, \(result.reparsed) reparsed, \(removed.count) dropped in \(Int(Date().timeIntervalSince(start) * 1000))ms")
        save()
    }

    func releaseResidentData() {
        files = [:]
        loaded = false
    }

    func residentFileCount() -> Int { files.count }

    /// Cost per day, priced with the current LiteLLM table. Prices are resolved
    /// in a single hop so a concurrent pricing reload cannot mix old and new
    /// rates into one answer.
    func costSeries() async -> CostSeriesModel {
        ensureLoaded()
        let usageEvents = Self.mergedUsageEvents(from: Array(files.values))

        // Copied/resumed files do not create extra sessions in the history.
        var byDate: [String: (cost: Double, models: [String: Double], totals: CodexTokenTotals, sessions: Int)] = [:]
        var sessionsByDay: [String: Set<String>] = [:]
        for (path, aggregate) in files {
            for day in Set(aggregate.usageEvents.map(\.day)) {
                sessionsByDay[day, default: []].insert(aggregate.sessionId ?? path)
            }
        }
        for (day, sessions) in sessionsByDay {
            byDate[day, default: (0, [:], CodexTokenTotals(), 0)].sessions = sessions.count
        }

        var modelIds: Set<String> = []
        modelIds.formUnion(usageEvents.map(\.model))

        let pricingService = PricingService.shared
        await pricingService.ensureLoaded()
        let prices = await pricingService.prices(for: Array(modelIds))

        for event in usageEvents {
            let date = event.day
            var entry = byDate[date] ?? (0, [:], CodexTokenTotals(), 0)
            let cost = (prices[event.model] ?? nil)?.openAICost(
                inputTokens: event.delta.inputTokens,
                cachedInputTokens: event.delta.cachedInputTokens,
                cacheWriteTokens: event.delta.cacheWriteTokens,
                outputTokens: event.delta.outputTokens,
                serviceTier: event.serviceTier
            ) ?? 0
            entry.cost += cost
            entry.models[event.model, default: 0] += cost
            entry.totals = entry.totals + event.delta
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
                    inputTokens: max(0, entry.totals.inputTokens - entry.totals.cachedInputTokens),
                    outputTokens: entry.totals.outputTokens,
                    cacheWriteTokens: 0,
                    cacheReadTokens: min(entry.totals.cachedInputTokens, entry.totals.inputTokens)
                )
            }
            .sorted { $0.date > $1.date }

        let unpriced = modelIds.filter { (prices[$0] ?? nil) == nil }.sorted()
        return CostSeriesModel(
            todayCost: byDate[today]?.cost ?? 0,
            daily: daily,
            unpricedModels: unpriced,
            hasUnknownServiceTiers: usageEvents.contains { $0.serviceTier == .unknown }
        )
    }

    /// Deduplicate replayed events, not whole counter curves: agents sharing
    /// a session ID still have independent request usage and counter resets.
    static func mergedTokensByDayAndModel(from aggregates: [CodexRolloutAggregate]) -> [String: [String: CodexTokenTotals]] {
        let requests = mergedUsageEvents(from: aggregates)
        var result: [String: [String: CodexTokenTotals]] = [:]
        for event in requests {
            result[event.day, default: [:]][event.model, default: CodexTokenTotals()] =
                (result[event.day]?[event.model] ?? CodexTokenTotals()) + event.delta
        }
        return result
    }

    static func mergedUsageEvents(from aggregates: [CodexRolloutAggregate]) -> [CodexUsageEvent] {
        struct EventKey: Hashable {
            let session: String
            let scope: String?
            let timestamp: Double
            let cumulative: CodexTokenTotals
        }
        var events: [EventKey: CodexUsageEvent] = [:]
        for (index, aggregate) in aggregates.enumerated() {
            for event in aggregate.usageEvents {
                let key = EventKey(session: aggregate.sessionId ?? "unkeyed-\(index)", scope: event.requestScope,
                                   timestamp: event.timestamp, cumulative: event.cumulative)
                // Replayed history keeps its timestamp and counters. A file
                // beginning mid-history may only know the last request's delta.
                if var existing = events[key] {
                    if event.delta.totalBillableTokens == 0 {
                        existing.delta = event.delta
                    } else if existing.delta.totalBillableTokens > 0,
                              event.delta.totalBillableTokens > existing.delta.totalBillableTokens {
                        existing.delta = event.delta
                    }
                    if existing.model == "unknown" || (event.model != "unknown" && event.model < existing.model) {
                        existing.model = event.model
                    }
                    if existing.serviceTier == .unknown, event.serviceTier != .unknown {
                        existing.serviceTier = event.serviceTier
                    }
                    events[key] = existing
                    continue
                }
                events[key] = event
            }
        }
        struct RequestKey: Hashable {
            let session: String
            let scope: String?
            let cumulative: CodexTokenTotals
            let delta: CodexTokenTotals
        }
        var requests: [RequestKey: CodexUsageEvent] = [:]
        for (key, event) in events {
            guard event.delta.totalBillableTokens > 0 else { continue }
            let requestKey = RequestKey(session: key.session, scope: key.scope, cumulative: event.cumulative, delta: event.delta)
            if var existing = requests[requestKey] {
                // Fork replay rewrites timestamps but preserves turn IDs and counters.
                if event.timestamp < existing.timestamp {
                    existing.timestamp = event.timestamp
                    existing.day = event.day
                }
                if existing.model == "unknown" || (event.model != "unknown" && event.model < existing.model) {
                    existing.model = event.model
                }
                if existing.serviceTier == .unknown, event.serviceTier != .unknown {
                    existing.serviceTier = event.serviceTier
                }
                requests[requestKey] = existing
            } else {
                requests[requestKey] = event
            }
        }
        return Array(requests.values)
    }

    /// Legacy activity heuristic: collapses replays that preserve timestamps
    /// and patch call IDs. Unlike request accounting, it cannot fully resolve
    /// retimestamped history and is not an exact measure of work duration.
    static func mergedActivityByDay(from aggregates: [CodexRolloutAggregate]) -> [String: CodexActivityTotals] {
        struct SessionDay {
            var turnStamps: Set<Double> = []
            var patchLinesById: [String: Int] = [:]
            var activeMinuteBuckets: Set<Int> = []
        }

        var bySession: [String: [String: SessionDay]] = [:]
        for (index, aggregate) in aggregates.enumerated() {
            let sessionKey = aggregate.sessionId ?? "unkeyed-\(index)"
            var days = bySession[sessionKey] ?? [:]

            for (day, stamps) in aggregate.turnTimestampsByDay {
                days[day, default: SessionDay()].turnStamps.formUnion(stamps)
            }
            for (day, events) in aggregate.patchEventsByDay {
                var entry = days[day] ?? SessionDay()
                for event in events { entry.patchLinesById[event.id] = event.lines }
                days[day] = entry
            }
            for (day, buckets) in aggregate.activeMinuteBucketsByDay {
                days[day, default: SessionDay()].activeMinuteBuckets.formUnion(buckets)
            }

            bySession[sessionKey] = days
        }

        var result: [String: CodexActivityTotals] = [:]
        for days in bySession.values {
            for (day, sessionDay) in days {
                var totals = result[day] ?? CodexActivityTotals()
                totals.turns += sessionDay.turnStamps.count
                totals.linesAdded += sessionDay.patchLinesById.values.reduce(0, +)
                // Minute buckets stand in for exact timestamps here — see
                // `activeMinuteBucketsByDay` — so gaps are computed between
                // bucket starts rather than raw event times.
                let bucketDates = sessionDay.activeMinuteBuckets
                    .map { Date(timeIntervalSince1970: Double($0) * 60) }
                totals.activeMinutes += CodexRolloutParser.activeMinutes(bucketDates)
                result[day] = totals
            }
        }
        return result
    }

    /// Today's activity, deduplicated per session across replayed rollout files.
    func activityToday() -> ActivitySummaryModel {
        ensureLoaded()
        let today = Formatters.isoDay.string(from: Date())

        let activity = Self.mergedActivityByDay(from: Array(files.values))[today] ?? CodexActivityTotals()
        var perModelTokens: [String: Int] = [:]

        for (model, totals) in Self.mergedTokensByDayAndModel(from: Array(files.values))[today] ?? [:] {
            // Output tokens are the closest Codex analogue to "how much did
            // this model actually produce today".
            perModelTokens[model, default: 0] += totals.outputTokens
        }

        let entries = perModelTokens
            .sorted { $0.value > $1.value }
            .map { ModelUsageEntry(displayName: $0.key, count: $0.value, tint: CodexDisplayMapper.tint(forModel: $0.key)) }

        return ActivitySummaryModel(
            turns: activity.turns,
            activeTimeText: Self.durationText(minutes: activity.activeMinutes),
            linesWritten: activity.linesAdded,
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
        guard let data = try? Data(contentsOf: cacheURL),
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
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func durationText(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
    }
}
