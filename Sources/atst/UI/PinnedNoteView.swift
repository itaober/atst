import AppKit
import SwiftUI

/// Static snapshot of a translation, frozen in time when the user pins it.
/// Carries every segment the live tooltip rendered so the pinned note keeps
/// the same dual-section layout (API rows + AI block + description).
struct PinnedNoteSnapshot: Identifiable, Equatable {
    let id = UUID()
    let sourceText: String
    let apiSegments: [ProviderSegment]
    let aiSegment: ProviderSegment?
    let phoneticEnabled: Bool
    let smartExplanationEnabled: Bool
    let initiallyExpanded: Bool

    static func == (lhs: PinnedNoteSnapshot, rhs: PinnedNoteSnapshot) -> Bool {
        lhs.id == rhs.id
    }

    /// Convenience used by the AppKit shell for the panel title.
    var headerTitle: String {
        if let ai = aiSegment, let model = ai.modelHint, !model.isEmpty {
            return model
        }
        return Branding.appName
    }

    var canRender: Bool {
        if let ai = aiSegment, ai.state.hasContent { return true }
        return apiSegments.contains { $0.state.hasContent }
    }
}

/// Read-only sibling of `TranslationResultView`. Same visual language, but
/// driven by a frozen snapshot instead of the live view model.
struct PinnedNoteView: View {
    let snapshot: PinnedNoteSnapshot
    var onClose: () -> Void

    @State private var descriptionExpanded: Bool
    @State private var copyFeedbackKey: String? = nil
    @State private var copyResetTask: Task<Void, Never>?

    private let cornerRadius: CGFloat = 10
    private let speaker = TooltipSpeaker()

    init(snapshot: PinnedNoteSnapshot, onClose: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onClose = onClose
        _descriptionExpanded = State(initialValue: snapshot.initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !snapshot.apiSegments.isEmpty {
                PinnedAPIBlock(segments: snapshot.apiSegments, copyFeedbackKey: $copyFeedbackKey) { key in
                    triggerCopyFeedback(for: key)
                }
            }
            if !snapshot.apiSegments.isEmpty && snapshot.aiSegment != nil {
                Divider().padding(.vertical, 1)
            }
            if let ai = snapshot.aiSegment {
                PinnedAISegmentBlock(
                    segment: ai,
                    descriptionExpanded: $descriptionExpanded,
                    phoneticEnabled: snapshot.phoneticEnabled,
                    smartExplanationEnabled: snapshot.smartExplanationEnabled,
                    sourceText: snapshot.sourceText,
                    copyFeedbackKey: $copyFeedbackKey,
                    onCopyFeedback: { triggerCopyFeedback(for: $0) },
                    onSpeak: { speaker.speak($0) }
                )
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .frame(width: pinnedWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(AdaptiveGlassSurface(cornerRadius: cornerRadius, border: .accent))
        .padding(5)
    }

    /// Pinned notes inherit the live tooltip's two-tier width rule so a
    /// long-text translation that was wide while live stays wide once
    /// pinned, preserving readability after detachment.
    private var pinnedWidth: CGFloat {
        let trimmed = snapshot.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 80 || trimmed.contains("\n") {
            return 480
        }
        return 320
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(snapshot.headerTitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Image(systemName: "pin.fill")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 16)
                .foregroundStyle(Color.accentColor)
                .help(L.pick("Pinned note", "已固定"))
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help(L.pick("Close", "关闭"))
        }
    }

    private func triggerCopyFeedback(for key: String) {
        copyResetTask?.cancel()
        copyFeedbackKey = key
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { copyFeedbackKey = nil }
        }
    }
}

// MARK: - API segments in pinned notes

private struct PinnedAPIBlock: View {
    let segments: [ProviderSegment]
    @Binding var copyFeedbackKey: String?
    let onCopyFeedback: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(segments) { segment in
                PinnedAPIRow(
                    segment: segment,
                    copyFeedbackKey: $copyFeedbackKey,
                    onCopyFeedback: onCopyFeedback
                )
            }
        }
    }
}

