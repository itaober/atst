import AppKit
import SwiftUI

/// Static snapshot of a translation, frozen in time when the user pins it.
/// Carries everything `PinnedNoteView` needs to render without observing
/// the shared `TranslatorViewModel`.
struct PinnedNoteSnapshot: Identifiable, Equatable {
    let id = UUID()
    let modelTitle: String
    let sourceText: String
    let output: TranslationOutput
    let phoneticEnabled: Bool
    let smartExplanationEnabled: Bool
    let initiallyExpanded: Bool

    static func == (lhs: PinnedNoteSnapshot, rhs: PinnedNoteSnapshot) -> Bool {
        lhs.id == rhs.id
    }
}

/// Read-only sibling of `TranslationResultView`. Same visual language, but
/// driven by a frozen snapshot instead of a live view model. Only the close
/// button is interactive — no expand/copy buttons depend on streaming state.
struct PinnedNoteView: View {
    let snapshot: PinnedNoteSnapshot
    var onClose: () -> Void

    @State private var descriptionExpanded: Bool
    @State private var didCopy = false
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
            translationItems
            footer
            if shouldShowDescription,
               let description = snapshot.output.description,
               !description.isEmpty {
                CollapsibleSection(
                    isExpanded: descriptionExpanded,
                    animation: .spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.04)
                ) {
                    TooltipDescription(markdown: description)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PinnedNoteSurface(cornerRadius: cornerRadius))
        .padding(5)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(snapshot.modelTitle)
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

    @ViewBuilder
    private var translationItems: some View {
        let items = snapshot.output.items
        if items.count <= 1 {
            Text(items.first ?? snapshot.output.result)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    multiMeaningRow(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func multiMeaningRow(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Text("•")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copy(text)
            } label: {
                Image(systemName: copyFeedbackKey == text ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copyFeedbackKey == text ? Color.green : .secondary)
            .help(copyFeedbackKey == text ? L.pick("Copied", "已复制") : L.pick("Copy this", "复制这一条"))
        }
        .padding(.vertical, 1)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if shouldShowPhonetic, let phonetic = snapshot.output.phonetic, !phonetic.isEmpty {
                Button {
                    speaker.speak(snapshot.sourceText)
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

            if shouldShowDescription, snapshot.output.hasDescription {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.04)) {
                        descriptionExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .rotationEffect(.degrees(descriptionExpanded ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(descriptionExpanded
                      ? L.pick("Collapse explanation", "收起释义")
                      : L.pick("Expand explanation", "展开释义"))
            }

            if snapshot.output.items.count <= 1 {
                Button {
                    copy(snapshot.output.result)
                    didCopy = true
                    copyResetTask?.cancel()
                    copyResetTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        if !Task.isCancelled { didCopy = false }
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(didCopy ? Color.green : .secondary)
                .help(didCopy ? L.pick("Copied", "已复制") : L.pick("Copy translation", "复制译文"))
            }
        }
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyResetTask?.cancel()
        copyFeedbackKey = text
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { copyFeedbackKey = nil }
        }
    }

    private var shouldShowPhonetic: Bool { snapshot.phoneticEnabled }
    private var shouldShowDescription: Bool { snapshot.smartExplanationEnabled }
}

/// Pinned notes use the same tooltip material as the live tooltip but with
/// an accent-coloured border so the user can visually tell them apart from
/// the active translation.
private struct PinnedNoteSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(VisualEffectBackground(material: .toolTip, cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
    }
}
