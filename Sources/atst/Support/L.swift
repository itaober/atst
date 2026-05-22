import Foundation

/// User-facing UI language preference.
///
/// - `auto`: follow the system's preferred language; the only Chinese
///   branch we honour today maps to "any zh-* locale".
/// - `english` / `chinese`: hard override, ignores system locale.
enum UILanguage: String, Codable, CaseIterable, Equatable {
    case auto
    case english
    case chinese
}

/// Bilingual string helper. We default to English everywhere and only fall back
/// to the Chinese variant when the active UI language is Chinese (system
/// language `zh-*`, or the user explicitly picked 中文 in settings). All UI
/// strings should be wrapped in `L.pick(en:zh:)` so the entire UI flips together.
enum L {
    /// Runtime override driven by `AppConfiguration.uiLanguage`. AppDelegate
    /// keeps this in sync on launch and on every settings change. Pure static
    /// state instead of an ObservableObject because every `L.pick` call would
    /// otherwise need to access an injected dependency — and the views that
    /// render those strings already observe `settingsStore.configuration`, so
    /// they re-evaluate when the override flips.
    static var override: UILanguage = .auto

    static var isChinese: Bool {
        switch override {
        case .auto:
            let lang = (Locale.preferredLanguages.first ?? "en").lowercased()
            return lang.hasPrefix("zh")
        case .english:
            return false
        case .chinese:
            return true
        }
    }

    static func pick(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }
}
