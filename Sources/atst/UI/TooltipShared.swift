import AppKit
import AVFoundation
import SwiftUI

// MARK: - Visual effect background

/// Shared NSVisualEffectView backdrop used by both the live tooltip and
/// pinned notes. Corner radius is applied at the layer level so AppKit
/// owns the rounded clip — this avoids the visible lag you get when SwiftUI
/// tries to clip a hosted NSVisualEffectView during a frame-by-frame resize.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.layer?.cornerRadius = cornerRadius
    }
}

// MARK: - Collapsible section

/// Smoothly animates an inline section from height `0` to its measured
/// natural height (and back) by always keeping a hidden measurement copy in
/// the layout. The visible copy fades while the container's height
/// interpolates between the two endpoints — SwiftUI owns the whole
/// animation, AppKit only follows the SwiftUI fitting size frame-by-frame.
struct CollapsibleSection<Content: View>: View {
    let isExpanded: Bool
    let animation: Animation
    @ViewBuilder var content: () -> Content

    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            content()
                .fixedSize(horizontal: false, vertical: true)
                .readHeight { measuredHeight = $0 }
                .opacity(0)
                .allowsHitTesting(false)

            content()
                .fixedSize(horizontal: false, vertical: true)
                .opacity(isExpanded ? 1 : 0)
        }
        .frame(height: isExpanded ? measuredHeight : 0, alignment: .top)
        .clipped()
        .animation(animation, value: isExpanded)
    }
}

// MARK: - Preference keys + size / height readers

struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

extension View {
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: HeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(HeightPreferenceKey.self, perform: onChange)
    }

    func readSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: SizePreferenceKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(SizePreferenceKey.self, perform: onChange)
    }
}

// MARK: - Markdown rendering

enum TooltipMarkdown {
    /// Inline-only parse that always returns *something*. Block elements
    /// (headings, code fences) get collapsed to plain text — that's fine
    /// because our `<atst-desc>` is conventional inline-style content.
    static func render(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attr = try? AttributedString(markdown: source, options: options) {
            return attr
        }
        return AttributedString(source)
    }
}

/// Indented explanation block with an accent-coloured leading bar.
/// Shared between live tooltip and pinned notes so the look stays in sync.
struct TooltipDescription: View {
    let markdown: String

    var body: some View {
        Text(TooltipMarkdown.render(markdown))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.accentColor.opacity(0.45))
                    .frame(width: 2)
                    .padding(.top, 8)
            }
    }
}

// MARK: - Speech

/// Tiny `AVSpeechSynthesizer` wrapper used by tooltip footers to pronounce
/// the source text when the phonetic pill is tapped. Chooses voice locale
/// by detecting whether the input is pure ASCII.
@MainActor
final class TooltipSpeaker {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: detectLanguage(for: trimmed))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(utterance)
    }

    private func detectLanguage(for text: String) -> String {
        if text.unicodeScalars.contains(where: { $0.value > 0x7F }) {
            return Locale.current.identifier
        }
        return "en-US"
    }
}
