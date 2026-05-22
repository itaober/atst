import Foundation

struct TranslationOutput: Equatable, Codable {
    /// The concatenated translation; for multi-meaning results this is `items` joined by newline,
    /// so a single "Copy" still produces sensible text. UI should render `items` when length > 1.
    var result: String
    /// One or more meanings. Always non-empty for a successful parse.
    var items: [String]
    var phonetic: String?
    var description: String?
    /// True when the model signaled `<atst-translatable>false</atst-translatable>`
    /// — input has no meaningful translation (proper noun / brand / code
    /// identifier / already-target-language). Callers skip caching those
    /// entries. Default `false` of this Swift field means "translatable"
    /// (no flag = normal translation).
    var untranslatable: Bool = false

    static let empty = TranslationOutput(result: "", items: [], phonetic: nil, description: nil, untranslatable: false)

    var hasPhonetic: Bool { !(phonetic ?? "").isEmpty }
    var hasDescription: Bool { !(description ?? "").isEmpty }
    var isMultiMeaning: Bool { items.count > 1 }
}

enum TranslationOutputParser {
    /// Parse a possibly-incomplete model response. During streaming the closing
    /// tag may not have arrived yet — in that case we fall back to "everything
    /// after the opening `<atst-result>`" as the in-progress result so the user
    /// sees text appearing token by token.
    static func parse(_ raw: String) -> TranslationOutput {
        let phonetic = extractClosedTag("atst-phonetic", from: raw)
        let description = extractClosedTag("atst-desc", from: raw)
        // `<atst-translatable>` is optional. We only recognise the literal
        // string `false` (case-insensitive). Anything else — absent, `true`,
        // empty, weird — is treated as translatable. Prompt teaches the
        // model to emit exactly `false` so we stay strict on input.
        let translatableTag = (extractClosedTag("atst-translatable", from: raw) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let untranslatable = translatableTag == "false"
        if let closed = extractClosedTag("atst-result", from: raw) {
            let items = extractItems(in: closed)
            return TranslationOutput(
                result: items.joined(separator: "\n"),
                items: items,
                phonetic: phonetic,
                description: description,
                untranslatable: untranslatable
            )
        }
        if let partial = extractAfterOpenTag("atst-result", in: raw) {
            let items = extractItems(in: partial)
            return TranslationOutput(
                result: items.joined(separator: "\n"),
                items: items,
                phonetic: phonetic,
                description: description,
                untranslatable: untranslatable
            )
        }
        // Model didn't emit any tag yet (or doesn't follow the protocol) —
        // fall back to whatever it's saying so the user isn't staring at a
        // blank panel.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranslationOutput(
            result: trimmed,
            items: trimmed.isEmpty ? [] : [trimmed],
            phonetic: phonetic,
            description: description,
            untranslatable: untranslatable
        )
    }

    /// Pull `<atst-item>...</atst-item>` blocks from a chunk. If we encounter
    /// any `<atst-item>` tag at all we treat the body as "tagged output" — even
    /// if every item turned out to be empty — and return an empty list so
    /// callers can surface a proper "no result" error instead of rendering
    /// the raw XML scaffolding to the user.
    private static func extractItems(in body: String) -> [String] {
        var items: [String] = []
        var sawAnyTag = false
        var cursor = body.startIndex
        while let openRange = body.range(of: "<atst-item>", range: cursor..<body.endIndex) {
            sawAnyTag = true
            let after = openRange.upperBound
            if let closeRange = body.range(of: "</atst-item>", range: after..<body.endIndex) {
                let inner = body[after..<closeRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty {
                    items.append(inner)
                }
                cursor = closeRange.upperBound
            } else {
                // Partial item still streaming — surface what's there so the
                // user sees text appearing token-by-token.
                let inner = body[after...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty {
                    items.append(inner)
                }
                break
            }
        }
        if !items.isEmpty { return items }
        if sawAnyTag {
            // Tags arrived but all empty — caller should treat as "no result".
            return []
        }
        // No tags at all (model ignored protocol) — fall back to raw body.
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }

    private static func extractClosedTag(_ tag: String, from raw: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let openRange = raw.range(of: open),
              let closeRange = raw.range(of: close, range: openRange.upperBound..<raw.endIndex) else {
            return nil
        }
        let inner = raw[openRange.upperBound..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    private static func extractAfterOpenTag(_ tag: String, in raw: String) -> String? {
        let open = "<\(tag)>"
        guard let openRange = raw.range(of: open) else { return nil }
        let trailing = raw[openRange.upperBound...]
        // Strip any partial trailing `<` so we don't show "<a" mid-token.
        var text = String(trailing)
        if let cut = text.range(of: "<", options: .backwards) {
            // Heuristic: only cut if the `<` has no matching `>` after it yet —
            // means it's the start of the closing tag we haven't finished.
            let after = text[cut.upperBound...]
            if !after.contains(">") {
                text = String(text[..<cut.lowerBound])
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
