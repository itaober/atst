import AppKit
import SwiftUI

/// Tooltip body — renders either:
///   - the two-segment text layout (API rows on top, AI section below),
///   - the screenshot result (single AI block, like before),
///   - the global failure / idle / empty-state messages.
///
/// All sizing flows from `readSize` upward into `FloatingPanelController`,
/// which mirrors the SwiftUI fitting height into the NSPanel frame.
struct TranslationResultView: View {
    @ObservedObject var viewModel: TranslatorViewModel
    /// Drives the maximum content height. Owned and updated by
    /// `FloatingPanelController` so the tooltip can never overflow the
    /// current screen, and so dragging to a position with more room
    /// dismisses the scroll bar automatically.
    @ObservedObject var layout: TooltipLayout
    var onClose: () -> Void
    var onContentSizeChange: (CGSize) -> Void = { _ in }
    /// Invoked when the user taps the "cached" indicator (header refresh).
    /// Receives the source text that should be re-translated.
    var onRefresh: (String) -> Void = { _ in }
    /// Invoked when the user clicks the empty-state "Open settings" CTA.
    /// Wired up by the panel controller so a tooltip-driven settings open
    /// can dismiss the tooltip first.
    var onOpenSettings: () -> Void = {}

    @State private var descriptionExpanded: Bool = false
    @State private var lastSeenSourceForExpansion: String = ""

