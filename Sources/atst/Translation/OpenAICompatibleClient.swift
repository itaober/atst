import Foundation

struct OpenAICompatibleClient {
    var configuration: AppConfiguration

    /// Fire a cheap HEAD against the chat endpoint so URLSession opens a
    /// TCP + TLS connection and keeps it warm. The first real translation
    /// after this then skips ~200–400ms of handshake, which is the chunk of
    /// TTFB we can actually shave off the client side.
    /// Safe to call repeatedly — URLSession will dedupe pooled connections.
    static func prewarm(configuration: AppConfiguration) {
        guard let url = configuration.chatCompletionsURL else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.log("connection prewarmed host=\(url.host ?? "?") status=\(status)")
        }.resume()
    }

    func stream(
        model: String,
        messages: [ChatMessage],
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let request = try makeRequest(model: model, messages: messages, stream: true)
        let isVisionRequest = messages.contains { message in
            if case .parts(let parts) = message.content {
                return parts.contains { if case .imageURL = $0 { return true } else { return false } }
            }
            return false
        }

        let requestStart = Date()
        var ttfbLogged = false

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError.aiRequestFailed("AI 服务返回了无法识别的响应。")
            }
            let connectMs = Int(Date().timeIntervalSince(requestStart) * 1000)
            AppLogger.log("openai stream open model=\(model) status=\(httpResponse.statusCode) connectMs=\(connectMs)")

            var fullText = ""
            var errorBody = ""

            for try await line in bytes.lines {
                if !ttfbLogged {
                    let ttfb = Int(Date().timeIntervalSince(requestStart) * 1000)
                    AppLogger.log("openai stream ttfb model=\(model) ttfbMs=\(ttfb)")
                    ttfbLogged = true
                }
                if !(200..<300).contains(httpResponse.statusCode) {
                    errorBody += line
                    continue
                }

                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedLine.hasPrefix("data:") else {
                    continue
                }

                let payload = trimmedLine.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                if payload == "[DONE]" {
                    break
                }

                guard let data = payload.data(using: .utf8) else {
                    continue
                }

                if let chunk = try? JSONDecoder().decode(ChatCompletionStreamChunk.self, from: data),
                   let delta = chunk.choices.first?.delta.content,
                   !delta.isEmpty {
                    fullText += delta
                    await MainActor.run {
                        onDelta(delta)
                    }
                }
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let detail = errorBody.isEmpty ? "HTTP \(httpResponse.statusCode)" : errorBody
                AppLogger.log("OpenAI stream non-2xx status=\(httpResponse.statusCode) model=\(model) vision=\(isVisionRequest) body=\(detail.prefix(400))")
                if isVisionRequest {
                    throw AppError.aiRequestFailed("HTTP \(httpResponse.statusCode)：\(detail.prefix(200))。该模型可能不支持图像输入，请在设置里换一个 vision 模型。")
                }
                throw AppError.aiRequestFailed(detail)
            }

            let totalMs = Int(Date().timeIntervalSince(requestStart) * 1000)
            let outputChars = fullText.count
            let tokensPerSec = outputChars > 0 && totalMs > 0
                ? Double(outputChars) / (Double(totalMs) / 1000.0)
                : 0
            AppLogger.log(String(format: "openai stream done model=%@ totalMs=%d outputChars=%d charsPerSec=%.1f",
                                  model, totalMs, outputChars, tokensPerSec))

            let result = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else {
                AppLogger.log("OpenAI stream empty result model=\(model) vision=\(isVisionRequest)")
                if isVisionRequest {
                    throw AppError.visionModelLikelyUnsupported(model)
                }
                throw AppError.emptyTranslation
            }
            return result
        } catch let error as AppError {
            throw error
        } catch let error as URLError {
            throw AppError.aiUnavailable(error.localizedDescription)
        } catch {
            throw AppError.aiRequestFailed(error.localizedDescription)
        }
    }

    private func makeRequest(model: String, messages: [ChatMessage], stream: Bool) throws -> URLRequest {
        guard let url = configuration.chatCompletionsURL else {
            throw AppError.invalidAIBaseURL(configuration.baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: model,
                messages: messages,
                temperature: 0.2,
                stream: stream
            )
        )

        return request
    }

    private func decodeErrorMessage(from data: Data) -> String? {
        if let response = try? JSONDecoder().decode(ChatErrorResponse.self, from: data) {
            return response.error.message
        }
        return String(data: data, encoding: .utf8)
    }
}

struct ChatMessage: Encodable {
    var role: String
    var content: ChatContent

    static func text(role: String, content: String) -> ChatMessage {
        ChatMessage(role: role, content: .text(content))
    }

    static func parts(role: String, parts: [ChatContentPart]) -> ChatMessage {
        ChatMessage(role: role, content: .parts(parts))
    }
}

enum ChatContent: Encodable {
    case text(String)
    case parts([ChatContentPart])

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            var container = encoder.singleValueContainer()
            try container.encode(text)
        case .parts(let parts):
            var container = encoder.singleValueContainer()
            try container.encode(parts)
        }
    }
}

enum ChatContentPart: Encodable {
    case text(String)
    case imageURL(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURLContent(url: url), forKey: .imageURL)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

private struct ImageURLContent: Encodable {
    var url: String
}

private struct ChatCompletionRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
    var temperature: Double
    var stream: Bool
}

private struct ChatCompletionStreamChunk: Decodable {
    var choices: [ChatStreamChoice]
}

private struct ChatStreamChoice: Decodable {
    var delta: ChatStreamDelta
}

private struct ChatStreamDelta: Decodable {
    var content: String?
}

private struct ChatErrorResponse: Decodable {
    var error: ChatError
}

private struct ChatError: Decodable {
    var message: String
}
