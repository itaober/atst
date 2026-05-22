import AppKit
import Combine
import Foundation

@MainActor
final class TranslatorViewModel: ObservableObject {
    @Published private(set) var state: TranslationState = .idle
    @Published private(set) var configuration: AppConfiguration
    @Published var pinned: Bool = false

    private let settingsStore: SettingsStore
    private let selectedTextProvider: SelectedTextProvider
    private var cancellables = Set<AnyCancellable>()
    /// Tasks driving the currently-visible text translation — one per
    /// active provider segment. Replaced wholesale whenever a new
    /// selection arrives so older results can't write into the newer state.
    private var activeTextSegmentTasks: [Task<Void, Never>] = []

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.configuration = settingsStore.configuration
        self.selectedTextProvider = SelectedTextProvider()

        settingsStore.$configuration
            .sink { [weak self] configuration in
                self?.configuration = configuration
            }
            .store(in: &cancellables)
    }

    func readCurrentSelection() async throws -> SelectedText {
        try await selectedTextProvider.selectedText()
    }

    /// Seed the visible state with placeholder segments so the tooltip can
    /// render its spinners immediately, before any provider has replied.
    /// Caller invokes this synchronously from the hotkey handler so we beat
    /// the network on screen.
    func beginTextTranslation(source: String) {
        let segments = makePlaceholderSegments()
        if segments.api.isEmpty && segments.ai == nil {
            state = .text(TextSegments(source: source, api: [], ai: nil, bothDisabled: true))
        } else {
            state = .text(TextSegments(
                source: source,
                api: segments.api,
                ai: segments.ai,
                bothDisabled: false
            ))
        }
    }

    func beginScreenshotTranslation() {
        state = .screenshotLoading(
            message: L.pick("Translating…", "翻译中…"),
            model: configuration.screenshotModel,
            source: L.pick("Screenshot translation", "截图翻译")
        )
    }

    /// Transitional state shown while we're running Vision OCR on the
    /// freshly-captured screenshot, before any provider has been touched.
    /// Reuses the `.screenshotLoading` case with a different message so
    /// the tooltip just shows a spinner + the right text; once OCR is
    /// done AppDelegate calls `beginTextTranslation(...)` and the state
    /// transitions into the regular dual-segment text UI.
    func beginScreenshotOCR() {
        state = .screenshotLoading(
            message: L.pick("Recognising text…", "识别截图文字…"),
            model: "",
            source: L.pick("Screenshot translation", "截图翻译")
        )
    }

    /// Kick off the configured text providers in parallel. Cache lookups
    /// happen per-segment up front; on cache miss we spawn a Task per
    /// provider and let each one update its own segment as it completes.
    func translateSelection(_ selection: SelectedText, bypassCache: Bool = false) async {
        cancelActiveTextTasks()

        let providers = buildEnabledProviders()
        if noTranslatorEnabled {
            // Both top-level switches are off — short-circuit to the
            // empty-state tooltip with the "Open settings" CTA.
            state = .text(TextSegments(
                source: selection.text,
                api: [],
                ai: nil,
                bothDisabled: true
            ))
            return
        }
        if providers.isEmpty {
            // Switches are on but every resolved provider was filtered out
            // (e.g. API toggle on with every provider disabled). Render an
            // explanatory empty state so the user doesn't get a silent
            // tooltip with no segments.
            state = .text(TextSegments(
                source: selection.text,
                api: [],
                ai: nil,
                bothDisabled: true
            ))
            return
        }

        // Seed segments with a loading state so the tooltip lays out
        // immediately. Cache hits flip individual segments to .success on
        // the same frame.
        var apiSegments: [ProviderSegment] = []
        var aiSegment: ProviderSegment? = nil
        for provider in providers {
            let id = provider.id
            let cachedEntry = bypassCache ? nil : lookupCache(for: provider, source: selection.text)
            let initialState: SegmentState
            if let entry = cachedEntry {
                initialState = .success(output: entry.output, latencyMs: nil, fromCache: true, cacheInfo: TranslationCache.CacheInfo(cachedAt: entry.createdAt, source: entry.source))
            } else {
                initialState = .loading
            }
            let segment = ProviderSegment(
                id: id,
                displayName: provider.displayName,
                modelHint: provider.modelHint,
                state: initialState
            )
            if id.segmentKind == .ai {
                aiSegment = segment
            } else {
                apiSegments.append(segment)
            }
        }

        state = .text(TextSegments(
            source: selection.text,
            api: apiSegments,
            ai: aiSegment,
            bothDisabled: false
        ))

        // For each provider that wasn't a cache hit, kick off a Task. Each
        // task updates its own segment in place; tasks are independent so
        // a fast provider lands first even if a slow one is still running.
        for provider in providers {
            let segment = segment(for: provider.id)
            if case .success(_, _, true, _) = segment?.state {
                continue
            }
            let task: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.run(provider: provider, source: selection.text)
            }
            activeTextSegmentTasks.append(task)
        }
    }

    func translateScreenshot(_ capture: ScreenshotCapture) async {
        do {
            let service = ScreenshotVisionService(configuration: configuration)
            let raw = try await service.streamTranslateScreenshot(capture.imageData) { [weak self] delta in
                self?.appendScreenshotDelta(delta)
            }
            let output = TranslationOutputParser.parse(raw)
            let trimmed = output.result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || Self.looksLikeNoTextFallback(trimmed) {
                let preview = raw.replacingOccurrences(of: "\n", with: " ").prefix(300)
                AppLogger.log("screenshot translation flagged as no-text. rawLen=\(raw.count) parsedLen=\(trimmed.count) screenshotPath=\(capture.savedPath) rawPreview=\(preview)")
                state = .failure(DisplayError(AppError.noScreenshotText))
            } else {
                AppLogger.log("screenshot translation ok parsedLen=\(trimmed.count) screenshotPath=\(capture.savedPath)")
                state = .screenshotSuccess(
                    output: output,
                    source: L.pick("Screenshot translation", "截图翻译"),
                    model: configuration.screenshotModel
                )
            }
        } catch {
            state = .failure(DisplayError(error))
        }
    }

    func showError(_ error: Error) {
        state = .failure(DisplayError(error))
    }

    func setTargetLanguage(_ language: String) {
        var next = configuration
        next.targetLanguage = language
        try? settingsStore.save(next)
    }

    func reloadConfiguration() {
        settingsStore.reload()
        state = .idle
    }

    // MARK: - Provider plumbing

    /// Build the list of providers we should fan out to, honoring the AI/API
    /// top-level toggles. AI is always included when `aiEnabled` is on —
    /// even without a configured model — so the AI segment can surface a
    /// "model not configured" error inline instead of silently disappearing.
    /// API providers come from the user's enabled list in the order they're
    /// defined in settings.
    private func buildEnabledProviders() -> [TranslationProvider] {
        var providers: [TranslationProvider] = []
        if configuration.apiEnabled {
            for kind in configuration.enabledAPIProviderKinds {
                if let provider = makeProvider(for: kind) {
                    providers.append(provider)
                }
            }
        }
        if configuration.aiEnabled {
            providers.append(OpenAIProvider(configuration: configuration))
        }
        return providers
    }

    /// True only when the user has flipped both top-level switches off.
    /// "AI on but no model" or "API on with all providers disabled" are
    /// surfaced inline as segment errors / empty rows instead of via this
    /// global empty-state path.
    private var noTranslatorEnabled: Bool {
        !configuration.aiEnabled && !configuration.apiEnabled
    }

    private func makeProvider(for kind: TranslationProviderID) -> TranslationProvider? {
        switch kind {
        case .ai:
            return OpenAIProvider(configuration: configuration)
        case .google:
            return GoogleProvider(targetLanguage: configuration.targetLanguage)
        case .microsoft:
            return MicrosoftProvider(targetLanguage: configuration.targetLanguage)
        }
    }

    /// Pre-flight placeholder segments used by `beginTextTranslation`. Mirrors
    /// what `translateSelection` will seed once it has the selection, so the
    /// hotkey-to-first-frame path doesn't flash an empty tooltip.
    private func makePlaceholderSegments() -> (api: [ProviderSegment], ai: ProviderSegment?) {
        var apiSegments: [ProviderSegment] = []
        if configuration.apiEnabled {
            for kind in configuration.enabledAPIProviderKinds {
                let provider = makeProvider(for: kind)
                apiSegments.append(ProviderSegment(
                    id: kind,
                    displayName: provider?.displayName ?? kind.rawValue,
                    modelHint: provider?.modelHint,
                    state: .loading
                ))
            }
        }
        var aiSegment: ProviderSegment? = nil
        if configuration.aiEnabled {
            let provider = OpenAIProvider(configuration: configuration)
            aiSegment = ProviderSegment(
                id: .ai,
                displayName: provider.displayName,
                modelHint: provider.modelHint,
                state: .loading
            )
        }
        return (apiSegments, aiSegment)
    }

    private func cancelActiveTextTasks() {
        for task in activeTextSegmentTasks { task.cancel() }
        activeTextSegmentTasks.removeAll()
    }

    /// Drive a single provider's translate() stream and patch the matching
    /// segment in `state` on each emission / final / failure. Streaming
    /// providers (AI) call this with many emissions; APIs call once.
    private func run(provider: TranslationProvider, source: String) async {
        let started = Date()
        let cacheKey = cacheKey(for: provider, source: source)
        do {
            for try await emission in provider.translate(text: source) {
                try Task.checkCancellation()
                let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
                if emission.isFinal {
                    updateSegment(id: provider.id) { segment in
                        segment.state = .success(
                            output: emission.output,
                            latencyMs: latencyMs,
                            fromCache: false,
                            cacheInfo: nil
                        )
                    }
                    // Cache only successful, non-untranslatable results that
                    // actually produced content.
                    if let key = cacheKey,
                       Self.shouldCache(source: source, output: emission.output) {
                        let cacheSource: TranslationCache.Source = provider.id.segmentKind == .ai ? .ai : .api
                        TranslationCache.shared.put(
                            key: key,
                            source: cacheSource,
                            output: emission.output,
                            model: provider.modelHint ?? provider.displayName,
                            sourceText: source
                        )
                    } else {
                        AppLogger.log("cache skipped for \(provider.id.rawValue): untranslatable=\(emission.output.untranslatable)")
                    }
                } else {
                    updateSegment(id: provider.id) { segment in
                        segment.state = .streaming(raw: emission.raw, output: emission.output)
                    }
                }
            }
        } catch is CancellationError {
            // Surface nothing — a newer translation has already replaced our
            // segments; writing into a stale segment would race.
        } catch {
            updateSegment(id: provider.id) { segment in
                segment.state = .failure(DisplayError(error))
            }
            AppLogger.log("provider \(provider.id.rawValue) failed: \(error)")
        }
    }

    private func cacheKey(for provider: TranslationProvider, source: String) -> String? {
        switch provider.id.segmentKind {
        case .ai:
            return TranslationCache.makeAIKey(text: source, configuration: configuration)
        case .api:
            return TranslationCache.makeProviderKey(
                providerID: provider.id,
                text: source,
                targetLanguage: configuration.targetLanguage
            )
        }
    }

    private func lookupCache(for provider: TranslationProvider, source: String) -> TranslationCache.Entry? {
        guard let key = cacheKey(for: provider, source: source) else { return nil }
        return TranslationCache.shared.get(key: key)
    }

    private func segment(for id: TranslationProviderID) -> ProviderSegment? {
        guard case .text(let segments) = state else { return nil }
        if let api = segments.api.first(where: { $0.id == id }) { return api }
        if segments.ai?.id == id { return segments.ai }
        return nil
    }

    /// Mutate the segment matching `id` in place. No-op if the current state
    /// isn't a text translation or no segment matches — covers the race
    /// where a newer selection arrived between this task's await and now.
    private func updateSegment(id: TranslationProviderID, mutate: (inout ProviderSegment) -> Void) {
        guard case .text(var segments) = state else { return }
        if let index = segments.api.firstIndex(where: { $0.id == id }) {
            mutate(&segments.api[index])
            state = .text(segments)
            return
        }
        if var ai = segments.ai, ai.id == id {
            mutate(&ai)
            segments.ai = ai
            state = .text(segments)
        }
    }

    private func appendScreenshotDelta(_ delta: String) {
        let current: String
        if case .screenshotStreaming(let raw, _, _, _) = state {
            current = raw
        } else {
            current = ""
        }
        let updated = current + delta
        let output = TranslationOutputParser.parse(updated)
        state = .screenshotStreaming(
            raw: updated,
            output: output,
            model: configuration.screenshotModel,
            source: L.pick("Screenshot translation", "截图翻译")
        )
    }

    /// Decide whether a successful translation should land in the local
    /// cache. Skip when any of the following hold — caching long, unique,
    /// or low-value entries just bloats the LRU without ever paying off.
    ///
    /// Hit-rate gates (cheap):
    ///   1. Source spans multiple lines — paragraphs / articles / code
    ///      blocks. Re-selection probability ≈ 0.
    ///   2. Source longer than ~200 chars — even single-line, a sentence
    ///      that long is almost certainly something the user pasted
    ///      once and won't paste again.
    ///   3. Source contains an http/https URL — we don't translate URLs,
    ///      and any "translation" of a URL-containing chunk is best-effort.
    ///
    /// Quality gates:
    ///   4. Provider tagged the input as untranslatable (model self-report
    ///      for AI, source==result heuristic for API).
    ///   5. Output echoed the source unchanged (modulo case + whitespace)
    ///      with no extras — defensive fallback in case the flag was missed.
    ///   6. Result trimmed of whitespace + punctuation is empty — there
    ///      is nothing useful to remember.
    private static func shouldCache(source: String, output: TranslationOutput) -> Bool {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)

        // Hit-rate gates
        if trimmedSource.contains("\n") || trimmedSource.contains("\r") {
            return false
        }
        if trimmedSource.count > 200 {
            return false
        }
        if trimmedSource.range(of: #"https?://"#, options: .regularExpression) != nil {
            return false
        }

        // Quality gates
        if output.untranslatable { return false }
        guard let first = output.items.first else { return false }
        let strippedFirst = first.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if strippedFirst.isEmpty {
            return false
        }
        let normSource = trimmedSource.lowercased()
        let normResult = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normSource == normResult, !output.hasDescription, !output.hasPhonetic {
            return false
        }
        return true
    }

    private static func looksLikeNoTextFallback(_ text: String) -> Bool {
        guard text.count <= 60 else { return false }
        let collapsed = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .lowercased()
        let needles = [
            "没有识别到可翻译",
            "没有可翻译",
            "未识别到",
            "未发现可翻译",
            "(notext)",
            "notranslatabletext",
            "notext"
        ]
        return needles.contains { collapsed.contains($0) }
    }
}

