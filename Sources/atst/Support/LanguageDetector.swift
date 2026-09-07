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
}
