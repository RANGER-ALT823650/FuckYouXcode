import Foundation

enum OpenAIChatClientError: LocalizedError {
    case missingConfiguration
    case invalidBaseURL
    case emptyResponse
    case providerError(String)
    case requestFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "请先填写 Base URL、API Key 和模型名称。"
        case .invalidBaseURL:
            return "Base URL 无效。"
        case .emptyResponse:
            return "模型没有返回内容。"
        case .providerError(let message):
            return message
        case .requestFailed(let statusCode, let message):
            return "请求失败（\(statusCode)）：\(message)"
        }
    }
}

struct OpenAIChatClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(
        messages: [AIChatMessage],
        configuration: AIProviderConfiguration
    ) async throws -> String {
        let request = try makeRequest(
            messages: messages,
            configuration: configuration,
            stream: false
        )

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let message = Self.providerErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw OpenAIChatClientError.requestFailed(statusCode: statusCode, message: message)
        }

        if let errorMessage = Self.providerErrorMessage(from: data) {
            throw OpenAIChatClientError.providerError(errorMessage)
        }

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw OpenAIChatClientError.emptyResponse
        }
        return content
    }

    func stream(
        messages: [AIChatMessage],
        configuration: AIProviderConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        messages: messages,
                        configuration: configuration,
                        stream: true
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                    guard (200..<300).contains(statusCode) else {
                        let message = HTTPURLResponse.localizedString(forStatusCode: statusCode)
                        throw OpenAIChatClientError.requestFailed(statusCode: statusCode, message: message)
                    }

                    var didReceiveContent = false
                    for try await line in bytes.lines {
                        guard let chunk = try Self.streamContent(fromServerSentEventLine: line) else {
                            continue
                        }
                        didReceiveContent = true
                        continuation.yield(chunk)
                    }

                    if !didReceiveContent {
                        throw OpenAIChatClientError.emptyResponse
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    static func chatCompletionsURL(from baseURLString: String) throws -> URL {
        let raw = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw OpenAIChatClientError.invalidBaseURL
        }

        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard var components = URLComponents(string: candidate),
              components.scheme != nil,
              components.host != nil else {
            throw OpenAIChatClientError.invalidBaseURL
        }

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }

        if !path.hasSuffix("/chat/completions") {
            path += "/chat/completions"
        }
        components.path = path

        guard let url = components.url else {
            throw OpenAIChatClientError.invalidBaseURL
        }
        return url
    }

    static func streamContent(fromServerSentEventLine line: String) throws -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else {
            return nil
        }

        let payload = trimmed.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != "[DONE]" else {
            return nil
        }

        let data = Data(payload.utf8)
        if let errorMessage = providerErrorMessage(from: data) {
            throw OpenAIChatClientError.providerError(errorMessage)
        }

        let decoded = try JSONDecoder().decode(OpenAIChatStreamResponse.self, from: data)
        let content = decoded.choices.compactMap(\.delta.content).joined()
        return content.isEmpty ? nil : content
    }

    private func makeRequest(
        messages: [AIChatMessage],
        configuration: AIProviderConfiguration,
        stream: Bool
    ) throws -> URLRequest {
        let normalizedBaseURL = configuration.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAPIKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedBaseURL.isEmpty,
              !normalizedAPIKey.isEmpty,
              !normalizedModel.isEmpty else {
            throw OpenAIChatClientError.missingConfiguration
        }

        let url = try Self.chatCompletionsURL(from: normalizedBaseURL)
        let requestBody = OpenAIChatRequest(
            model: normalizedModel,
            messages: messages.map { OpenAIChatRequest.Message(role: $0.role.rawValue, content: $0.content) },
            stream: stream
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(normalizedAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)
        return request
    }

    private static func providerErrorMessage(from data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) else {
            return nil
        }
        return envelope.error?.message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }

    var model: String
    var messages: [Message]
    var stream: Bool
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String?
        }

        var message: Message
    }

    var choices: [Choice]
}

private struct OpenAIChatStreamResponse: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var content: String?
        }

        var delta: Delta
    }

    var choices: [Choice]
}

private struct OpenAIErrorEnvelope: Decodable {
    struct ProviderError: Decodable {
        var message: String
    }

    var error: ProviderError?
}
