import Foundation

/// Splits multi-line source text into per-line payload entries for the
/// batch-capable HTTP translators (Google / Microsoft). Both endpoints
/// collapse `\n` inside a single string, so line / paragraph structure is
/// only preserved by sending each non-blank line as its own array entry
/// and putting the translations back at their original indices.
struct LineBatch {
    private let lines: [String]
    private let payloadIndices: [Int]

    init(text: String) {
        let split = text.components(separatedBy: "\n")
        lines = split
        payloadIndices = split.indices.filter { idx in
            !split[idx].trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Non-blank lines, in source order. Send these to the endpoint.
    var payload: [String] { payloadIndices.map { lines[$0] } }

    /// Drop translated lines back into their original slots. Returns nil
    /// when the endpoint echoed a different number of entries — callers
    /// should fail loud rather than mis-align translations to lines.
    func merge(_ translated: [String]) -> String? {
        guard translated.count == payloadIndices.count else { return nil }
        var assembled = lines
        for (slot, originalIndex) in payloadIndices.enumerated() {
            assembled[originalIndex] = translated[slot]
        }
        return assembled.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
