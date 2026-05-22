import Foundation

/// Unofficial Microsoft Translator edge endpoint adapter. Same two-step
/// flow the Edge browser's built-in translator uses: fetch a short-lived
/// JWT, then call the translate endpoint with the JWT as both the `Bearer`
/// auth header and the `Ocp-Apim-Subscription-Key`. No user key required.
///
/// Stability tradeoff: same as Google — unofficial, may break or be
/// rate-limited; we surface clean errors when it does.
///
/// Step 1 (token):
///   GET https://edge.microsoft.com/translate/auth
///   → "<jwt>" (raw text response body)
///
/// Step 2 (translate):
///   POST https://api-edge.cognitive.microsofttranslator.com/translate
///     ?from=<from>&to=<to>&api-version=3.0&textType=plain
///   Headers:
///     Authorization: Bearer <token>
///     Ocp-Apim-Subscription-Key: <token>
///     Content-Type: application/json
///   Body: [{"Text":"<text>"}]
///   → [{"translations":[{"text":"<translated>","to":"<to>"}]}]
struct MicrosoftProvider: TranslationProvider {
    let id: TranslationProviderID = .microsoft
    let displayName: String = "Microsoft"
    let modelHint: String? = nil
    let targetLanguage: String

    private let authEndpoint = URL(string: "https://edge.microsoft.com/translate/auth")!
    private let translateBase = "https://api-edge.cognitive.microsofttranslator.com/translate"

    /// Prewarm by triggering a token fetch — keeps both the auth host and
    /// (via subsequent requests) the translate host warm. Idempotent because
    /// the token manager caches.
    static func prewarm() {
        Task.detached(priority: .utility) {
            _ = try? await MicrosoftAuthToken.shared.token()
        }
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
        guard !trimmed.isEmpty else { throw AppError.emptyTranslation }
        let toCode = LanguageCode.bcp47(from: targetLanguage) ?? "en"

        // One-shot retry on 401 — token may have expired between our last
        // fetch and this request despite our buffer.
        do {
            return try await translateOnce(text: text, target: toCode, forceRefresh: false)
        } catch let error as MicrosoftAuthError where error == .unauthorized {
            AppLogger.log("microsoft 401, retrying with fresh token")
            return try await translateOnce(text: text, target: toCode, forceRefresh: true)
        }
    }

    private func translateOnce(text: String, target: String, forceRefresh: Bool) async throws -> TranslationProviderEmission {
        let token: String
        do {
            token = try await MicrosoftAuthToken.shared.token(forceRefresh: forceRefresh)
        } catch {
            throw AppError.aiUnavailable("Microsoft auth: \(error.localizedDescription)")
        }

        var components = URLComponents(string: translateBase)!
        components.queryItems = [
            URLQueryItem(name: "from", value: ""),
            URLQueryItem(name: "to", value: target),
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "textType", value: "plain")
        ]
        guard let url = components.url else {
            throw AppError.aiRequestFailed("Microsoft: failed to build URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [["Text": text]], options: [])

        let started = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            throw AppError.aiUnavailable("Microsoft: \(urlError.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppError.aiRequestFailed("Microsoft returned an unrecognised response")
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        AppLogger.log("microsoft translate status=\(http.statusCode) bytes=\(data.count) latencyMs=\(latency)")

        if http.statusCode == 401 { throw MicrosoftAuthError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            throw AppError.aiRequestFailed("Microsoft HTTP \(http.statusCode): \(preview)")
        }

        let translated = try parseResponse(data: data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { throw AppError.emptyTranslation }
        let untranslatable = looksUntranslatable(source: text, result: translated)
        let output = TranslationOutput(
            result: translated,
            items: [translated],
            phonetic: nil,
            description: nil,
            untranslatable: untranslatable
        )
        return TranslationProviderEmission(output: output, raw: translated, isFinal: true)
    }

    private func parseResponse(data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        if let array = json as? [[String: Any]],
           let first = array.first,
           let translations = first["translations"] as? [[String: Any]],
           let firstTranslation = translations.first,
           let text = firstTranslation["text"] as? String {
            return text
        }
        throw AppError.aiRequestFailed("Microsoft: unexpected response shape")
    }

    private func looksUntranslatable(source: String, result: String) -> Bool {
        let normSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normResult = result.lowercased()
        return !normSource.isEmpty && normSource == normResult
    }
}

// MARK: - Token manager

enum MicrosoftAuthError: Error, Equatable {
    case unauthorized
    case fetchFailed(String)
}

/// Caches the Edge-translate JWT and refreshes lazily. Tokens are short
/// (typically 10 min). We parse the `exp` claim to drive refresh; if parsing
/// fails (token shape changed), we assume a conservative 8-minute lifetime.
actor MicrosoftAuthToken {
    static let shared = MicrosoftAuthToken()

    private var cachedToken: String?
    private var expiresAt: Date?
    /// Refresh if we're within this window of expiry — buys us a safety
    /// margin for clock skew and round-trip latency.
    private let refreshBuffer: TimeInterval = 30
    /// Fallback lifetime when we can't parse the JWT exp claim.
    private let fallbackLifetime: TimeInterval = 8 * 60

    func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh,
           let cached = cachedToken,
           let expiry = expiresAt,
           expiry.timeIntervalSinceNow > refreshBuffer {
            return cached
        }
        return try await fetchToken()
    }

    private func fetchToken() async throws -> String {
        var request = URLRequest(url: URL(string: "https://edge.microsoft.com/translate/auth")!)
        request.timeoutInterval = 10
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MicrosoftAuthError.fetchFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw MicrosoftAuthError.fetchFailed("auth endpoint returned no token")
        }
        cachedToken = token
        expiresAt = Self.extractExpiry(from: token) ?? Date().addingTimeInterval(fallbackLifetime)
        AppLogger.log("microsoft token fetched, expiresAt=\(expiresAt?.timeIntervalSinceNow ?? -1)s")
        return token
    }

    /// Decode the base64url-encoded payload of a JWT and pull the `exp` claim.
    /// Returns nil when the input isn't a JWT, the payload isn't valid JSON,
    /// or `exp` is missing — caller falls back to a conservative lifetime.
    private static func extractExpiry(from jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let exp = json["exp"] as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }
}
