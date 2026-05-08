import Foundation

private let fiveHours: TimeInterval = 5 * 60 * 60
private let sevenDays: TimeInterval = 7 * 24 * 60 * 60
private let claudeUsageRetryDelay: TimeInterval = 10 * 60
private let claudeCachedPercentMaxAge: TimeInterval = 12 * 60 * 60

private struct ModelPricing {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
}

private let opusPricing = ModelPricing(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)
private let sonnetPricing = ModelPricing(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
private let haikuPricing = ModelPricing(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1)

private func pricing(for model: String?) -> ModelPricing {
    guard let m = model?.lowercased() else { return sonnetPricing }
    if m.contains("opus") { return opusPricing }
    if m.contains("haiku") { return haikuPricing }
    return sonnetPricing
}

private struct Totals {
    var input: Double = 0
    var output: Double = 0
    var cacheCreate: Double = 0
    var cacheRead: Double = 0
    var cost: Double = 0
    var totalTokens: Double { input + output + cacheCreate + cacheRead }

    mutating func add(_ other: Totals) {
        input += other.input
        output += other.output
        cacheCreate += other.cacheCreate
        cacheRead += other.cacheRead
        cost += other.cost
    }
}

// Per-file entry keyed by (path, mtime). Re-used across refreshes so we only
// re-parse files whose contents actually changed.
struct FileEntry: Sendable {
    let mtime: Date
    let events: [UsageEvent]
}

struct UsageEvent: Sendable {
    let timestamp: Date
    let input: Double
    let output: Double
    let cacheCreate: Double
    let cacheRead: Double
    let cost: Double
}

actor ClaudeFileCache {
    static let shared = ClaudeFileCache()
    private var entries: [String: FileEntry] = [:]

    func events(for url: URL, mtime: Date) async -> [UsageEvent] {
        let key = url.path
        if let cached = entries[key], cached.mtime == mtime {
            return cached.events
        }
        let events = await parseFile(url)
        entries[key] = FileEntry(mtime: mtime, events: events)
        return events
    }

    func prune(keeping validKeys: Set<String>) {
        entries = entries.filter { validKeys.contains($0.key) }
    }

    private func parseFile(_ url: URL) async -> [UsageEvent] {
        var out: [UsageEvent] = []
        out.reserveCapacity(64)
        let retentionCutoff = Date().addingTimeInterval(-(sevenDays + 60 * 60))
        do {
            for try await line in url.lines {
                if line.isEmpty { continue }
                // NSDictionary from JSONSerialization lives in the autorelease
                // pool; without draining, 200k+ lines pile up and multiply RSS.
                let event: UsageEvent? = autoreleasepool {
                    parseClaudeLine(line, retentionCutoff: retentionCutoff)
                }
                if let event { out.append(event) }
            }
        } catch {
            // Incomplete / unreadable file — return what we have.
        }
        return out
    }
}

// Remembers the last successful OAuth result for each provider so that a
// transient 429 / network blip doesn't blow away a good display.
actor OAuthSnapshotCache {
    static let shared = OAuthSnapshotCache(storageURL: defaultStorageURL())
    private var lastGood: [ProviderUsage.ID: (usage: ProviderUsage, at: Date)] = [:]
    private let storageURL: URL?
    private var loadedFromDisk = false

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL
    }

    func store(_ usage: ProviderUsage) {
        loadFromDiskIfNeeded()
        lastGood[usage.id] = (usage, Date())
        saveToDisk()
    }

    func recent(_ id: ProviderUsage.ID, maxAge: TimeInterval) -> ProviderUsage? {
        loadFromDiskIfNeeded()
        guard let entry = lastGood[id] else { return nil }
        if Date().timeIntervalSince(entry.at) > maxAge { return nil }
        return entry.usage
    }

    private static func defaultStorageURL() -> URL? {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("AIUsageBar", isDirectory: true)
            .appendingPathComponent("oauth-snapshots.json")
    }

    private func loadFromDiskIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let storageURL,
              let data = try? Data(contentsOf: storageURL),
              let stored = try? JSONDecoder().decode(StoredOAuthSnapshots.self, from: data)
        else { return }

        for (rawID, entry) in stored.entries {
            guard let id = ProviderUsage.ID(rawValue: rawID),
                  let usage = entry.providerUsage(id: id)
            else { continue }
            lastGood[id] = (usage, entry.at)
        }
    }

    private func saveToDisk() {
        guard let storageURL else { return }
        let entries = Dictionary(
            uniqueKeysWithValues: lastGood.map { id, entry in
                (id.rawValue, StoredOAuthSnapshotEntry(usage: entry.usage, at: entry.at))
            }
        )
        let stored = StoredOAuthSnapshots(entries: entries)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            // Cache persistence is best-effort; live reads and local fallback still work.
        }
    }
}