// MARK: - State model

/// Top-level translation state — the single source of truth the tooltip and
/// pinned-note logic observe.
enum TranslationState: Equatable {
    case idle
    /// Text translation in flight or complete. Carries the per-segment
    /// states (API rows + optional AI row). `bothDisabled == true` means
    /// the user has neither AI nor API enabled; the UI renders an empty
    /// state with a "Open settings" prompt.
    case text(TextSegments)
    case screenshotLoading(message: String, model: String, source: String)
    case screenshotStreaming(raw: String, output: TranslationOutput, model: String, source: String)
    case screenshotSuccess(output: TranslationOutput, source: String, model: String)
    case failure(DisplayError)
}

/// Snapshot of all text segments for a single translation. Stored inside
/// `TranslationState.text(...)`.
struct TextSegments: Equatable {
    var source: String
    /// API provider rows, in user-configured order. Always rendered above
    /// the AI row.
    var api: [ProviderSegment]
    /// Optional AI row (gpt-4o, claude, ollama, …).
    var ai: ProviderSegment?
    /// True iff both AI and API switches are off — UI shows an empty-state
    /// "no provider enabled" prompt with a "Open settings" CTA.
    var bothDisabled: Bool

    var hasAnyContent: Bool {
        if let ai = ai, ai.state.hasContent { return true }
        return api.contains { $0.state.hasContent }
    }