    private let cornerRadius: CGFloat = 10

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
        // Wrap the stack in a ScrollView whose height tops out at
        // `layout.maxContentHeight`. SwiftUI sizes the ScrollView to its
        // content's natural height when content fits, only engaging the
        // scroll bar (and capping height) when natural > max. The view
        // therefore stays scroll-free for short translations and only
        // shows a scroll bar when the panel literally can't fit the
        // content within the available screen space.
        //
        // The inner `header` is the drag handle (see WindowDragHandle in
        // tooltipHeader) — keeping it inside the scroll area means the
        // user can grab it from the top edge even when content scrolls,
        // matching native macOS behaviour (toolbar pinned at top).
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                header
                content(descriptionExpanded: expanded)
            }
            .padding(.horizontal, 11)
            .padding(.top, 8)
            .padding(.bottom, 7)
            .frame(width: preferredTooltipWidth, alignment: .leading)
        }
        .frame(maxHeight: layout.maxContentHeight)
        .fixedSize(horizontal: true, vertical: true)
    }

    /// Two-tier tooltip width. Short selections (a word, a name, a short
    /// phrase) read better in a narrow column; long selections — sentences
    /// over ~80 characters or anything multi-line — produce a forest of
    /// wrapped fragments at the narrow width, so we widen the panel to
    /// keep each line within a reasonable reading length. The exact
    /// thresholds are intentionally coarse (binary, not tiered) so the
    /// panel never feels like its size is drifting unpredictably.
    private var preferredTooltipWidth: CGFloat {
        let trimmed = viewModel.state.sourceText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 80 || trimmed.contains("\n") {
            return 480
        }
        return 320
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(headerTitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let dot = statusDot {
                Circle()
                    .fill(dot.color)
                    .frame(width: 6, height: 6)
                    .help(dot.tooltipText)
                    .accessibilityLabel(Text(dot.tooltipText))
            }

            Spacer(minLength: 8)

            // Header-level refresh: only visible when at least one segment
            // was served from cache. Re-translates from scratch and bypasses
            // the cache for every segment.
            if anyFromCache {
                Button {
                    onRefresh(viewModel.state.sourceText)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help(L.pick("Refresh (bypass cache)", "重新翻译（绕过缓存）"))
            }

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
        // The whole header strip — model name, status dot, spacer — is a
        // drag handle for the floating panel. Buttons inside (refresh /
        // pin / close) keep their own click handling because they sit
        // *above* the background drag-initiator. Cursor turns into an
        // open hand on hover so users discover the affordance.
        .background(WindowDragHandle())
    }

    private var headerTitle: String {
        switch viewModel.state {
        case .screenshotLoading(_, let model, _),
             .screenshotStreaming(_, _, let model, _),
             .screenshotSuccess(_, _, let model):
            return model.isEmpty ? Branding.appName : model
        case .text:
            return Branding.appName
        case .idle, .failure:
            return Branding.appName
        }
    }

    private var canPin: Bool {
        switch viewModel.state {
        case .text(let segments):
            return segments.hasAnyContent
        case .screenshotStreaming(_, let output, _, _):
            return !output.result.isEmpty
        case .screenshotSuccess:
            return true
        case .idle, .screenshotLoading, .failure:
            return false
        }
    }

    private var anyFromCache: Bool {
        if case .text(let segments) = viewModel.state {
            return segments.allSegments.contains { segment in
                if case .success(_, _, true, _) = segment.state { return true }
                return false
            }
        }
        return false
    }

    // MARK: - Header status dot

    /// Multi-source-aware status dot:
    ///   green — at least one segment succeeded, none failed
    ///   yellow — mixed (some success, some failure)
    ///   red   — all segments failed
    ///   gray  — at least one terminal segment but all "untranslatable"
    ///   nil   — still loading / streaming / idle
    private enum StatusDot {
        case success
        case untranslatable
        case partial
        case failure

        var color: Color {
            switch self {
            case .success: return .green
            case .partial: return .orange
            case .untranslatable: return .gray
            case .failure: return .red
            }
        }

        var tooltipText: String {
            switch self {
            case .success:
                return L.pick("Translated", "翻译成功")
            case .partial:
                return L.pick("Partial success — some providers failed", "部分成功：有 provider 失败")
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
        case .text(let segments):
            return statusDot(for: segments)
        case .screenshotSuccess(let output, _, _):
            return output.untranslatable ? .untranslatable : .success
        case .failure:
            return .failure
        case .idle, .screenshotLoading, .screenshotStreaming:
            return nil
        }
    }

    private func statusDot(for segments: TextSegments) -> StatusDot? {
        if segments.bothDisabled { return nil }
        var successes = 0
        var failures = 0
        var untranslatables = 0
        var pending = 0
        for segment in segments.allSegments {
            switch segment.state {
            case .success(let output, _, _, _):
                if output.untranslatable {
                    untranslatables += 1
                } else {
                    successes += 1
                }
            case .failure:
                failures += 1
            case .loading, .streaming:
                pending += 1
            }
        }
        if pending > 0, successes == 0, failures == 0, untranslatables == 0 { return nil }
        if failures > 0, successes == 0, untranslatables == 0 { return .failure }
        if successes == 0, untranslatables > 0, failures == 0 { return .untranslatable }
        if failures > 0 { return .partial }
        return .success
    }

    // MARK: - Body content

    @ViewBuilder
    private func content(descriptionExpanded expanded: Bool) -> some View {
        switch viewModel.state {
        case .idle:
            placeholder(L.pick(
                "Select text, then press the translate hotkey",
                "选中文字，按下翻译快捷键"
            ))
        case .text(let segments):
            textContent(segments, descriptionExpanded: expanded)
        case .screenshotLoading(let message, _, _):
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .screenshotStreaming(_, let output, _, _):
            translationItems(output, isStreaming: true, copyKeyPrefix: "screenshot")
        case .screenshotSuccess(let output, _, _):
            translationItems(output, isStreaming: false, copyKeyPrefix: "screenshot")
        case .failure(let error):
            failureBlock(error)
        }
    }

    @ViewBuilder
    private func textContent(_ segments: TextSegments, descriptionExpanded expanded: Bool) -> some View {
        if segments.bothDisabled {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !segments.api.isEmpty {
                    APISegmentsBlock(segments: segments.api)
                }
                if !segments.api.isEmpty && segments.ai != nil {
                    Divider().padding(.vertical, 1)
                }
                if let ai = segments.ai {
                    AISegmentBlock(
                        segment: ai,
                        descriptionExpanded: expanded,
                        toggleExpand: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.04)) {
                                descriptionExpanded.toggle()
                            }
                        },
                        phoneticEnabled: viewModel.configuration.phoneticEnabled,
                        smartExplanationEnabled: viewModel.configuration.smartExplanationEnabled,
                        sourceText: segments.source
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "switch.2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.pick(
                        "No translator enabled",
                        "未启用任何翻译方式"
                    ))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    Text(L.pick(
                        "Enable AI or API translation in settings to start translating.",
                        "请在设置中启用 AI 翻译或 API 翻译后再使用。"
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                onOpenSettings()
            } label: {
                Text(L.pick("Open Settings", "打开设置"))
                    .font(.system(size: 12, weight: .medium))
            }
            .controlSize(.small)
        }
    }

    private func failureBlock(_ error: DisplayError) -> some View {
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

    // MARK: - Screenshot translation rendering

    @ViewBuilder
    private func translationItems(_ output: TranslationOutput, isStreaming: Bool, copyKeyPrefix: String) -> some View {
        let items = output.items
        if items.isEmpty {
            placeholderText(isStreaming ? L.pick("Translating…", "翻译中…") : "")
        } else if items.count == 1 {
            singleMeaningRow(items[0], isStreaming: isStreaming, copyKey: "\(copyKeyPrefix).single")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    multiMeaningRow(item, copyKey: "\(copyKeyPrefix).\(offset)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @State private var copyFeedbackKey: String? = nil
    @State private var copyResetTask: Task<Void, Never>?

    private func singleMeaningRow(_ text: String, isStreaming: Bool, copyKey: String) -> some View {
        let isPlaceholder = text.isEmpty && isStreaming
        let displayText = isPlaceholder ? L.pick("Translating…", "翻译中…") : text
        return HStack(alignment: .top, spacing: 7) {
            Text(displayText)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isPlaceholder {
                copyButton(text: text, key: copyKey, tooltip: L.pick("Copy translation", "复制译文"))
            }
        }
    }

    private func multiMeaningRow(_ text: String, copyKey: String) -> some View {
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
            copyButton(text: text, key: copyKey, tooltip: L.pick("Copy this", "复制这一条"))
        }
        .padding(.vertical, 1)
    }

    private func copyButton(text: String, key: String, tooltip: String) -> some View {
        let copied = copyFeedbackKey == key
        return Button {
            copyToPasteboard(text)
            triggerCopyFeedback(for: key)
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

    private func placeholderText(_ text: String) -> some View {
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
            if !Task.isCancelled { copyFeedbackKey = nil }
        }
    }

    // MARK: - Auto-expand bookkeeping

    private var currentOutput: TranslationOutput {
        viewModel.state.currentOutput
    }

    /// Only the AI segment surfaces phonetic/description — and only when
    /// the user has enabled the corresponding toggles.
    private var hasRenderableDescription: Bool {
        guard viewModel.configuration.smartExplanationEnabled else { return false }
        guard let description = aiSegmentDescription, !description.isEmpty else { return false }
        return true
    }

    private var aiSegmentDescription: String? {
        guard case .text(let segments) = viewModel.state, let ai = segments.ai else { return nil }
        return ai.state.output.description
    }

    private func syncExpansion(for state: TranslationState) {
        let source = state.sourceText
        guard !source.isEmpty else { return }

        if source != lastSeenSourceForExpansion {
            lastSeenSourceForExpansion = source
            descriptionExpanded = viewModel.configuration.smartExplanationExpandedByDefault
        }

        // Auto-expand description when the AI segment lands with
        // untranslatable=true and there's a description with the user's
        // reason in it — same behaviour as before, scoped to the AI segment.
        if case .text(let segments) = state,
           let ai = segments.ai,
           case .success(let output, _, _, _) = ai.state,
           output.untranslatable,
           viewModel.configuration.smartExplanationEnabled,
           output.hasDescription,
           !descriptionExpanded {
            descriptionExpanded = true
        }
    }
}

// MARK: - API segments block

/// Renders the stacked API rows above the AI block. Every row carries its
/// own copy button and failure UI.
private struct APISegmentsBlock: View {
    let segments: [ProviderSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(segments) { segment in
                APISegmentRow(segment: segment)
            }
        }
    }
}

private struct APISegmentRow: View {
    let segment: ProviderSegment
    @State private var copyFeedbackKey: String? = nil
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        // Provider name sits as a small label *above* the translation row(s).
        // The translation row owns the trailing copy button so the icon
        // aligns with the text it copies — not with the label up top.
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
        case .loading:
            loadingRow
        case .streaming(_, let output):
            if output.result.isEmpty {
                loadingRow
            } else {
                successRows(output)
            }
        case .success(let output, _, _, _):
            successRows(output)
        case .failure(let error):
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

    private var loadingRow: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(height: 14)
            Spacer()
        }
    }

    /// Render successful output as one or more rows. Current built-in
    /// providers (Google, Microsoft) always return a single string per
    /// request, but the multi-row path is here for any future provider
    /// (custom HTTP / DeepL alternates / dictionary-flavoured API) that
    /// might return several meanings — that case should look identical to
    /// the AI multi-meaning section.
    @ViewBuilder
    private func successRows(_ output: TranslationOutput) -> some View {
        let items = output.items.isEmpty ? [output.result] : output.items
        if items.count <= 1 {
            translationRow(text: items[0], copyKey: "api.\(segment.id.rawValue).single", showBullet: false)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    translationRow(text: item, copyKey: "api.\(segment.id.rawValue).\(offset)", showBullet: true)
                }
            }
        }
    }

    private func translationRow(text: String, copyKey: String, showBullet: Bool) -> some View {
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
            copyButton(text: text, key: copyKey)
        }
    }

    private func copyButton(text: String, key: String) -> some View {
        let copied = copyFeedbackKey == key
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copyResetTask?.cancel()
            copyFeedbackKey = key
            copyResetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if !Task.isCancelled { copyFeedbackKey = nil }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Color.green : .secondary)
        .help(copied
              ? L.pick("Copied", "已复制")
              : L.pick("Copy this", "复制这一条"))
    }
}

