import Foundation
import AppKit
import Vision

/// On-device text recognition for screenshot translation.
///
/// Wraps `VNRecognizeTextRequest` with an async/throws API. Runs on the
/// Neural Engine on Apple Silicon, ~100-300ms for typical screen regions,
/// fully offline, no token cost. Result quality is excellent on printed
/// text (web / IDE / PDF screenshots), middling on handwriting / stylized
/// fonts — see the comment on `recognize(...)` for fallback strategy.
enum VisionOCRService {
    /// Default recognition languages (BCP-47), tuned for the typical atst
    /// user: simplified Chinese, English, Japanese. Users can extend the
    /// list from settings. Order matters — Vision prefers earlier entries
    /// when text is ambiguous.
    static let defaultLanguages: [String] = ["zh-Hans", "en-US", "ja-JP"]

    /// Every language Vision can recognise (curated to the ones atst users
    /// are likely to need; the full list is much longer on newer macOS but
    /// they're rare in practice). Order = display priority in the settings
    /// add-language menu.
    static let supportedLanguages: [OCRLanguage] = [
        .init(code: "zh-Hans", english: "Chinese (Simplified)", chinese: "中文（简）"),
        .init(code: "zh-Hant", english: "Chinese (Traditional)", chinese: "中文（繁）"),
        .init(code: "en-US",   english: "English", chinese: "英文"),
        .init(code: "ja-JP",   english: "Japanese", chinese: "日文"),
        .init(code: "ko-KR",   english: "Korean", chinese: "韩文"),
        .init(code: "fr-FR",   english: "French", chinese: "法文"),
        .init(code: "de-DE",   english: "German", chinese: "德文"),
        .init(code: "es-ES",   english: "Spanish", chinese: "西班牙文"),
        .init(code: "it-IT",   english: "Italian", chinese: "意大利文"),
        .init(code: "pt-BR",   english: "Portuguese", chinese: "葡萄牙文"),
        .init(code: "ru-RU",   english: "Russian", chinese: "俄文"),
        .init(code: "uk-UA",   english: "Ukrainian", chinese: "乌克兰文")
    ]

    struct OCRLanguage: Identifiable, Equatable {
        let code: String
        let english: String
        let chinese: String
        var id: String { code }
        var displayName: String { L.pick(english, chinese) }
    }

    /// Run OCR on a PNG/JPEG image. Returns the recognised text, with each
    /// detected line joined by `\n`. Returns an empty string if Vision
    /// found nothing — caller decides whether to fall back to AI vision.
    ///
    /// - Parameters:
    ///   - imageData: raw PNG or JPEG bytes (whatever the screenshot file
    ///     contains). Vision auto-detects format.
    ///   - languages: BCP-47 codes; falls back to `defaultLanguages` if
    ///     empty.
    static func recognize(
        imageData: Data,
        languages: [String]
    ) async throws -> String {
        let activeLanguages = languages.isEmpty ? defaultLanguages : languages
        let started = Date()
        return try await withCheckedThrowingContinuation { continuation in
            // Hop off the calling actor — Vision blocks the calling thread
            // during inference. The Neural Engine runs in a separate
            // process, but we still don't want to block the main actor
            // while we wait for the request to issue.
            Task.detached(priority: .userInitiated) {
                do {
                    let text = try Self.runRequest(imageData: imageData, languages: activeLanguages)
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    AppLogger.log("vision ocr ok latencyMs=\(ms) chars=\(text.count) langs=\(activeLanguages.joined(separator: ","))")
                    continuation.resume(returning: text)
                } catch {
                    AppLogger.log("vision ocr failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Prewarm by running OCR against a tiny blank image so Vision loads
    /// its model into memory before the user fires the real hotkey. Saves
    /// ~150-250ms on the very first invocation. Idempotent.
    static func prewarm() {
        Task.detached(priority: .utility) {
            guard let data = makeBlankImageData() else { return }
            _ = try? Self.runRequest(imageData: data, languages: defaultLanguages)
            AppLogger.log("vision ocr prewarmed")
        }
    }

    // MARK: - Internals

    private static func runRequest(imageData: Data, languages: [String]) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(data: imageData, options: [:])
        try handler.perform([request])
        let observations = (request.results ?? [])
        // Join top candidate of each line with newlines. We deliberately
        // keep line breaks — they tend to map onto sentence / paragraph
        // boundaries on screen, and the downstream translation provider
        // handles multi-line input cleanly.
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 16×16 transparent PNG — small enough that Vision returns instantly
    /// but still triggers the model load + JIT path we want pre-warmed.
    private static func makeBlankImageData() -> Data? {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
