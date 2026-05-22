import Foundation

/// Unofficial Google translate-pa endpoint adapter. Same one used by the
/// `wt_lib` web translation widget, no user key required — the
/// `X-Goog-API-Key` is a public client identifier baked into Google's own
/// JS. May break or get rate-limited at any time; we surface a clean error
/// when that happens so the user can disable it from settings.
///
/// Request shape:
///   POST https://translate-pa.googleapis.com/v1/translateHtml
///   Headers:
///     Content-Type: application/json+protobuf
///     X-Goog-API-Key: <baked-in public key>
///   Body (positional protobuf JSON):
///     [[[<text>], <from>, <to>], "wt_lib"]
///
/// Response shape:
///   [[ "<html-encoded translation>" ], "<detected source lang>"]
struct GoogleProvider: TranslationProvider {
    let id: TranslationProviderID = .google
    let displayName: String = "Google"
    let modelHint: String? = nil
    let targetLanguage: String

    private let endpoint = URL(string: "https://translate-pa.googleapis.com/v1/translateHtml")!
    /// Public client API key shipped in Google's own translate widget JS.
    /// Not a secret; surfaces here because the endpoint rejects requests
    /// without it.
    private let apiKey = "AIzaSyATBXajvzQLTDHEQbcpq0Ihe0vWDHmO520"

    /// Best-effort connection prewarm — fire a tiny request so URLSession
    /// has a pooled TCP+TLS connection ready for the first real translation.
    /// Same trick we use for the AI endpoint.
    static func prewarm() {
        var request = URLRequest(url: URL(string: "https://translate-pa.googleapis.com/")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.log("google prewarmed status=\(status)")
        }.resume()
    }

    func translate(text: String) -> AsyncThrowingStream<TranslationProviderEmission, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let emission = try await performTranslate(text: text)
                    try Task.checkCancellation()
                    continuation.yield(emission)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performTranslate(text: String) async throws -> TranslationProviderEmission {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.emptyTranslation
        }
        // `"auto"` lets Google auto-detect the source language; an empty
        // string is rejected with HTTP 400 by this endpoint.
        let toCode = LanguageCode.bcp47(from: targetLanguage) ?? "en"

        // translateHtml accepts a single text or an array of texts and
        // returns a parallel array of translations. Critically: it
        // collapses any `\n` inside a single text into a single output
        // blob (newlines / paragraph structure / markdown list breaks
        // all disappear). To preserve the source's line structure we
        // split by `\n`, send the non-blank lines as separate array
        // entries, and reassemble afterwards — empty lines are kept at
        // their original index without burning a slot in the request.
        let lines = text.components(separatedBy: "\n")
        let payloadIndices = lines.indices.filter { idx in
            !lines[idx].trimmingCharacters(in: .whitespaces).isEmpty
        }
        let payloadLines = payloadIndices.map { lines[$0] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-API-Key")

        // Positional protobuf-as-JSON shape — order matters, no keys.
        let body: [Any] = [
            [payloadLines, "auto", toCode],
            "wt_lib"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let started = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            throw AppError.aiUnavailable("Google: \(urlError.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.aiRequestFailed("Google returned an unrecognised response")
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        AppLogger.log("google translate status=\(http.statusCode) bytes=\(data.count) latencyMs=\(latency) lines=\(payloadLines.count)")

        guard (200..<300).contains(http.statusCode) else {
            let bodyPreview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            throw AppError.aiRequestFailed("Google HTTP \(http.statusCode): \(bodyPreview)")
        }

        let translatedLines = try parseResponse(data: data)
        // Defensive: count mismatch shouldn't happen under normal
        // operation (Google echoes the same array length), but if the
        // server changes shape we'd rather fail loud than silently mis-
        // align translations to source lines.
        guard translatedLines.count == payloadLines.count else {
            throw AppError.aiRequestFailed("Google: line count mismatch (sent \(payloadLines.count), got \(translatedLines.count))")
        }

        // Reassemble: drop translated lines back into their original
        // indices, blank lines stay blank. HTML-decode each line as we
        // go since Google returns `&amp;` / `&#39;` etc.
        var assembled = lines
        for (slotIndex, originalIndex) in payloadIndices.enumerated() {
            assembled[originalIndex] = HTMLEntityDecoder.decode(translatedLines[slotIndex])
        }
        let decoded = assembled.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { throw AppError.emptyTranslation }

        let untranslatable = looksUntranslatable(source: text, result: decoded)
        let output = TranslationOutput(
            result: decoded,
            items: [decoded],
            phonetic: nil,
            description: nil,
            untranslatable: untranslatable
        )
        return TranslationProviderEmission(output: output, raw: decoded, isFinal: true)
    }

    /// Parse the Google translateHtml response into an array of
    /// translated strings. Expected shape:
    ///   [["<trans_1>", "<trans_2>", ...], ["<detected_lang_1>", ...]]
    /// Falls back to defensively handling either single-string or
    /// single-array first elements so a minor server-side change
    /// doesn't crash us hard.
    private func parseResponse(data: Data) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let outer = json as? [Any] else {
            throw AppError.aiRequestFailed("Google: unexpected response shape")
        }
        if let firstArray = outer.first as? [Any] {
            let strings = firstArray.compactMap { $0 as? String }
            if !strings.isEmpty {
                return strings
            }
        }
        if let firstString = outer.first as? String {
            return [firstString]
        }
        throw AppError.aiRequestFailed("Google: unexpected response shape")
    }

    /// Heuristic: if the result (case-folded, whitespace-stripped) equals the
    /// input, we never actually translated anything — likely a proper noun
    /// or already-target-language input. Skip caching and tag the segment
    /// with the same gray status dot AI uses.
    private func looksUntranslatable(source: String, result: String) -> Bool {
        let normSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normResult = result.lowercased()
        return !normSource.isEmpty && normSource == normResult
    }
}
