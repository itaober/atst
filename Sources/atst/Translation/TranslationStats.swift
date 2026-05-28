import Foundation

/// Per-day translation event counter with two parallel counters:
/// `total` (every user-triggered translation, cache hits included) and
/// `new` (cache misses — translations that actually called a provider).
///
/// Separate from `TranslationCache` because cache only records unique
/// translations (one entry per source text), so cache-derived stats miss
/// repeated lookups of the same word. This counter increments on every
/// user-triggered translation, so the stats sparkline reflects actual
/// usage volume; the secondary `new` line lets the user see how much of
/// that volume was fresh vocabulary vs cached lookups.
///
/// Persisted as a tiny JSON file in `~/Library/Caches/dev.local.atst/`
/// alongside the translation cache. Auto-prunes to the last 90 days on
/// load.
@MainActor
final class TranslationStats: ObservableObject {
    static let shared = TranslationStats()

    struct DailyEntry: Equatable {
        let date: Date
        let total: Int
        let new: Int
    }

    /// Per-day buckets. Keys are calendar-day-start Dates so equality
    /// lines up regardless of when in the day the entry was recorded.
    private var buckets: [Date: DailyBucket] = [:]

    /// Drives `@ObservedObject` listeners — SwiftUI re-evaluates dependent
    /// views whenever this bumps.
    @Published private(set) var revision: Int = 0

    private let storageURL: URL
    private var saveDebounceTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent(Branding.bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("translation_stats.json")
        loadFromDisk()
        pruneOldEntries()
    }

    /// Bump today's `total` bucket — call once per user-triggered
    /// translation (hotkey, refresh, screenshot capture).
    func recordTranslation() {
        let today = Calendar.current.startOfDay(for: Date())
        buckets[today, default: DailyBucket()].total += 1
        revision &+= 1
        scheduleSave()
    }

    /// Bump today's `new` bucket — call once per user-triggered
    /// translation whose result was NOT entirely served from cache. For
    /// multi-provider selection translations, "any segment was a cache
    /// miss" qualifies. Screenshot vision is always new (no cache).
    func recordCacheMiss() {
        let today = Calendar.current.startOfDay(for: Date())
        buckets[today, default: DailyBucket()].new += 1
        revision &+= 1
        scheduleSave()
    }

    /// Returns the last `days` days as a dense series, oldest first.
    /// Empty days come back with zeros so callers can draw an unbroken
    /// line series.
    func dailyCounts(days: Int = 14) -> [DailyEntry] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var result: [DailyEntry] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            if let d = calendar.date(byAdding: .day, value: -offset, to: today) {
                let b = buckets[d] ?? DailyBucket()
                result.append(DailyEntry(date: d, total: b.total, new: b.new))
            }
        }
        return result
    }

    /// Wipe every bucket. Called by the "Clear" button alongside cache
    /// clearing so the two stay visually consistent.
    func clear() {
        buckets.removeAll()
        revision &+= 1
        scheduleSave()
    }

    // MARK: - Internals

    private struct DailyBucket: Codable, Equatable {
        var total: Int = 0
        var new: Int = 0
    }

    private func pruneOldEntries() {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: Date())) else { return }
        buckets = buckets.filter { $0.key >= cutoff }
    }

    private func scheduleSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveToDisk()
        }
    }

    private func saveToDisk() {
        let snapshot = Snapshot(entries: buckets.map { Entry(date: $0.key, bucket: $0.value) })
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard
            let data = try? Data(contentsOf: storageURL),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        for entry in snapshot.entries {
            buckets[entry.date] = entry.bucket
        }
    }

    private struct Snapshot: Codable {
        let entries: [Entry]
    }

    private struct Entry: Codable {
        let date: Date
        let bucket: DailyBucket
    }
}
