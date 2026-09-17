import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AnthropicThinking: Equatable, Sendable {
    case disabled
    case adaptive
    case enabled(budgetTokens: Int)
}

public struct AnthropicProvider: ModelProvider, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var descriptor: ModelProviderDescriptor {
        var capabilities: ModelCapabilities = [.streaming, .multiTurn, .tools, .structuredOutput]
        if thinking != .disabled { capabilities.insert(.reasoning) }
        return .init(id: "anthropic", capabilities: capabilities)
    }
    private let apiKey: String
    private let endpoint: URL
    private let maximumOutputTokens: Int
    private let thinking: AnthropicThinking
    private let transport: any ProviderHTTPTransport
    public var description: String { "AnthropicProvider" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["descriptor": descriptor]) }

    public init(apiKey: String, endpoint: URL? = nil, maximumOutputTokens: Int = 4_096,
                thinking: AnthropicThinking = .disabled,
                transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains("\r"), !apiKey.contains("\n"), maximumOutputTokens > 0,
              let endpoint = endpoint ?? URL(string: "https://api.anthropic.com/v1/messages") else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid provider configuration.")
        }
        let host = endpoint.host?.lowercased() ?? ""
        if case .enabled(let budget) = thinking, budget < 1_024 || budget >= maximumOutputTokens {
            throw ModelProviderError(kind: .invalidRequest, message: "The thinking budget must be at least 1024 and below the output limit.")
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard !host.isEmpty, endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              endpoint.scheme?.lowercased() == "https" || (endpoint.scheme?.lowercased() == "http" && loopback) else {
            throw ModelProviderError(kind: .invalidRequest, message: "The provider endpoint must use HTTPS or local HTTP.")
        }
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.maximumOutputTokens = maximumOutputTokens
        self.thinking = thinking
        self.transport = transport
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let body: Data
            do {
                body = try JSONEncoder().encode(AnthropicRequestEncoder.encode(request, maximumOutputTokens: maximumOutputTokens, thinking: thinking))
            } catch let error as ModelProviderError { throw error }
            catch { throw ModelProviderError(kind: .invalidRequest, message: "The provider request cannot be encoded.") }
            var http = URLRequest(url: endpoint)
            http.httpMethod = "POST"
            http.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            http.httpBody = body
            var sse = try ProviderSSEDecoder()
            var decoder = AnthropicStreamDecoder(model: request.model)
            var validation = ModelEventAccumulator()
            var receivedHeader = false
            for try await event in transport.stream(http) {
                try Task.checkCancellation()
                switch event {
                case .response(let status, let headers):
                    guard !receivedHeader else { throw ProviderJSON.invalid() }
                    guard status == 200 else { throw ProviderHTTPFailure.classify(status, headers: headers) }
                    receivedHeader = true
                case .data(let data):
                    guard receivedHeader else { throw ProviderJSON.invalid() }
                    for frame in try sse.consume(data) {
                        for normalized in try decoder.consume(frame) {
                            do { try validation.append(normalized) } catch { throw ProviderJSON.invalid() }
                            try emit(normalized)
                        }
                    }
                }
            }
            try Task.checkCancellation()
            try sse.finish()
            try decoder.finish()
            do { _ = try validation.finish() } catch { throw ProviderJSON.invalid() }
        }
    }
}