actor ClaudeUsageBackoff {
    static let shared = ClaudeUsageBackoff(duration: claudeUsageRetryDelay)

    private let duration: TimeInterval
    private var blockedUntil: Date?

    init(duration: TimeInterval) {
        self.duration = duration
    }

    func canAttempt(now: Date = Date()) -> Bool {
        guard let blockedUntil else { return true }
        return now >= blockedUntil
    }

    func retryAfter(now: Date = Date()) -> TimeInterval? {
        guard let blockedUntil else { return nil }
        return max(0, blockedUntil.timeIntervalSince(now))
    }

    func recordRateLimit(now: Date = Date()) {
        blockedUntil = now.addingTimeInterval(duration)
    }

    func reset() {
        blockedUntil = nil
    }
}

private struct StoredOAuthSnapshots: Codable {
    let entries: [String: StoredOAuthSnapshotEntry]
}

private struct StoredOAuthSnapshotEntry: Codable {
    let at: Date
    let name: String
    let status: String
    let message: String?
    let bars: [StoredUsageBar]
    let meta: [StoredMetaItem]

    init(usage: ProviderUsage, at: Date) {
        self.at = at
        name = usage.name
        status = usage.status.rawValue
        message = usage.message
        bars = usage.bars.map(StoredUsageBar.init)
        meta = usage.meta.map { StoredMetaItem(key: $0.0, value: $0.1) }
    }

    func providerUsage(id: ProviderUsage.ID) -> ProviderUsage? {
        guard let status = ProviderStatus(rawValue: status) else { return nil }
        return ProviderUsage(
            id: id,
            name: name,
            status: status,
            message: message,
            bars: bars.map { $0.usageBar },
            meta: meta.map { ($0.key, $0.value) }
        )
    }
}

private struct StoredUsageBar: Codable {
    let label: String
    let percent: Double?
    let used: Double
    let limit: Double?
    let unit: String
    let resetsAt: Date?

    init(_ bar: UsageBar) {
        label = bar.label
        percent = bar.percent
        used = bar.used
        limit = bar.limit
        unit = bar.unit
        resetsAt = bar.resetsAt
    }

    var usageBar: UsageBar {
        UsageBar(
            label: label,
            percent: percent,
            used: used,
            limit: limit,
            unit: unit,
            resetsAt: resetsAt
        )
    }
}

private struct StoredMetaItem: Codable {
    let key: String
    let value: String
}

enum UsageReader {

    static func snapshot(allowingCredentialPrompts: Bool = true) async -> UsageSnapshot {
        async let claude = readClaude(allowingCredentialPrompts: allowingCredentialPrompts)
        async let codex = readCodex()
        let providers = await [claude, codex]
        return UsageSnapshot(fetchedAt: Date(), providers: providers)
    }

    // MARK: Claude

    private static func readClaude(allowingCredentialPrompts: Bool) async -> ProviderUsage {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let claudeDirExists = FileManager.default.fileExists(atPath: claudeDir.path)

        let credentials: OAuthCredentials
        do {
            credentials = try await ClaudeCredentialCache.shared.credentials(
                allowUserInteraction: allowingCredentialPrompts
            ) { allowUserInteraction in
                try KeychainReader.loadCredentials(allowUserInteraction: allowUserInteraction)
            }
        } catch OAuthLoadError.interactionNotAllowed {
            return await claudeWithoutOAuth(
                claudeDir: claudeDir,
                claudeDirExists: claudeDirExists,
                message: "Claude keychain access needs approval — open the menu to allow once."
            )
        } catch {
            // No OAuth token available — offline-only fallback.
            return await claudeWithoutOAuth(
                claudeDir: claudeDir,
                claudeDirExists: claudeDirExists,
                message: nil
            )
        }

        if !(await ClaudeUsageBackoff.shared.canAttempt()) {
            return await claudePercentageUnavailable(
                credentials: credentials,
                reason: "Claude usage percentage is rate-limited"
            )
        }

        do {
            let resp = try await ClaudeOAuthClient.fetchUsage(accessToken: credentials.accessToken)
            await ClaudeUsageBackoff.shared.reset()
            let usage = claudeFromOAuth(resp, credentials: credentials)
            await OAuthSnapshotCache.shared.store(usage)
            return usage
        } catch OAuthFetchError.unauthorized {
            return await refreshClaudeCredentialsAndRetryUsage(credentials)
        } catch let OAuthFetchError.http(code) where code == 429 {
            await ClaudeUsageBackoff.shared.recordRateLimit()
            return await claudePercentageUnavailable(
                credentials: credentials,
                reason: "Claude usage percentage is rate-limited"
            )
        } catch {
            return await withTransientNote(
                providerID: .claude, name: "Claude Code",
                credentials: credentials, error: error
            )
        }
    }

