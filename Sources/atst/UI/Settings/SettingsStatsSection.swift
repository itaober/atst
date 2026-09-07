import Charts
import SwiftUI

/// Cache counters + 14-day activity sparkline shown at the bottom of the
/// General page.
struct SettingsStatsSection: View {
    @ObservedObject var cache: TranslationCache
    @ObservedObject var stats: TranslationStats
    /// Bound to whichever day in the sparkline the cursor is over via
    /// `chartXSelection`. nil = no hover, hides the inline annotation.
    @State private var sparklineSelectedDate: Date?

    var body: some View { statsSection }

    private var statsSection: some View {
        SettingsSection(title: L.pick("Stats", "统计")) {
            HStack(spacing: 12) {
                statBlock(label: L.pick("AI", "AI"), value: "\(cache.aiCount)")
                Divider().frame(height: 28)
                statBlock(label: L.pick("API", "API"), value: "\(cache.apiCount)")
                Divider().frame(height: 28)
                cacheSizeStatBlock
                Spacer(minLength: 6)
                statsSparkline
                Spacer(minLength: 6)
                Button(L.pick("Clear", "清空")) {
                    cache.clear()
                    stats.clear()
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(cache.aiCount == 0 && cache.apiCount == 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    /// 14-day sparkline with two stacked series:
    ///   - Total: every user-triggered translation (incl. cache hits)
    ///   - New:   only cache misses (fresh provider calls)
    ///
    /// Uses macOS 14's `chartXSelection` for native hover that tracks
    /// the cursor x-position. The selected day's annotation (date +
    /// both counts) is anchored to a `RuleMark` so the tooltip arrow
    /// follows the mouse. Hidden axes since at 70pt wide the visual is
    /// a glance-able shape, not a precise reading.
    private var statsSparkline: some View {
        // Touch revision so this view re-evaluates whenever stats change.
        _ = stats.revision
        let series = stats.dailyCounts(days: 14)
        let maxValue = max(1, series.map(\.total).max() ?? 1)
        let selectedEntry = sparklineSelectedDate.flatMap { date in
            series.min(by: {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            })
        }

        return Chart {
            ForEach(series, id: \.date) { day in
                LineMark(
                    x: .value("Day", day.date),
                    y: .value("Count", day.total),
                    series: .value("Kind", "total")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(series, id: \.date) { day in
                LineMark(
                    x: .value("Day", day.date),
                    y: .value("Count", day.new),
                    series: .value("Kind", "new")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [2, 2]))
            }
            if let entry = selectedEntry {
                RuleMark(x: .value("Selected", entry.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top,
                        alignment: .center,
                        spacing: 4,
                        overflowResolution: .init(x: .disabled, y: .disabled)
                    ) {
                        sparklineHoverContent(for: entry)
                            .padding(10)
                            .padding(.bottom, 5) // room for the downward arrow tip
                            .background(.regularMaterial, in: PopoverCardShape())
                            .overlay(
                                PopoverCardShape()
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...maxValue)
        .chartXSelection(value: $sparklineSelectedDate)
        .frame(width: 70, height: 22)
    }

    private func sparklineHoverContent(for entry: TranslationStats.DailyEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.hoverDateFormatter.string(from: entry.date))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                hoverStat(
                    color: .accentColor,
                    label: L.pick("Total", "总次数"),
                    value: entry.total
                )
                Divider().frame(height: 32)
                hoverStat(
                    color: .orange,
                    label: L.pick("New", "新词"),
                    value: entry.new
                )
            }
        }
    }

    private func hoverStat(color: Color, label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Rebuilt per access so the locale follows a UI-language switch.
    private static var hoverDateFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.isChinese ? "zh_CN" : "en_US")
        f.dateFormat = L.isChinese ? "M月d日 EEEE" : "MMM d, EEEE"
        return f
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    /// Cache size variant of `statBlock` — splits the byte-formatted
    /// string ("214 KB") into number + unit and renders them on a
    /// shared baseline with a smaller unit font. This stops "214 KB"
    /// from wrapping when the stats row is tight, and matches the
    /// visual rhythm of weather / activity widgets that pair a big
    /// number with a small unit.
    private var cacheSizeStatBlock: some View {
        let formatted = Self.byteFormatter.string(fromByteCount: Int64(cache.totalBytes))
        let parts = formatted.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let number = parts.first.map(String.init) ?? formatted
        let unit = parts.count > 1 ? String(parts[1]) : ""
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(number)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(L.pick("Cache", "缓存"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .fixedSize()
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        // `.memory` uses 1024-based thresholds (1 KB at 1024 bytes,
        // 1 MB at 1024 KB), matching Activity Monitor and developer
        // intuition. `.file` would use 1000-based steps like Finder
        // — fine for storage but feels wrong for an in-process cache.
        f.countStyle = .memory
        f.allowedUnits = [.useKB, .useMB]
        return f
    }()
}

/// Popover-styled card with a downward-pointing arrow at the bottom-
/// center. Used as the background for the sparkline's hover annotation
/// so the tooltip visually resembles a native popover (material
/// background + arrow indicator + drop shadow) while staying inside
/// SwiftUI Charts' annotation system — meaning it follows the cursor
/// natively via `chartXSelection`.
private struct PopoverCardShape: Shape {
    var cornerRadius: CGFloat = 8
    var arrowWidth: CGFloat = 10
    var arrowHeight: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        let bodyHeight = rect.height - arrowHeight
        let bodyRect = CGRect(x: 0, y: 0, width: rect.width, height: bodyHeight)

        var path = Path(roundedRect: bodyRect, cornerRadius: cornerRadius)

        // Append the downward arrow at the bottom-center.
        let centerX = rect.midX
        path.move(to: CGPoint(x: centerX - arrowWidth / 2, y: bodyHeight))
        path.addLine(to: CGPoint(x: centerX, y: rect.maxY))
        path.addLine(to: CGPoint(x: centerX + arrowWidth / 2, y: bodyHeight))
        path.closeSubpath()

        return path
    }
}
