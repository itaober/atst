import Foundation

/// Bilingual string helper. We default to English everywhere and only fall back
/// to the Chinese variant when the user's preferred system language is Chinese
/// (Hans / Hant / generic). All UI strings should be wrapped in `L.pick(en:zh:)`
/// so the entire UI flips together.
enum L {
    static var isChinese: Bool {
        let lang = (Locale.preferredLanguages.first ?? "en").lowercased()
        return lang.hasPrefix("zh")
    }

    static func pick(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }
}