// MARK: - AI segment block

private struct AISegmentBlock: View {
    let segment: ProviderSegment
    let descriptionExpanded: Bool
    let toggleExpand: () -> Void
    let phoneticEnabled: Bool
    let smartExplanationEnabled: Bool
    let sourceText: String

    @State private var copyFeedbackKey: String? = nil
    @State private var copyResetTask: Task<Void, Never>?
    private let speaker = TooltipSpeaker()

    var body: some View {
        // Tight 2pt outer spacing — the previous 4pt left a visible gap
        // between the translation row and the description chevron that
        // made the section feel airier than the API rows above.
        VStack(alignment: .leading, spacing: 2) {
            header
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

    private var header: some View {
        HStack(spacing: 6) {
            Text(segment.modelHint ?? segment.displayName)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch segment.state {
        case .loading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 2)
        case .streaming(_, let output):
            translationItems(output, isStreaming: true)
        case .success(let output, _, _, _):
            translationItems(output, isStreaming: false)
        case .failure(let error):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let message = error.message {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func translationItems(_ output: TranslationOutput, isStreaming: Bool) -> some View {
        let items = output.items
        if items.isEmpty {
            if isStreaming {
                HStack {
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 2)
            } else {
                placeholderText("")
            }
        } else if items.count == 1 {
            singleMeaningRow(items[0], isStreaming: isStreaming)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    multiMeaningRow(item, copyKey: "ai.multi.\(offset)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func singleMeaningRow(_ text: String, isStreaming: Bool) -> some View {
        let key = "ai.single"
        let isPlaceholder = text.isEmpty && isStreaming
        return HStack(alignment: .top, spacing: 7) {
            if isPlaceholder {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                copyButton(text: text, key: key, tooltip: L.pick("Copy translation", "复制译文"))
            }
        }
    }

    private func multiMeaningRow(_ text: String, copyKey: String) -> some View {
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
            copyButton(text: text, key: copyKey, tooltip: L.pick("Copy this", "复制这一条"))
        }
        .padding(.vertical, 1)
    }

    private func copyButton(text: String, key: String, tooltip: String) -> some View {
        let copied = copyFeedbackKey == key
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copyResetTask?.cancel()
            copyFeedbackKey = key
            copyResetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if !Task.isCancelled { copyFeedbackKey = nil }
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

    private func placeholderText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if phoneticEnabled, let phonetic = segment.state.output.phonetic, !phonetic.isEmpty {
                Button {
                    speaker.speak(sourceText)
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
                Button(action: toggleExpand) {
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
