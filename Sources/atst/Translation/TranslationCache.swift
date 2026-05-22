import Foundation

/// Local persistent cache for successful text translations.
///
/// - Key = `model | targetLanguage | phoneticEnabled | smartExplanationEnabled | normalize(sourceText)`
///   where `normalize` = trim + lowercase, so casing and stray whitespace
///   don't fragment the cache.
/// - TTL: 90 days. Entries older than that are treated as misses (and pruned).
/// - LRU capped at `maxEntries` (2000); least-recently-used entries evict.
/// - Persisted as a single JSON file under `~/Library/Caches/dev.local.atst/`.
///   `Caches/` semantics mean macOS may purge the file if disk is low — fine,
///   we treat the cache as best-effort.
/// - Writes are debounced (1s) and performed off-main; reads stay on main.
///
/// Note: screenshot translations are intentionally *not* cached — each
/// image is unique, and the base64 payload would balloon the cache.
@MainActor
final class TranslationCache: ObservableObject {
    static let shared = TranslationCache()

    enum Source: String, Codable, Equatable {
        case ai
        case api
    }

    struct CacheInfo: Equatable {
        let cachedAt: Date
        let source: Source
    }

    struct Entry: Codable, Equatable {
        let key: String
        let source: Source
        let createdAt: Date
        var lastUsedAt: Date
        let output: TranslationOutput
        let model: String
        let sourceText: String      // original casing, for display / debugging
    }

    /// Number of cached entries that came from an AI (LLM) translation.
    @Published private(set) var aiCount: Int = 0
    /// Number of cached entries that came from a non-LLM translation API.
    /// Always 0 today — placeholder for a future traditional API integration.
    @Published private(set) var apiCount: Int = 0
    /// Approximate persisted size in bytes (JSON-encoded snapshot).
    @Published private(set) var totalBytes: Int = 0

    private var entries: [String: Entry] = [:]
    /// Driven by `AppConfiguration.cacheEnabled` via `configure(...)` — when
    /// false, `get` always misses and `put` is a no-op, but persisted entries
    /// stay on disk so toggling back on restores them.
    private var enabled: Bool = true
    /// Upper bound on live entries. LRU drives eviction. Driven from
    /// `AppConfiguration.cacheMaxEntries` via `configure(...)`.
    private var maxEntries: Int = 2000
    /// Time-to-live for an entry; expired entries are dropped on read and on
    /// load. Driven from `AppConfiguration.cacheTTLDays` via `configure(...)`.
    private var ttl: TimeInterval = 90 * 24 * 3600
    private let storageURL: URL
    private var saveDebounceTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent(Branding.bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("translations.json")
        loadFromDisk()
    }

    // MARK: - External configuration

    /// Apply the user's cache preferences. Idempotent — safe to call on
    /// every configuration change. Shrinking `maxEntries` triggers an
    /// eviction pass immediately so disk + memory stay within the new bound.
    func configure(enabled: Bool, ttlDays: Int, maxEntries: Int) {
        let cleanTTLDays = max(1, ttlDays)
        let cleanMax = max(1, maxEntries)
        let ttlChanged = self.ttl != TimeInterval(cleanTTLDays) * 24 * 3600
        let maxChanged = self.maxEntries != cleanMax
        self.enabled = enabled
        self.ttl = TimeInterval(cleanTTLDays) * 24 * 3600
        self.maxEntries = cleanMax
        if ttlChanged {
            // Newly-shortened TTL may make existing entries expire — prune now.
            pruneExpired()
        }
        if maxChanged {
            evictIfNeeded()
        }
        if ttlChanged || maxChanged {
            updateStats()
            scheduleSave()
        }
        AppLogger.log("cache configured enabled=\(enabled) ttlDays=\(cleanTTLDays) maxEntries=\(cleanMax)")
    }

    // MARK: - Key

    static func makeKey(text: String, configuration: AppConfiguration) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [
            "v1",   // schema version — bump if Entry shape changes
            configuration.textModel,
            configuration.targetLanguage,
            configuration.phoneticEnabled ? "p1" : "p0",
            configuration.smartExplanationEnabled ? "e1" : "e0",
            normalized
        ].joined(separator: "|")
    }

    // MARK: - Read / write

    /// Returns a non-expired entry and bumps its `lastUsedAt` (LRU touch).
    /// Returns `nil` if cache is disabled, absent, or expired.
    func get(key: String) -> Entry? {
        guard enabled else { return nil }
        guard var entry = entries[key] else { return nil }
        if Date().timeIntervalSince(entry.createdAt) > ttl {
            entries.removeValue(forKey: key)
            updateStats()
            scheduleSave()
            AppLogger.log("cache miss-expired key='\(key.suffix(60))'")
            return nil
        }
        entry.lastUsedAt = Date()
        entries[key] = entry
        scheduleSave()
        AppLogger.log("cache hit key='\(key.suffix(60))' age=\(Int(Date().timeIntervalSince(entry.createdAt)))s")
        return entry
    }

    func put(
        key: String,
        source: Source,
        output: TranslationOutput,
        model: String,
        sourceText: String
    ) {
        guard enabled else {
            AppLogger.log("cache put skipped: cache disabled")
            return
        }
        let now = Date()
        entries[key] = Entry(
            key: key,
            source: source,
            createdAt: now,
            lastUsedAt: now,
            output: output,
            model: model,
            sourceText: sourceText
        )
        evictIfNeeded()
        updateStats()
        scheduleSave()
        AppLogger.log("cache put source=\(source.rawValue) total=\(entries.count)")
    }

    func clear() {
        entries.removeAll()
        updateStats()
        scheduleSave()
        AppLogger.log("cache cleared")
    }

    // MARK: - Internals

    private func evictIfNeeded() {
        guard entries.count > maxEntries else { return }
        let excess = entries.count - maxEntries
        let sortedByLRU = entries.values.sorted { $0.lastUsedAt < $1.lastUsedAt }
        for victim in sortedByLRU.prefix(excess) {
            entries.removeValue(forKey: victim.key)
        }
    }

    /// Drop entries older than the current TTL. Called after the user
    /// shortens `cacheTTLDays` so stale entries don't linger in stats.
    private func pruneExpired() {
        let now = Date()
        let before = entries.count
        entries = entries.filter { now.timeIntervalSince($0.value.createdAt) <= ttl }
        let pruned = before - entries.count
        if pruned > 0 {
            AppLogger.log("cache pruned-expired count=\(pruned)")
        }
    }

    private func updateStats() {
        var ai = 0
        var api = 0
        for entry in entries.values {
            switch entry.source {
            case .ai: ai += 1
            case .api: api += 1
            }
        }
        aiCount = ai
        apiCount = api
        if let data = try? JSONEncoder().encode(Array(entries.values)) {
            totalBytes = data.count
        } else {
            totalBytes = 0
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL) else {
            AppLogger.log("cache load: no file at \(storageURL.path)")
            return
        }
        guard let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            AppLogger.log("cache load: failed to decode \(storageURL.path)")
            return
        }
        let now = Date()
        let alive = decoded.filter { now.timeIntervalSince($0.createdAt) <= ttl }
        entries = Dictionary(uniqueKeysWithValues: alive.map { ($0.key, $0) })
        updateStats()
        AppLogger.log("cache loaded entries=\(entries.count) bytes=\(totalBytes) pruned=\(decoded.count - alive.count)")
    }

    private func scheduleSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.saveToDisk()
        }
    }

    private func saveToDisk() {
        let snapshot = Array(entries.values)
        let url = storageURL
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: [.atomic])
            } catch {
                // Best-effort persistence; we'll try again on the next put.
            }
        }
    }
}
