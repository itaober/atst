import AppKit
import SwiftUI

struct TranslationResultView: View {
    @ObservedObject var viewModel: TranslatorViewModel
    var onClose: () -> Void
    var onContentSizeChange: (CGSize) -> Void = { _ in }
    /// Invoked when the user taps the "cached" indicator to force a fresh
    /// AI call. Receives the source text that should be re-translated.
    var onRefresh: (String) -> Void = { _ in }

    @State private var copyFeedbackKey: String? = nil
    @State private var copyResetTask: Task<Void, Never>?
    @State private var descriptionExpanded: Bool = false
    @State private var lastSeenSourceForExpansion: String = ""

    private let cornerRadius: CGFloat = 10
    private let speaker = TooltipSpeaker()

    var body: some View {
        ZStack(alignment: .topLeading) {
            tooltipChrome(descriptionExpanded: descriptionExpanded, includeSurface: true)

            if hasRenderableDescription {
                tooltipChrome(descriptionExpanded: true, includeSurface: false)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // Keep the window sized to the expanded content while only the visible
        // SwiftUI chrome changes height. That removes the janky cross-process
        // feedback loop where an NSPanel resize tries to follow every frame of
        // the disclosure animation.
        .fixedSize(horizontal: false, vertical: true)
        .readSize(onContentSizeChange)
        .onReceive(viewModel.$state) { state in
            syncExpansion(for: state)
        }
    }

    private func tooltipChrome(descriptionExpanded expanded: Bool, includeSurface: Bool) -> some View {
        let stack = tooltipStack(descriptionExpanded: expanded)
        return Group {
            if includeSurface {
                stack.modifier(GlassSurface(cornerRadius: cornerRadius))
            } else {
                stack
            }
        }
        .padding(5)
    }

    private func tooltipStack(descriptionExpanded expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
            footer
            if hasRenderableDescription, let description = currentOutput.description {
                CollapsibleSection(
                    isExpanded: expanded,
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
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(modelTitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            // Terminal-state status dot:
            //   green — successful translation
            //   gray  — proper noun / no real translation needed
            //   red   — failure
            // Loading / streaming have no dot (the spinner and incoming
            // tokens already communicate progress).
            if let dot = statusDot {
                Circle()
                    .fill(dot.color)
                    .frame(width: 6, height: 6)
                    .help(dot.tooltipText)
                    .accessibilityLabel(Text(dot.tooltipText))
            }

            // Subtle "from cache" badge: a small clockwise-arrow icon
            // immediately right of the model name. Tap re-translates with
            // cache bypass. Only visible when the current success was served
            // from cache, so it doubles as a "this isn't a fresh call" hint.
            if let info = viewModel.state.cacheInfo {
                Button {
                    onRefresh(viewModel.state.sourceText)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help(L.pick(
                    "Cached \(Self.relativeFormatter.localizedString(for: info.cachedAt, relativeTo: Date())) · click to refresh",
                    "缓存命中（\(Self.relativeFormatter.localizedString(for: info.cachedAt, relativeTo: Date()))） · 点击重新翻译"
                ))
            }

            Spacer(minLength: 8)
            if canPin {
                Button {
                    viewModel.pinned = true
                } label: {
                    Image(systemName: "pin")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .rotationEffect(.degrees(-30))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help(L.pick("Pin as note", "固定为便签"))
            }

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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// Terminal-state indicator shown next to the model name.
    private enum StatusDot {
        case success
        case untranslatable
        case failure

        var color: Color {
            switch self {
            case .success: return .green
            case .untranslatable: return .gray
            case .failure: return .red
            }
        }

        var tooltipText: String {
            switch self {
            case .success:
                return L.pick("Translated", "翻译成功")
            case .untranslatable:
                return L.pick(
                    "No standard translation (proper noun / already target language / unrecognised input)",
                    "无标准译文（专有名词 / 已是目标语言 / 无法识别的输入）"
                )
            case .failure:
                return L.pick("Translation failed", "翻译失败")
            }
        }
    }

    private var statusDot: StatusDot? {
        switch viewModel.state {
        case .success(let output, _, _, _, _):
            return output.untranslatable ? .untranslatable : .success
        case .failure:
            return .failure
        case .idle, .loading, .streaming:
            return nil
        }
    }

    /// Only show the pin button once there's real content to freeze — hide
    /// during loading / idle / failure so the header doesn't flicker.
    private var canPin: Bool {
        switch viewModel.state {
        case .streaming(_, let output, _, _, _):
            return !output.result.isEmpty
        case .success:
            return true
        case .idle, .loading, .failure:
            return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            placeholder(L.pick(
                "Select text, then press the translate hotkey",
                "选中文字，按下翻译快捷键"
            ))
        case .loading(let message, _, _, _):
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .streaming(_, let output, _, _, _):
            translationItems(output, isStreaming: true)
        case .success(let output, _, _, _, _):
            translationItems(output, isStreaming: false)
        case .failure(let error):
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let message = error.message {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func translationItems(_ output: TranslationOutput, isStreaming: Bool) -> some View {
        let items = output.items
        if items.isEmpty {
            translationText(isStreaming ? "Translating…" : "")
        } else if items.count == 1 {
            // Single-item path mirrors the multi-item row layout: translation
            // text on the left, a per-row copy button on the right. This
            // keeps the visual grammar consistent with the bullet list and
            // lets us drop the standalone bottom-right copy from the footer.
            singleMeaningRow(items[0], isStreaming: isStreaming)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    multiMeaningRow(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Single-meaning row — translation text with an inline copy button on the
    /// right, matching the multi-meaning bullet rows. Suppresses the copy
    /// button while the placeholder "Translating…" string is showing.
    private func singleMeaningRow(_ text: String, isStreaming: Bool) -> some View {
        let isPlaceholder = text.isEmpty && isStreaming
        let displayText = isPlaceholder ? "Translating…" : text
        return HStack(alignment: .top, spacing: 7) {
            Text(displayText)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isPlaceholder {
                Button {
                    copyToPasteboard(displayText)
                    triggerCopyFeedback(for: displayText)
                } label: {
                    Image(systemName: copyFeedbackKey == displayText ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copyFeedbackKey == displayText ? Color.green : .secondary)
                .help(copyFeedbackKey == displayText
                      ? L.pick("Copied", "已复制")
                      : L.pick("Copy translation", "复制译文"))
            }
        }
    }

    private func multiMeaningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
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
                copyToPasteboard(text)
                triggerCopyFeedback(for: text)
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

    private func translationText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if shouldShowPhonetic, let phonetic = currentOutput.phonetic, !phonetic.isEmpty {
                Button {
                    speaker.speak(viewModel.state.sourceText)
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

            if shouldShowDescription, currentOutput.hasDescription {
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

            // Copy button intentionally omitted here — both single- and
            // multi-meaning rows render their own inline copy next to the
            // translation text. Keeping a duplicate footer copy was a
            // legacy artifact that broke visual symmetry between the two
            // layouts.
        }
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func triggerCopyFeedback(for key: String) {
        copyResetTask?.cancel()
        copyFeedbackKey = key
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled {
                copyFeedbackKey = nil
            }
        }
    }

    private var currentOutput: TranslationOutput {
        viewModel.state.currentOutput
    }

    private var shouldShowPhonetic: Bool {
        viewModel.configuration.phoneticEnabled
    }

    private var shouldShowDescription: Bool {
        viewModel.configuration.smartExplanationEnabled
    }

    private var hasRenderableDescription: Bool {
        guard shouldShowDescription,
              let description = currentOutput.description else {
            return false
        }
        return !description.isEmpty
    }

    private var modelTitle: String {
        if let active = viewModel.state.activeModel, !active.isEmpty {
            return active
        }
        switch viewModel.state.activeMode {
        case .some(.screenshot):
            return viewModel.configuration.screenshotModel.isEmpty ? Branding.appName : viewModel.configuration.screenshotModel
        case .some(.text), .none:
            return viewModel.configuration.textModel.isEmpty ? Branding.appName : viewModel.configuration.textModel
        }
    }

    private func syncExpansion(for state: TranslationState) {
        let source = state.sourceText
        guard !source.isEmpty else { return }

        // New source: reset description expansion to the user's
        // "expand by default" preference. Runs once per new translation —
        // streaming token updates keep the same source and don't re-trigger.
        if source != lastSeenSourceForExpansion {
            lastSeenSourceForExpansion = source
            descriptionExpanded = viewModel.configuration.smartExplanationExpandedByDefault
        }

        // When the translation lands and the model flagged the input as
        // untranslatable, the <atst-item> is just an echo of the source.
        // The actually-useful payload lives in <atst-desc>, so auto-expand
        // it (provided smart-explanation is on and there's something to
        // show). Done once at terminal state — if the user manually
        // collapses afterwards, we don't fight them.
        if case .success(let output, _, _, _, _) = state,
           output.untranslatable,
           viewModel.configuration.smartExplanationEnabled,
           output.hasDescription,
           !descriptionExpanded {
            descriptionExpanded = true
        }
    }
}

/// Background modifier for the live tooltip. Uses Liquid Glass on macOS 26+
/// when the SDK supports it (gated by `#if compiler(>=6.2)`), otherwise the
/// shared `VisualEffectBackground` with the system `.toolTip` material.
private struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            fallbackSurface(content)
        }
        #else
        fallbackSurface(content)
        #endif
    }

    @ViewBuilder
    private func fallbackSurface(_ content: Content) -> some View {
        content
            .background(VisualEffectBackground(material: .toolTip, cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
    }
}
