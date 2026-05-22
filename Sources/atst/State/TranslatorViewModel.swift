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

    func beginTextTranslation(source: String) {
        state = .loading(message: "Translating…", model: configuration.textModel, mode: .text, source: source)
    }

    func beginScreenshotTranslation() {
        state = .loading(message: "Translating…", model: configuration.screenshotModel, mode: .screenshot, source: "截图翻译")
    }

    func translateSelection(_ selection: SelectedText, bypassCache: Bool = false) async {
        let cacheKey = TranslationCache.makeKey(text: selection.text, configuration: configuration)
        if !bypassCache, let entry = TranslationCache.shared.get(key: cacheKey) {
            state = .success(
                output: entry.output,
                source: selection.text,
                model: entry.model,
                mode: .text,
                cacheInfo: TranslationCache.CacheInfo(cachedAt: entry.createdAt, source: entry.source)
            )
            return
        }
        do {
            let service = TranslationService(configuration: configuration)
            let raw = try await service.streamTranslateText(selection.text) { [weak self] delta in
                self?.append(delta: delta, mode: .text, source: selection.text)
            }
            let output = TranslationOutputParser.parse(raw)
            if output.result.isEmpty {
                state = .failure(DisplayError(AppError.emptyTranslation))
            } else {
                state = .success(
                    output: output,
                    source: selection.text,
                    model: configuration.textModel,
                    mode: .text,
                    cacheInfo: nil
                )
                // Skip caching when the model flagged the input as
                // untranslatable, OR — defensively — when the model emitted
                // a pure echo (case/whitespace-normalised result equals
                // input). Both signal "no real translation happened" and
                // caching them just pollutes the LRU.
                if Self.shouldCacheTranslation(source: selection.text, output: output) {
                    TranslationCache.shared.put(
                        key: cacheKey,
                        source: .ai,
                        output: output,
                        model: configuration.textModel,
                        sourceText: selection.text
                    )
                } else {
                    AppLogger.log("cache skipped: untranslatable=\(output.untranslatable) text='\(selection.text.prefix(40))'")
                }
            }
        } catch {
            state = .failure(DisplayError(error))
        }
    }

    func translateScreenshot(_ capture: ScreenshotCapture) async {
        do {
            let service = TranslationService(configuration: configuration)
            let raw = try await service.streamTranslateScreenshot(capture.imageData) { [weak self] delta in
                self?.append(delta: delta, mode: .screenshot, source: "截图翻译")
            }
            let output = TranslationOutputParser.parse(raw)
            let trimmed = output.result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || Self.looksLikeNoTextFallback(trimmed) {
                // Log a slice of the raw response so we can tell apart
                // "model returned nothing" vs "model said it can't see text"
                // vs "model emitted text without <atst-result> tags".
                let preview = raw.replacingOccurrences(of: "\n", with: " ").prefix(300)
                AppLogger.log("screenshot translation flagged as no-text. rawLen=\(raw.count) parsedLen=\(trimmed.count) screenshotPath=\(capture.savedPath) rawPreview=\(preview)")
                state = .failure(DisplayError(AppError.noScreenshotText))
            } else {
                AppLogger.log("screenshot translation ok parsedLen=\(trimmed.count) screenshotPath=\(capture.savedPath)")
                // Screenshot results are intentionally not cached — each image
                // is unique and would bloat the cache.
                state = .success(
                    output: output,
                    source: "截图翻译",
                    model: configuration.screenshotModel,
                    mode: .screenshot,
                    cacheInfo: nil
                )
            }
        } catch {
            state = .failure(DisplayError(error))
        }
    }

    func showError(_ error: Error) {
        state = .failure(DisplayError(error))
    }

    func copyResult() {
        guard let text = state.copyableText else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    private func append(delta: String, mode: TranslationMode, source: String) {
        let current = state.streamingRaw ?? ""
        let updated = current + delta
        let output = TranslationOutputParser.parse(updated)
        state = .streaming(raw: updated, output: output, model: model(for: mode), mode: mode, source: source)
    }

    /// Decide whether a successful translation should land in the local
    /// cache. Skip when:
    ///   1. Model set `<atst-translatable>false</atst-translatable>` (or `0`) —
    ///      it self-reported "this has no real translation".
    ///   2. Model echoed the source unchanged (modulo case + whitespace) and
    ///      didn't add description content. Defensive fallback in case the
    ///      model forgot the explicit flag.
    private static func shouldCacheTranslation(source: String, output: TranslationOutput) -> Bool {
        if output.untranslatable { return false }
        guard let first = output.items.first else { return false }
        let normSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private func model(for mode: TranslationMode) -> String {
        switch mode {
        case .text:
            return configuration.textModel
        case .screenshot:
            return configuration.screenshotModel
        }
    }
}

enum TranslationState: Equatable {
    case idle
    case loading(message: String, model: String, mode: TranslationMode, source: String)
    case streaming(raw: String, output: TranslationOutput, model: String, mode: TranslationMode, source: String)
    case success(output: TranslationOutput, source: String, model: String, mode: TranslationMode, cacheInfo: TranslationCache.CacheInfo?)
    case failure(DisplayError)

    var copyableText: String? {
        switch self {
        case .streaming(_, let output, _, _, _):
            return output.result.isEmpty ? nil : output.result
        case .success(let output, _, _, _, _):
            return output.result
        case .idle, .loading, .failure:
            return nil
        }
    }

    var streamingRaw: String? {
        if case .streaming(let raw, _, _, _, _) = self {
            return raw
        }
        return nil
    }

    var sourceText: String {
        switch self {
        case .loading(_, _, _, let source):
            return source
        case .streaming(_, _, _, _, let source):
            return source
        case .success(_, let source, _, _, _):
            return source
        case .idle, .failure:
            return ""
        }
    }

    var currentOutput: TranslationOutput {
        switch self {
        case .streaming(_, let output, _, _, _):
            return output
        case .success(let output, _, _, _, _):
            return output
        case .idle, .loading, .failure:
            return .empty
        }
    }

    var activeModel: String? {
        switch self {
        case .loading(_, let model, _, _),
             .streaming(_, _, let model, _, _),
             .success(_, _, let model, _, _):
            return model
        case .idle, .failure:
            return nil
        }
    }

    var activeMode: TranslationMode? {
        switch self {
        case .loading(_, _, let mode, _),
             .streaming(_, _, _, let mode, _),
             .success(_, _, _, let mode, _):
            return mode
        case .idle, .failure:
            return nil
        }
    }

    /// `CacheInfo` present iff the success came from the local cache instead
    /// of a fresh AI call. Used by the UI to render a "cached • click to
    /// refresh" indicator.
    var cacheInfo: TranslationCache.CacheInfo? {
        if case .success(_, _, _, _, let info) = self {
            return info
        }
        return nil
    }
}

enum TranslationMode: Equatable {
    case text
    case screenshot
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