    private static func refreshClaudeCredentialsAndRetryUsage(
        _ credentials: OAuthCredentials
    ) async -> ProviderUsage {
        do {
            let refreshed = try await ClaudeOAuthRefreshClient.refresh(credentials)
            try? KeychainReader.saveCredentials(refreshed)
            await ClaudeCredentialCache.shared.store(refreshed)

            let resp = try await ClaudeOAuthClient.fetchUsage(accessToken: refreshed.accessToken)
            await ClaudeUsageBackoff.shared.reset()
            let usage = claudeFromOAuth(resp, credentials: refreshed)
            await OAuthSnapshotCache.shared.store(usage)
            return usage
        } catch let OAuthFetchError.http(code) where code == 429 {
            await ClaudeUsageBackoff.shared.recordRateLimit()
            return await claudePercentageUnavailable(
                credentials: credentials,
                reason: "Claude usage percentage is rate-limited"
            )
        } catch let OAuthRefreshError.http(code) where code == 429 {
            await ClaudeUsageBackoff.shared.recordRateLimit()
            return await claudePercentageUnavailable(
                credentials: credentials,
                reason: "Claude token refresh is rate-limited"
            )
        } catch {
            await ClaudeCredentialCache.shared.invalidate()
            return ProviderUsage(
                id: .claude, name: "Claude Code", status: .error,
                message: "Claude token refresh failed — run `claude` to re-auth.",
                bars: [], meta: planMeta(credentials: credentials)
            )
        }
    }

    private static func claudeWithoutOAuth(
        claudeDir: URL,
        claudeDirExists: Bool,
        message: String?
    ) async -> ProviderUsage {
        if var cached = await recentClaudePercentageSnapshot(maxAge: claudeCachedPercentMaxAge) {
            let fallbackMessage: String
            if let message {
                fallbackMessage = "\(message) Showing last good snapshot."
            } else {
                fallbackMessage = "Claude OAuth unavailable — showing cached percentage."
            }
            cached = ProviderUsage(
                id: cached.id, name: cached.name, status: .stale,
                message: fallbackMessage,
                bars: cached.bars, meta: cached.meta
            )
            return cached
        }

        if !claudeDirExists {
            return ProviderUsage(
                id: .claude, name: "Claude Code",
                status: .unavailable,
                message: "~/.claude not found — run Claude Code once.",
                bars: [], meta: []
            )
        }

        if let message {
            let local = await claudeFromLocalScan(claudeDir: claudeDir)
            return ProviderUsage(
                id: local.id, name: local.name, status: local.status,
                message: message,
                bars: local.bars, meta: local.meta
            )
        }

        return await claudeFromLocalScan(claudeDir: claudeDir)
    }

    private static func claudePercentageUnavailable(
        credentials: OAuthCredentials,
        reason: String
    ) async -> ProviderUsage {
        let retry = await ClaudeUsageBackoff.shared.retryAfter()
        let retryText = retry.map { " Retrying in \(formatDuration($0))." } ?? ""

        if var cached = await recentClaudePercentageSnapshot(maxAge: claudeCachedPercentMaxAge) {
            cached = ProviderUsage(
                id: cached.id, name: cached.name, status: .stale,
                message: "\(reason) — showing cached percentage.\(retryText)",
                bars: cached.bars, meta: cached.meta
            )
            return cached
        }

        return ProviderUsage(
            id: .claude,
            name: "Claude Code",
            status: .error,
            message: "\(reason). Waiting for Anthropic usage API to return percent.\(retryText)",
            bars: [],
            meta: planMeta(credentials: credentials)
        )
    }

