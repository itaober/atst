import Foundation

/// Maps user-typed freeform language strings ("简体中文", "English",
/// "Japanese", "ja-JP", …) to BCP-47 codes that Google / Microsoft / DeepL
/// accept. AI providers don't need this — they take the freeform string
/// directly into the prompt.
///
/// Strategy: try a small built-in table first (covers the languages atst's
/// UI actually offers as defaults), then fall back to `Locale.identifier`
/// parsing. Returns `nil` only when the input is empty / unrecognisable, in
/// which case the caller should fall back to auto-detect.
enum LanguageCode {
    /// Map a user-typed string to a BCP-47 language code (`zh`, `en`, `ja`,
    /// `zh-Hant`, …). Case-insensitive, accepts both display names and
    /// existing codes.
    static func bcp47(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if let mapped = directMap[lower] { return mapped }
        // Already a code? Pass through if it parses as a Locale identifier.
        // Restrict to short tokens so we don't accept arbitrary strings.
        if lower.count <= 10, lower.range(of: "^[a-z]{2,3}(-[a-z0-9]{2,8})?$", options: .regularExpression) != nil {
            return lower.replacingOccurrences(of: "_", with: "-")
        }
        return nil
    }

    /// Tightly curated map. Covers our hard-coded default targets and the
    /// languages most likely to be typed by users — extend as needed. Keys
    /// are pre-lowercased.
    private static let directMap: [String: String] = [
        // Chinese
        "简体中文": "zh-CN",
        "繁体中文": "zh-TW",
        "繁體中文": "zh-TW",
        "中文": "zh-CN",
        "chinese": "zh-CN",
        "chinese (simplified)": "zh-CN",
        "chinese (traditional)": "zh-TW",
        "simplified chinese": "zh-CN",
        "traditional chinese": "zh-TW",
        "zh": "zh-CN",
        "zh-cn": "zh-CN",
        "zh-hans": "zh-CN",
        "zh-tw": "zh-TW",
        "zh-hant": "zh-TW",

        // English
        "english": "en",
        "英文": "en",
        "英语": "en",
        "en": "en",
        "en-us": "en",
        "en-gb": "en",

        // Japanese
        "japanese": "ja",
        "日本語": "ja",
        "日语": "ja",
        "ja": "ja",

        // Korean
        "korean": "ko",
        "한국어": "ko",
        "韩语": "ko",
        "ko": "ko",

        // French
        "french": "fr",
        "français": "fr",
        "法语": "fr",
        "法文": "fr",
        "fr": "fr",

        // German
        "german": "de",
        "deutsch": "de",
        "德语": "de",
        "de": "de",

        // Spanish
        "spanish": "es",
        "español": "es",
        "西班牙语": "es",
        "es": "es",

        // Portuguese
        "portuguese": "pt",
        "português": "pt",
        "葡萄牙语": "pt",
        "pt": "pt",

        // Russian
        "russian": "ru",
        "русский": "ru",
        "俄语": "ru",
        "ru": "ru",

        // Italian
        "italian": "it",
        "italiano": "it",
        "意大利语": "it",
        "it": "it",

        // Arabic
        "arabic": "ar",
        "العربية": "ar",
        "阿拉伯语": "ar",
        "ar": "ar",

        // Vietnamese
        "vietnamese": "vi",
        "tiếng việt": "vi",
        "越南语": "vi",
        "vi": "vi",

        // Thai
        "thai": "th",
        "ไทย": "th",
        "泰语": "th",
        "th": "th"
    ]
}

/// Tiny HTML entity decoder. Google's translate-pa endpoint returns
/// HTML-encoded payloads (`&amp;`, `&#39;`, `&quot;` etc.) regardless of
/// whether the source contained markup. We don't need a full HTML parser —
/// just convert the handful of entities Google actually emits.
enum HTMLEntityDecoder {
    static func decode(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        var result = raw
        // Order matters: numeric entities first so `&amp;#39;` doesn't end up
        // double-decoded.
        result = decodeNumericEntities(in: result)
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    private static let namedEntities: [(String, String)] = [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&nbsp;", " "),
        ("&#39;", "'"),
        ("&#x27;", "'"),
        ("&#x2F;", "/"),
        ("&#47;", "/"),
        ("&#x60;", "`"),
        ("&#x3D;", "=")
    ]

    /// Decode `&#NNNN;` and `&#xHHHH;` numeric entities. Leaves anything we
    /// can't parse untouched.
    private static func decodeNumericEntities(in raw: String) -> String {
        guard raw.contains("&#") else { return raw }
        var output = ""
        output.reserveCapacity(raw.count)
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "&",
               let semi = raw.range(of: ";", range: index..<raw.endIndex),
               raw.index(after: index) < raw.endIndex,
               raw[raw.index(after: index)] == "#" {
                let inner = raw[raw.index(index, offsetBy: 2)..<semi.lowerBound]
                let isHex = inner.first == "x" || inner.first == "X"
                let digits = isHex ? inner.dropFirst() : inner.dropFirst(0)
                if let scalarValue = UInt32(digits, radix: isHex ? 16 : 10),
                   let scalar = Unicode.Scalar(scalarValue) {
                    output.unicodeScalars.append(scalar)
                    index = semi.upperBound
                    continue
                }
            }
            output.append(raw[index])
            index = raw.index(after: index)
        }
        return output
    }
}
