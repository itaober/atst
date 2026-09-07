import AppKit
import SwiftUI

// MARK: - Copy button

/// Copy-to-pasteboard icon button with a 1.2s "copied" checkmark. Owns
/// its own feedback state so every row that needs one doesn't re-implement
/// the timer.
struct CopyButton: View {
    let text: String
    var tooltip: String = L.pick("Copy this", "复制这一条")

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            resetTask?.cancel()
            copied = true
            resetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if !Task.isCancelled { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Color.green : .secondary)
        .help(copied ? L.pick("Copied", "已复制") : tooltip)
    }
}

// MARK: - API segment rows

/// Stacked API provider rows rendered above the AI block. Shared by the
/// live tooltip and pinned notes; `isSnapshot` swaps the in-flight
/// spinner for a static "(no result)" since a frozen note can't update.
struct APISegmentsBlock: View {
    let segments: [ProviderSegment]
    var isSnapshot = false
    /// Handler for the "Disable" button on a collapsed failure row. nil
    /// (pinned notes) hides the button.
    var onDisable: ((TranslationProviderID) -> Void)? = nil

    /// A provider that has failed this many times in a row stops rendering
    /// its full error and collapses to one line with a Disable button.
    static let collapseAfterFailures = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(mergedRows, id: \.id) { row in
                APISegmentRow(
                    title: row.title,
                    segment: row.segment,
                    isSnapshot: isSnapshot,
                    onDisable: onDisable
                )
            }
        }
    }

    private struct Row {
        var id: String
        var title: String
        var segment: ProviderSegment
    }

    /// Providers that returned the same text collapse into one row titled
    /// "Google · Microsoft" — two identical lines told the user nothing and
    /// cost a row of tooltip height. Only successes merge; pending and
    /// failed segments always keep their own row.
    private var mergedRows: [Row] {
        var rows: [Row] = []
        var rowIndexByResult: [String: Int] = [:]
        for segment in segments {
            if case .success(let output, _, _, _) = segment.state {
                let key = output.result.trimmingCharacters(in: .whitespacesAndNewlines)
                if let index = rowIndexByResult[key] {
                    rows[index].title += " · " + segment.displayName
                    rows[index].id += "+" + segment.id.rawValue
                    continue
                }
                rowIndexByResult[key] = rows.count
            }
            rows.append(Row(id: segment.id.rawValue, title: segment.displayName, segment: segment))
        }
        return rows
    }
}

private struct APISegmentRow: View {
    let title: String
    let segment: ProviderSegment
    let isSnapshot: Bool
    let onDisable: ((TranslationProviderID) -> Void)?

    var body: some View {
        // Provider name sits as a small label *above* the translation row(s).
        // The translation row owns the trailing copy button so the icon
        // aligns with the text it copies — not with the label up top.
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
            content
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var content: some View {
        switch segment.state {
        case .loading:
            pendingRow
        case .streaming(_, let output):
            if output.result.isEmpty {
                pendingRow
            } else {
                successRows(output)
            }
        case .success(let output, _, _, _):
            successRows(output)
        case .failure(let error):
            if segment.consecutiveFailures >= APISegmentsBlock.collapseAfterFailures {
                collapsedFailureRow(error)
            } else {
                HStack(alignment: .top, spacing: 7) {
                    Text(error.title)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.red.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(error.message ?? error.title)
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.8))
                        .frame(width: 20, height: 20)
                }
            }
        }
    }

    /// One quiet line instead of a red error on every translation once a
    /// provider is clearly down (blocked network, dead endpoint). The last
    /// error stays reachable via the tooltip.
    private func collapsedFailureRow(_ error: DisplayError) -> some View {
        HStack(spacing: 7) {
            Text(L.pick(
                "Failed \(segment.consecutiveFailures) times in a row",
                "连续失败 \(segment.consecutiveFailures) 次"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help(error.message ?? error.title)
            Spacer(minLength: 4)
            if let onDisable {
                Button(L.pick("Disable", "停用")) { onDisable(segment.id) }
                    .controlSize(.mini)
                    .help(L.pick("Turn this provider off in settings", "在设置中关闭这个翻译源"))
            }
        }
    }

    @ViewBuilder
    private var pendingRow: some View {
        if isSnapshot {
            Text(L.pick("(no result)", "（无结果）"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        } else {
            HStack {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(height: 14)
                Spacer()
            }
        }
    }

    /// Render successful output as one or more rows. Current built-in
    /// providers (Google, Microsoft) always return a single string per
    /// request, but the multi-row path is here for any future provider
    /// that might return several meanings — that case should look identical
    /// to the AI multi-meaning section.
    @ViewBuilder
    private func successRows(_ output: TranslationOutput) -> some View {
        let items = output.items.isEmpty ? [output.result] : output.items
        if items.count <= 1 {
            translationRow(text: items[0], showBullet: false)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    translationRow(text: item, showBullet: true)
                }
            }
        }
    }

    private func translationRow(text: String, showBullet: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            if showBullet {
                Text("•")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: text)
        }
    }
}