    private static func recentClaudePercentageSnapshot(maxAge: TimeInterval) async -> ProviderUsage? {
        guard var cached = await OAuthSnapshotCache.shared.recent(.claude, maxAge: maxAge),
              cached.bars.contains(where: { $0.percent != nil })
        else { return nil }

        cached = ProviderUsage(
            id: cached.id,
            name: cached.name,
            status: .stale,
            message: cached.message,
            bars: cached.bars,
            meta: cached.meta
        )
        return cached
    }

    private static func withTransientNote(
        providerID: ProviderUsage.ID,
        name: String,
        credentials: OAuthCredentials,
        error: Error
    ) async -> ProviderUsage {
        if providerID == .claude,
           var cached = await recentClaudePercentageSnapshot(maxAge: claudeCachedPercentMaxAge) {
            cached = ProviderUsage(
                id: cached.id, name: cached.name, status: .stale,
                message: "Network error — showing cached percentage.",
                bars: cached.bars, meta: cached.meta
            )
            return cached
        }

        if var cached = await OAuthSnapshotCache.shared.recent(providerID, maxAge: 600) {
            cached = ProviderUsage(
                id: cached.id, name: cached.name, status: .stale,
                message: "Network error — showing last good snapshot.",
                bars: cached.bars, meta: cached.meta
            )
            return cached
        }
        return ProviderUsage(
            id: providerID, name: name, status: .error,
            message: "Fetch failed: \(error).",
            bars: [], meta: planMeta(credentials: credentials)
        )
    }

    private static func claudeFromOAuth(
        _ resp: OAuthUsageResponse,
        credentials: OAuthCredentials
    ) -> ProviderUsage {
        let fiveHour = resp.fiveHour
        let sevenDay = resp.sevenDay
        var bars: [UsageBar] = []
        if let five = fiveHour {
            bars.append(UsageBar(
                label: "5h session",
                percent: five.utilization,
                used: five.utilization ?? 0,
                limit: 100,
                unit: "%",
                resetsAt: five.resetsAt
            ))
        }
        if let seven = sevenDay {
            bars.append(UsageBar(
                label: "7 days",
                percent: seven.utilization,
                used: seven.utilization ?? 0,
                limit: 100,
                unit: "%",
                resetsAt: seven.resetsAt
            ))
        }
        var meta = planMeta(credentials: credentials)
        if let pace = hourlyBudget(percent: sevenDay?.utilization, resetsAt: sevenDay?.resetsAt) {
            meta.append(("7d budget", pace))
        }
        return ProviderUsage(
            id: .claude,
            name: "Claude Code",
            status: .ok,
            message: nil,
            bars: bars,
            meta: meta
        )
    }

    // Ideal per-hour spend to consume exactly the remaining quota by reset.
    // Returns nil when it doesn't apply (already full, reset in the past).
    private static func hourlyBudget(percent: Double?, resetsAt: Date?) -> String? {
        guard let percent, let resetsAt else { return nil }
        let remaining = 100 - percent
        let hours = resetsAt.timeIntervalSinceNow / 3600
        guard remaining > 0, hours > 0 else { return nil }
        let rate = remaining / hours
        if rate >= 10 { return String(format: "%.0f%%/h", rate) }
        if rate >= 1 { return String(format: "%.1f%%/h", rate) }
        return String(format: "%.2f%%/h", rate)
    }

    private static func planMeta(credentials: OAuthCredentials) -> [(String, String)] {
        var out: [(String, String)] = []
        if let sub = credentials.subscriptionType {
            out.append(("plan", sub.capitalized))
        }
        if let tier = credentials.rateLimitTier {
            out.append(("tier", tier))
        }
        return out
    }

