import Foundation
import NaturalLanguage

/// On-device language identification via NaturalLanguage. Used for the
/// tooltip's source-language label, the reverse-translation decision and
/// picking a speech voice — none of which should wait on a network call.
enum LanguageDetector {
    /// BCP-47 tag of the dominant language ("en", "zh-Hans", "ja"), or nil
    /// when the recognizer can't decide or its best guess is below
    /// `minimumConfidence`. Short single words are inherently ambiguous,
    /// so callers that act on the result (reverse translation) should
    /// pass a stricter threshold than callers that merely display it.
    static func detect(_ text: String, minimumConfidence: Double = 0) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        if minimumConfidence > 0 {
            let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
            guard confidence >= minimumConfidence else { return nil }
        }
        return language.rawValue
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
