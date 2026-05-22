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

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-API-Key")

        // Positional protobuf-as-JSON shape — order matters, no keys.
        let body: [Any] = [
            [[text], "auto", toCode],
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
        AppLogger.log("google translate status=\(http.statusCode) bytes=\(data.count) latencyMs=\(latency)")

        guard (200..<300).contains(http.statusCode) else {
            let bodyPreview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            throw AppError.aiRequestFailed("Google HTTP \(http.statusCode): \(bodyPreview)")
        }

        let parsed = try parseResponse(data: data)
        let decoded = HTMLEntityDecoder.decode(parsed).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Parse `[["<translated>"], "<detected>"]` defensively — handle either
    /// nested-array or flat-string shapes so a minor server-side change
    /// doesn't crash us hard.
    private func parseResponse(data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        if let outer = json as? [Any],
           let firstArray = outer.first as? [Any],
           let first = firstArray.first as? String {
            return first
        }
        if let outer = json as? [Any],
           let first = outer.first as? String {
            return first
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
