import Foundation

/// Local persistent cache for successful text translations.
///
/// Cache schema v2 (P7): each translation segment (AI + every enabled API
/// provider) is cached under its own key, so changing the AI prompt
/// settings doesn't invalidate Google's cached entry and vice versa.
///
/// Key formats (all colon-pipe joined):
///   - AI  segment: `v2|ai|<model>|<targetLang>|p<0/1>|e<0/1>|<normalized text>`
///   - API segment: `v2|<providerId>|<targetLang>|<normalized text>`
///
/// `normalize` = trim + lowercase, so casing and stray whitespace don't
/// fragment the cache.
///
/// - TTL: configurable (default 90 days). Entries older than that are
///   treated as misses (and pruned).
/// - LRU capped at `maxEntries` (default 2000); least-recently-used entries
///   evict.
/// - Persisted as a single JSON file under `~/Library/Caches/dev.local.atst/`.
///   `Caches/` semantics mean macOS may purge the file if disk is low —
///   fine, we treat the cache as best-effort.
/// - Writes are debounced (1s) and performed off-main; reads stay on main.
///
/// Note: screenshot translations are intentionally *not* cached — each
/// image is unique, and the base64 payload would balloon the cache.
@MainActor
final class TranslationCache: ObservableObject {
    static let shared = TranslationCache()

    enum Source: String, Codable, Equatable {
        /// Cache came from an AI (LLM) translation segment.
        case ai
        /// Cache came from an API (Google / Microsoft / future custom)
        /// translation segment.
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
    /// Number of cached entries that came from a non-LLM translation API
    /// (Google / Microsoft / future custom).
    @Published private(set) var apiCount: Int = 0
    /// Approximate persisted size in bytes (JSON-encoded snapshot).
    @Published private(set) var totalBytes: Int = 0

    private var entries: [String: Entry] = [:]
    private var enabled: Bool = true
    private var maxEntries: Int = 2000
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
        // v2 cache key format ships in P7. Old v1 entries can't satisfy v2
        // lookups, so they just gather TTL dust without harming anything —
        // we sweep them on first launch to keep stats honest.
        purgeLegacyEntries()
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

    // MARK: - Keys
    //
    // P7 splits the single legacy AI key into per-segment keys so AI and
    // each API provider live in independent cache slots. The composition is
    // intentionally provider-aware: AI keys include model + phonetic +
    // explanation toggles (changing those should re-translate); API keys
    // only need provider + target + text (no toggles apply).

    /// Cache key for the AI segment. Includes the toggles that change AI
    /// behaviour so flipping them invalidates the cached output.
    static func makeAIKey(text: String, configuration: AppConfiguration) -> String {
        let normalized = normalize(text)
        return [
            "v2",
            "ai",
            configuration.textModel,
            configuration.targetLanguage,
            configuration.phoneticEnabled ? "p1" : "p0",
            configuration.smartExplanationEnabled ? "e1" : "e0",
            normalized
        ].joined(separator: "|")
    }

    /// Cache key for a single API provider segment.
    static func makeProviderKey(
        providerID: TranslationProviderID,
        text: String,
        targetLanguage: String
    ) -> String {
        let normalized = normalize(text)
        return [
            "v2",
            providerID.rawValue,
            targetLanguage,
            normalized
        ].joined(separator: "|")
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private func pruneExpired() {
        let now = Date()
        let before = entries.count
        entries = entries.filter { now.timeIntervalSince($0.value.createdAt) <= ttl }
        let pruned = before - entries.count
        if pruned > 0 {
            AppLogger.log("cache pruned-expired count=\(pruned)")
        }
    }

    /// Sweep entries whose key uses the legacy `v1|…` schema. They became
    /// unreachable when P7 moved keys to `v2|…` and would otherwise sit on
    /// disk for the full TTL.
    private func purgeLegacyEntries() {
        let before = entries.count
        entries = entries.filter { !$0.key.hasPrefix("v1|") }
        let removed = before - entries.count
        if removed > 0 {
            AppLogger.log("cache purged legacy v1 entries count=\(removed)")
            updateStats()
            scheduleSave()
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