    var hasAnyTerminalSuccess: Bool {
        if let ai = ai, case .success = ai.state { return true }
        return api.contains { if case .success = $0.state { return true } else { return false } }
    }

    var allSegments: [ProviderSegment] {
        if let ai = ai { return api + [ai] }
        return api
    }
}

/// Per-provider segment carrying everything the UI needs to render one row.
struct ProviderSegment: Equatable, Identifiable {
    let id: TranslationProviderID
    let displayName: String
    let modelHint: String?
    var state: SegmentState
}

/// Per-segment lifecycle state. AI hits `.streaming(...)` between `.loading`
/// and `.success`; API providers go straight from `.loading` to `.success`
/// or `.failure`.
enum SegmentState: Equatable {
    case loading
    case streaming(raw: String, output: TranslationOutput)
    case success(output: TranslationOutput, latencyMs: Int?, fromCache: Bool, cacheInfo: TranslationCache.CacheInfo?)
    case failure(DisplayError)

    var hasContent: Bool {
        switch self {
        case .streaming(_, let output): return !output.items.isEmpty
        case .success(let output, _, _, _): return !output.items.isEmpty
        case .loading, .failure: return false
        }
    }

    /// `TranslationOutput` derived from this state for read-only display.
    var output: TranslationOutput {
        switch self {
        case .streaming(_, let output): return output
        case .success(let output, _, _, _): return output
        case .loading, .failure: return .empty
        }
    }
}