    private static func claudeFromLocalScan(claudeDir: URL) async -> ProviderUsage {
        let projectsDir = claudeDir.appendingPathComponent("projects", isDirectory: true)
        let recents = findRecentJsonl(in: projectsDir, within: sevenDays)
        await ClaudeFileCache.shared.prune(keeping: Set(recents.map { $0.url.path }))

        let now = Date()
        let fiveHCutoff = now.addingTimeInterval(-fiveHours)
        let sevenDCutoff = now.addingTimeInterval(-sevenDays)

        var session = Totals()
        var weekly = Totals()

        for entry in recents {
            let events = await ClaudeFileCache.shared.events(for: entry.url, mtime: entry.mtime)
            for ev in events where ev.timestamp >= sevenDCutoff {
                weekly.input += ev.input
                weekly.output += ev.output
                weekly.cacheCreate += ev.cacheCreate
                weekly.cacheRead += ev.cacheRead
                weekly.cost += ev.cost
                if ev.timestamp >= fiveHCutoff {
                    session.input += ev.input
                    session.output += ev.output
                    session.cacheCreate += ev.cacheCreate
                    session.cacheRead += ev.cacheRead
                    session.cost += ev.cost
                }
            }
        }

        return ProviderUsage(
            id: .claude,
            name: "Claude Code",
            status: .ok,
            message: "Offline estimate — run `claude` to enable utilization %.",
            bars: [
                UsageBar(
                    label: "5h session",
                    percent: nil,
                    used: session.totalTokens,
                    limit: nil,
                    unit: "tokens",
                    resetsAt: nil
                ),
                UsageBar(
                    label: "7 days",
                    percent: nil,
                    used: weekly.totalTokens,
                    limit: nil,
                    unit: "tokens",
                    resetsAt: nil
                ),
            ],
            meta: [
                ("session cost", String(format: "$%.2f", session.cost)),
                ("7d cost", String(format: "$%.2f", weekly.cost)),
            ]
        )
    }

    private struct RecentFile {
        let url: URL
        let mtime: Date
    }

