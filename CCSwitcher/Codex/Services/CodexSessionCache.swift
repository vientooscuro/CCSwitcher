import Foundation
import Darwin

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
    /// v8: first-request confirmations and response identities affect usage.
    private static let currentVersion = 8

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
    private let seedCacheURLs: [URL]

    init(sessionsRoot: String = NSHomeDirectory() + "/.codex/sessions", cacheURL: URL? = nil) {
        self.sessionsRoots = [sessionsRoot, URL(fileURLWithPath: sessionsRoot).deletingLastPathComponent().appendingPathComponent("archived_sessions").path]
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        self.seedCacheURLs = []
    }

    init(sessionRoots: [String], cacheURL: URL, seedCacheURL: URL? = nil, seedCacheURLs: [URL] = []) {
        self.sessionsRoots = sessionRoots
        self.cacheURL = cacheURL
        self.seedCacheURLs = (seedCacheURL.map { [$0] } ?? []) + seedCacheURLs
    }

    enum FileSelection {
        case all, uncompressed, compressed

        func includes(_ path: String) -> Bool {
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard name.hasPrefix("rollout-") else { return false }
            switch self {
            case .all: return name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")
            case .uncompressed: return name.hasSuffix(".jsonl")
            case .compressed: return name.hasSuffix(".jsonl.zst")
            }
        }
    }

    private struct ScanPlan {
        var validPaths: Set<String> = []
        var pending: [(url: URL, mtime: Double)] = []
        var total = 0
        var failures = 0
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func normalizedFiles(_ files: [String: CodexRolloutAggregate]) -> [String: CodexRolloutAggregate] {
        var result: [String: CodexRolloutAggregate] = [:]
        for (path, aggregate) in files {
            let key = canonicalURL(URL(fileURLWithPath: path)).path
            if let existing = result[key], existing.mtime >= aggregate.mtime { continue }
            result[key] = aggregate
        }
        return result
    }

    /// Validate cached mtimes in one directory walk before publishing cached archives.
    private static func scanPlan(roots: [String], cachedMtimes: [String: Double], selection: FileSelection) -> ScanPlan {
        var plan = ScanPlan()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        for root in roots {
            guard FileManager.default.fileExists(atPath: root) else { continue }
            let rootComponents = canonicalURL(URL(fileURLWithPath: root)).pathComponents
            guard let walker = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                errorHandler: { _, _ in plan.failures += 1; return true }
            ) else {
                plan.failures += 1
                continue
            }
            while let url = walker.nextObject() as? URL {
                if Task.isCancelled { return plan }
                guard selection.includes(url.lastPathComponent) else { continue }
                let canonical = canonicalURL(url)
                let components = canonical.pathComponents
                guard components.count > rootComponents.count, components.starts(with: rootComponents) else { continue }
                plan.total += 1
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, let modified = values.contentModificationDate else {
                    plan.failures += 1
                    continue
                }
                let mtime = modified.timeIntervalSince1970
                if cachedMtimes[canonical.path] == mtime {
                    plan.validPaths.insert(canonical.path)
                } else {
                    plan.pending.append((canonical, mtime))
                }
            }
        }
        plan.pending.sort { $0.mtime > $1.mtime }
        return plan
    }

    /// Each saved batch is reusable after cancellation or an application restart.
    @discardableResult
    func refreshFromFilesystem(selection: FileSelection = .all,
                               progress: (@Sendable (Int, Int) -> Void)? = nil,
                               snapshot: (@Sendable () async -> Void)? = nil) async -> Bool {
        ensureLoaded()
        let start = Date()
        let plan = Self.scanPlan(roots: sessionsRoots, cachedMtimes: files.mapValues { $0.mtime }, selection: selection)
        guard !Task.isCancelled else { return false }
        let removed = files.keys.filter { selection.includes($0) && !plan.validPaths.contains($0) }
        for path in removed { files.removeValue(forKey: path) }
        let invalidatedPaths = Set(removed)
        var processed = plan.total - plan.pending.count
        var failures = plan.failures
        var reparsed = 0
        progress?(processed, plan.total)
        if selection == .compressed {
            save(invalidatedPaths: invalidatedPaths)
            await snapshot?()
            guard !Task.isCancelled else { return false }
        }
        var batchCount = 0
        var checkpointAt = Date()
        var snapshotAt = Date()
        for item in plan.pending {
            guard !Task.isCancelled else { return false }
            let parsed = autoreleasepool {
                CodexRolloutParser.parse(contentsOf: item.url.path, relativePath: item.url.lastPathComponent, mtime: item.mtime)
            }
            guard !Task.isCancelled else { return false }
            if let parsed {
                files[item.url.path] = parsed
                reparsed += 1
            } else {
                failures += 1
            }
            processed += 1
            batchCount += 1
            if batchCount >= 100 || Date().timeIntervalSince(checkpointAt) >= 15 {
                save(invalidatedPaths: invalidatedPaths)
                progress?(processed, plan.total)
                batchCount = 0
                checkpointAt = Date()
                if Date().timeIntervalSince(snapshotAt) >= 15 {
                    await snapshot?()
                    guard !Task.isCancelled else { return false }
                    snapshotAt = Date()
                }
            }
        }
        save(invalidatedPaths: invalidatedPaths)
        progress?(processed, plan.total)
        log.info("refresh: \(plan.total) files, \(reparsed) reparsed, \(removed.count) dropped, \(failures) failed in \(Int(Date().timeIntervalSince(start) * 1000))ms")
        return failures == 0
    }

    func releaseResidentData() {
        files = [:]
        loaded = false
    }

    func residentFileCount() -> Int { files.count }

    /// Cost per day, priced with the current LiteLLM table. Prices are resolved
    /// in a single hop so a concurrent pricing reload cannot mix old and new
    /// rates into one answer.
    func costSeries(selection: FileSelection = .all) async -> CostSeriesModel {
        ensureLoaded()
        let selectedFiles = files.filter { selection.includes($0.key) }
        let usageEvents = Self.mergedUsageEvents(from: Array(selectedFiles.values))

        // Copied/resumed files do not create extra sessions in the history.
        var byDate: [String: (cost: Double, models: [String: Double], totals: CodexTokenTotals, sessions: Int)] = [:]
        var sessionsByDay: [String: Set<String>] = [:]
        for (path, aggregate) in selectedFiles {
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
            let responseID: String?
        }
        var events: [EventKey: CodexUsageEvent] = [:]
        for (index, aggregate) in aggregates.enumerated() {
            for event in aggregate.usageEvents {
                let key = EventKey(session: aggregate.sessionId ?? "unkeyed-\(index)", scope: event.requestScope,
                                   timestamp: event.timestamp, cumulative: event.cumulative, responseID: event.responseID)
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
        func legacyKey(_ key: EventKey, _ event: CodexUsageEvent) -> RequestKey {
            RequestKey(session: key.session, scope: key.scope, cumulative: event.cumulative,
                       delta: event.delta)
        }
        let confirmedSignatures = Set(events.compactMap { key, event in
            event.responseID == nil ? nil : legacyKey(key, event)
        })
        var legacyRequests: [RequestKey: CodexUsageEvent] = [:]
        var confirmedRequests: [String: CodexUsageEvent] = [:]
        for (key, event) in events {
            guard event.delta.totalBillableTokens > 0 else { continue }
            let requestKey = legacyKey(key, event)
            if event.responseID == nil, confirmedSignatures.contains(requestKey) { continue }
            let existingEvent = if let responseID = event.responseID {
                confirmedRequests[responseID]
            } else {
                legacyRequests[requestKey]
            }
            if var existing = existingEvent {
                // Replays may rewrite timestamps; preserve the earliest attribution.
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
                if let responseID = event.responseID {
                    confirmedRequests[responseID] = existing
                } else {
                    legacyRequests[requestKey] = existing
                }
            } else {
                if let responseID = event.responseID {
                    confirmedRequests[responseID] = event
                } else {
                    legacyRequests[requestKey] = event
                }
            }
        }
        return Array(confirmedRequests.values) + Array(legacyRequests.values)
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
    func activityToday(selection: FileSelection = .all) -> ActivitySummaryModel {
        ensureLoaded()
        let today = Formatters.isoDay.string(from: Date())
        let aggregates = files.filter { selection.includes($0.key) }.map(\.value)

        let activity = Self.mergedActivityByDay(from: aggregates)[today] ?? CodexActivityTotals()
        var perModelTokens: [String: Int] = [:]

        for (model, totals) in Self.mergedTokensByDayAndModel(from: aggregates)[today] ?? [:] {
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
        let roots = sessionsRoots.map { Self.canonicalURL(URL(fileURLWithPath: $0)).pathComponents }
        for url in [cacheURL] + seedCacheURLs {
            guard let envelope = Self.loadEnvelope(from: url) else { continue }
            for (path, aggregate) in Self.normalizedFiles(envelope.files) {
                let components = URL(fileURLWithPath: path).pathComponents
                guard roots.contains(where: { components.count > $0.count && components.starts(with: $0) }) else { continue }
                if let existing = files[path], existing.mtime >= aggregate.mtime { continue }
                files[path] = aggregate
            }
        }
        log.info("ensureLoaded: merged \(files.count) cached files")
    }

    private static func loadEnvelope(from url: URL) -> Envelope? {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == currentVersion else { return nil }
        return envelope
    }

    private func save(invalidatedPaths: Set<String>) {
        let lockPath = cacheURL.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { return }
        }
        defer { flock(descriptor, LOCK_UN) }

        let roots = sessionsRoots.map { Self.canonicalURL(URL(fileURLWithPath: $0)).pathComponents }
        if let envelope = Self.loadEnvelope(from: cacheURL) {
            for (path, aggregate) in Self.normalizedFiles(envelope.files) {
                let components = URL(fileURLWithPath: path).pathComponents
                guard roots.contains(where: { components.count > $0.count && components.starts(with: $0) }) else { continue }
                if invalidatedPaths.contains(path) {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                    let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
                    guard mtime == aggregate.mtime else { continue }
                }
                if let existing = files[path], existing.mtime >= aggregate.mtime { continue }
                files[path] = aggregate
            }
        }
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