extension TranslationState {
    /// Convenience: which segment currently makes the most sense to copy
    /// when the user uses a global "copy" shortcut. Returns the AI result
    /// when available, otherwise the first successful API segment.
    var copyableText: String? {
        switch self {
        case .text(let segments):
            if let ai = segments.ai, case .success(let output, _, _, _) = ai.state {
                return output.result.isEmpty ? nil : output.result
            }
            for segment in segments.api {
                if case .success(let output, _, _, _) = segment.state, !output.result.isEmpty {
                    return output.result
                }
            }
            return nil
        case .screenshotStreaming(_, let output, _, _):
            return output.result.isEmpty ? nil : output.result
        case .screenshotSuccess(let output, _, _):
            return output.result
        case .idle, .screenshotLoading, .failure:
            return nil
        }
    }

    var sourceText: String {
        switch self {
        case .text(let segments): return segments.source
        case .screenshotLoading(_, _, let source),
             .screenshotStreaming(_, _, _, let source),
             .screenshotSuccess(_, let source, _):
            return source
        case .idle, .failure: return ""
        }
    }

    /// Convenience accessor for the live-tooltip auto-expand logic and the
    /// pin-as-note snapshot path. Returns the AI segment's output if it
    /// exists, falling back to the first successful API segment.
    var currentOutput: TranslationOutput {
        switch self {
        case .text(let segments):
            if let ai = segments.ai {
                let output = ai.state.output
                if !output.items.isEmpty { return output }
            }
            for segment in segments.api {
                let output = segment.state.output
                if !output.items.isEmpty { return output }
            }
            return .empty
        case .screenshotStreaming(_, let output, _, _),
             .screenshotSuccess(let output, _, _):
            return output
        case .idle, .screenshotLoading, .failure:
            return .empty
        }
    }
}

struct DisplayError: Equatable {
    var title: String
    var message: String?

    init(_ error: Error) {
        let fallback = L.pick("Something went wrong", "出错了")
        if let localizedError = error as? LocalizedError {
            title = localizedError.errorDescription ?? fallback
            message = localizedError.recoverySuggestion
        } else {
            title = fallback
            message = error.localizedDescription
        }
    }
}
