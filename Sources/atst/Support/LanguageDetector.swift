import Foundation
import NaturalLanguage

/// On-device language identification via NaturalLanguage. Used for the
/// tooltip's source-language label, the reverse-translation decision and
/// picking a speech voice — none of which should wait on a network call.
enum LanguageDetector {
    struct Detection {
        /// BCP-47 tag: "en", "zh-Hans", "ja".
        let code: String
        /// 0…1. Short single words score low ("bank" ≈ 0.3), so callers
        /// that act on the result rather than display it should gate on it.
        let confidence: Double
    }

    /// Dominant language of `text`, or nil when the recognizer can't decide.
    static func detect(_ text: String) -> Detection? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        return Detection(code: language.rawValue, confidence: confidence)
    }

    /// Primary language subtag: "zh-Hant" → "zh". The recognizer's
    /// Simplified / Traditional split is unreliable on short text, so
    /// comparisons and labels work at the language level.
    static func primary(_ code: String) -> String {
        code.split(separator: "-").first.map(String.init) ?? code
    }

    /// Human-readable language name in the current UI language
    /// ("English" / "英语", "Chinese" / "中文"), falling back to the tag.
    static func displayName(for code: String) -> String {
        let locale = Locale(identifier: L.isChinese ? "zh_CN" : "en_US")
        let base = primary(code)
        return locale.localizedString(forIdentifier: base) ?? base
    }
}