private struct PinnedAPIRow: View {
    let segment: ProviderSegment
    @Binding var copyFeedbackKey: String?
    let onCopyFeedback: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(segment.displayName)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
            content
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var content: some View {
        switch segment.state {
        case .success(let output, _, _, _):
            successRows(output)
        case .failure(let error):
            HStack(alignment: .top, spacing: 7) {
                Text(error.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(error.message ?? error.title)
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 20, height: 20)
            }
        case .loading, .streaming:
            Text(L.pick("(no result)", "（无结果）"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    /// Multi-item rendering ready for any future provider that returns
    /// multiple meanings (Google / Microsoft built-ins currently always
    /// emit a single item, so this naturally renders as one row).
    @ViewBuilder
    private func successRows(_ output: TranslationOutput) -> some View {
        let items = output.items.isEmpty ? [output.result] : output.items
        if items.count <= 1 {
            row(text: items[0], copyKey: "pinned.api.\(segment.id.rawValue).single", showBullet: false)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    row(text: item, copyKey: "pinned.api.\(segment.id.rawValue).\(offset)", showBullet: true)
                }
            }
        }
    }

    private func row(text: String, copyKey: String, showBullet: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            if showBullet {
                Text("•")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            let copied = copyFeedbackKey == copyKey
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                onCopyFeedback(copyKey)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? Color.green : .secondary)
            .help(copied ? L.pick("Copied", "已复制") : L.pick("Copy this", "复制这一条"))
        }
    }
}

// MARK: - AI segment in pinned notes

private struct PinnedAISegmentBlock: View {
    let segment: ProviderSegment
    @Binding var descriptionExpanded: Bool
    let phoneticEnabled: Bool
    let smartExplanationEnabled: Bool
    let sourceText: String
    @Binding var copyFeedbackKey: String?
    let onCopyFeedback: (String) -> Void
    let onSpeak: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(segment.modelHint ?? segment.displayName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            content
            footer
            if let description = segment.state.output.description,
               !description.isEmpty,
               smartExplanationEnabled {
                CollapsibleSection(
                    isExpanded: descriptionExpanded,
                    animation: .spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.04)
                ) {
                    TooltipDescription(markdown: description)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch segment.state {
        case .success(let output, _, _, _):
            translationItems(output)
        case .failure(let error):
            Text(error.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red.opacity(0.85))
                .help(error.message ?? error.title)
        case .loading, .streaming:
            Text(L.pick("(no result)", "（无结果）"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func translationItems(_ output: TranslationOutput) -> some View {
        if output.items.count <= 1 {
            let text = output.items.first ?? output.result
            let key = "pinned.ai.single"
            let copied = copyFeedbackKey == key
            HStack(alignment: .top, spacing: 7) {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    onCopyFeedback(key)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copied ? Color.green : .secondary)
                .help(copied ? L.pick("Copied", "已复制") : L.pick("Copy translation", "复制译文"))
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(output.items.enumerated()), id: \.offset) { offset, item in
                    let key = "pinned.ai.multi.\(offset)"
                    let copied = copyFeedbackKey == key
                    HStack(alignment: .top, spacing: 7) {
                        Text("•")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item, forType: .string)
                            onCopyFeedback(key)
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(copied ? Color.green : .secondary)
                        .help(copied ? L.pick("Copied", "已复制") : L.pick("Copy this", "复制这一条"))
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if phoneticEnabled,
               let phonetic = segment.state.output.phonetic,
               !phonetic.isEmpty {
                Button {
                    onSpeak(sourceText)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(phonetic)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderless)
                .help(L.pick("Play / \(phonetic)", "朗读 / \(phonetic)"))
            }

            Spacer(minLength: 4)

            if smartExplanationEnabled, segment.state.output.hasDescription {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.04)) {
                        descriptionExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                        .rotationEffect(.degrees(descriptionExpanded ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help(descriptionExpanded
                      ? L.pick("Collapse explanation", "收起释义")
                      : L.pick("Expand explanation", "展开释义"))
            }
        }
    }
}