    private static func findRecentJsonl(in root: URL, within interval: TimeInterval) -> [RecentFile] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        let cutoff = Date().addingTimeInterval(-interval)
        var out: [RecentFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified >= cutoff
            else { continue }
            out.append(RecentFile(url: url, mtime: modified))
        }
        return out
    }

    // MARK: Codex

    private static func readCodex() async -> ProviderUsage {
        // Primary path: ChatGPT backend `wham/usage` endpoint (what CodexBar uses)
        // reading the OAuth token from ~/.codex/auth.json.
        if let creds = CodexAuthReader.loadCredentials() {
            do {
                let resp = try await CodexOAuthClient.fetchUsage(credentials: creds)
                let usage = codexFromOAuth(resp)
                await OAuthSnapshotCache.shared.store(usage)
                return usage
            } catch CodexFetchError.unauthorized {
                return ProviderUsage(
                    id: .codex, name: "Codex", status: .error,
                    message: "Token expired — run `codex` to re-auth.",
                    bars: [], meta: []
                )
            } catch let CodexFetchError.http(code) where code == 429 {
                if var cached = await OAuthSnapshotCache.shared.recent(.codex, maxAge: 600) {
                    cached = ProviderUsage(
                        id: cached.id, name: cached.name, status: .ok,
                        message: "Rate-limited — showing last good snapshot.",
                        bars: cached.bars, meta: cached.meta
                    )
                    return cached
                }
                return ProviderUsage(
                    id: .codex, name: "Codex", status: .error,
                    message: "Rate-limited (HTTP 429). Retrying on next refresh.",
                    bars: [], meta: []
                )
            } catch {
                if var cached = await OAuthSnapshotCache.shared.recent(.codex, maxAge: 600) {
                    cached = ProviderUsage(
                        id: cached.id, name: cached.name, status: .ok,
                        message: "Network error — showing last good snapshot.",
                        bars: cached.bars, meta: cached.meta
                    )
                    return cached
                }
                // Network / decode failure with no cache — fall through to local fallback.
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let historyURL = home.appendingPathComponent(".codex/history.jsonl")
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            return ProviderUsage(
                id: .codex,
                name: "Codex",
                status: .unavailable,
                message: "~/.codex/auth.json + history.jsonl both missing.",
                bars: [],
                meta: []
            )
        }

        let now = Date()
        var sessions5h = Set<String>()
        var sessions7d = Set<String>()
        var msgs5h = 0
        var msgs7d = 0

        do {
            for try await line in historyURL.lines {
                if line.isEmpty { continue }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let rawTs = asDouble(obj["ts"])
                guard rawTs > 0 else { continue }
                let tsSeconds = rawTs > 2_000_000_000 ? rawTs / 1000 : rawTs
                let tsDate = Date(timeIntervalSince1970: tsSeconds)
                let age = now.timeIntervalSince(tsDate)
                if age <= fiveHours {
                    msgs5h += 1
                    if let sid = obj["session_id"] as? String { sessions5h.insert(sid) }
                }
                if age <= sevenDays {
                    msgs7d += 1
                    if let sid = obj["session_id"] as? String { sessions7d.insert(sid) }
                }
            }
        } catch {
            return ProviderUsage(
                id: .codex,
                name: "Codex",
                status: .error,
                message: "Failed to read history.jsonl.",
                bars: [],
                meta: []
            )
        }

        let message =
            "Offline estimate from CLI history — real usage needs OAuth."

        return ProviderUsage(
            id: .codex,
            name: "Codex",
            status: .ok,
            message: message,
            bars: [
                UsageBar(
                    label: "5h CLI prompts",
                    percent: nil,
                    used: Double(msgs5h),
                    limit: nil,
                    unit: "prompts",
                    resetsAt: nil
                ),
                UsageBar(
                    label: "7d CLI prompts",
                    percent: nil,
                    used: Double(msgs7d),
                    limit: nil,
                    unit: "prompts",
                    resetsAt: nil
                ),
            ],
            meta: [
                ("5h sessions", String(sessions5h.count)),
                ("7d sessions", String(sessions7d.count)),
            ]
        )
    }

    private static func codexFromOAuth(_ resp: CodexUsageResponse) -> ProviderUsage {
        var bars: [UsageBar] = []
        if let win = resp.primaryWindow {
            bars.append(UsageBar(
                label: labelForWindow(win.limitWindowSeconds, fallback: "5h window"),
                percent: win.usedPercent,
                used: win.usedPercent,
                limit: 100,
                unit: "%",
                resetsAt: win.resetAt
            ))
        }
        if let win = resp.secondaryWindow {
            bars.append(UsageBar(
                label: labelForWindow(win.limitWindowSeconds, fallback: "weekly"),
                percent: win.usedPercent,
                used: win.usedPercent,
                limit: 100,
                unit: "%",
                resetsAt: win.resetAt
            ))
        }
        var meta: [(String, String)] = []
        if let plan = resp.planType, !plan.isEmpty {
            meta.append(("plan", plan.capitalized))
        }
        return ProviderUsage(
            id: .codex,
            name: "Codex",
            status: .ok,
            message: bars.isEmpty ? "No rate-limit windows returned." : nil,
            bars: bars,
            meta: meta
        )
    }

    private static func labelForWindow(_ seconds: Int?, fallback: String) -> String {
        guard let seconds, seconds > 0 else { return fallback }
        let hours = seconds / 3600
        if hours <= 1 { return "\(max(1, seconds / 60))m window" }
        if hours < 24 { return "\(hours)h window" }
        let days = hours / 24
        return "\(days)d window"
    }
}

private func parseClaudeLine(_ line: String, retentionCutoff: Date) -> UsageEvent? {
    guard let data = line.data(using: .utf8) else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    guard let ts = obj["timestamp"] as? String,
          let date = parseISO8601(ts),
          date >= retentionCutoff
    else { return nil }
    guard let message = obj["message"] as? [String: Any],
          let usage = message["usage"] as? [String: Any]
    else { return nil }
    let price = pricing(for: message["model"] as? String)
    let input = asDouble(usage["input_tokens"])
    let output = asDouble(usage["output_tokens"])
    let cacheCreate = asDouble(usage["cache_creation_input_tokens"])
    let cacheRead = asDouble(usage["cache_read_input_tokens"])
    let cost =
        (input * price.input + output * price.output
            + cacheCreate * price.cacheWrite + cacheRead * price.cacheRead) / 1_000_000
    return UsageEvent(
        timestamp: date,
        input: input,
        output: output,
        cacheCreate: cacheCreate,
        cacheRead: cacheRead,
        cost: cost
    )
}

private func asDouble(_ v: Any?) -> Double {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String, let d = Double(s) { return d }
    return 0
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(ceil(seconds)))
    if total < 60 { return "\(total)s" }
    let minutes = total / 60
    let remainder = total % 60
    return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
}

private let iso8601Fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let iso8601Basic: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func parseISO8601(_ s: String) -> Date? {
    iso8601Fractional.date(from: s) ?? iso8601Basic.date(from: s)
}
