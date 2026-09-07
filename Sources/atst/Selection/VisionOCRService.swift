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
        return paragraphs(from: observations).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Vision emits one observation per visual line. Lines that are just
    /// soft-wrapped inside a paragraph get merged so the translators see
    /// whole sentences (Google / Microsoft translate line by line, and a
    /// wrapped paragraph fed as fragments comes back as fragments). A
    /// paragraph break — kept as a blank line — is inferred from a
    /// vertical gap wider than the line height, a left-edge shift (list
    /// items, headings, indent changes), or a bullet / numbering marker.
    private static func paragraphs(from observations: [VNRecognizedTextObservation]) -> String {
        struct Line { let text: String; let box: CGRect }
        let lines: [Line] = observations
            .compactMap { obs in
                guard let text = obs.topCandidates(1).first?.string else { return nil }
                return Line(text: text, box: obs.boundingBox)
            }
            .sorted { $0.box.maxY > $1.box.maxY }  // Vision boxes are bottom-left origin; top of screen first

        var result = ""
        var previous: Line?
        for line in lines {
            defer { previous = line }
            guard let prev = previous else {
                result = line.text
                continue
            }
            let lineHeight = max(prev.box.height, line.box.height)
            let gap = prev.box.minY - line.box.maxY
            let indentShift = abs(prev.box.minX - line.box.minX)
            let startsBlock = line.text.range(of: #"^\s*([•·\-\*–—]|\d+[.、)])\s"#, options: .regularExpression) != nil
            if gap > lineHeight * 0.8 || indentShift > 0.05 || startsBlock {
                result += "\n\n" + line.text
            } else {
                result += joiner(between: prev.text, and: line.text) + line.text
            }
        }
        return result
    }

    /// CJK text has no inter-word spaces, so wrapped CJK lines join
    /// directly; everything else gets a single space.
    private static func joiner(between prev: String, and next: String) -> String {
        guard let last = prev.unicodeScalars.last, let first = next.unicodeScalars.first else { return " " }
        return isCJK(last) || isCJK(first) ? "" : " "
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana + Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x3000...0x303F,   // CJK punctuation
             0xFF00...0xFFEF:   // Fullwidth forms
            return true
        default:
            return false
        }
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
