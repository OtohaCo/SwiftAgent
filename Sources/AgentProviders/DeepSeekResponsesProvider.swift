import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// DeepSeek Responses API thinking-effort values.
public enum DeepSeekReasoningEffort: String, Hashable, Sendable, Codable {
    case none
    case low
    case high
    case max
}

/// A stateless DeepSeek Responses API adapter. SwiftAgent owns conversation
/// history and host tool execution; DeepSeek receives the full input each turn.
public struct DeepSeekResponsesProvider: ModelProvider, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public var descriptor: ModelProviderDescriptor {
        .init(id: "deepseek", capabilities: [.streaming, .multiTurn, .tools, .structuredOutput, .reasoning])
    }

    private let apiKey: String
    private let endpoint: URL
    private let maximumOutputTokens: Int
    private let reasoningEffort: DeepSeekReasoningEffort
    private let resolvedModelIDsByAlias: [String: String]
    private let transport: any ProviderHTTPTransport

    public var description: String { "DeepSeekResponsesProvider" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["descriptor": descriptor]) }

    public init(
        apiKey: String,
        endpoint: URL? = nil,
        maximumOutputTokens: Int = 4_096,
        reasoningEffort: DeepSeekReasoningEffort = .high,
        resolvedModelIDsByAlias: [String: String] = [:],
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
    ) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains("\r"), !apiKey.contains("\n"), maximumOutputTokens > 0,
              let endpoint = endpoint ?? URL(string: "https://api.deepseek.com/responses") else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid provider configuration.")
        }
        guard resolvedModelIDsByAlias.allSatisfy({ alias, resolved in
            !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid DeepSeek model alias configuration.")
        }
        let host = endpoint.host?.lowercased() ?? ""
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard !host.isEmpty, endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              endpoint.scheme?.lowercased() == "https" || (endpoint.scheme?.lowercased() == "http" && loopback) else {
            throw ModelProviderError(kind: .invalidRequest,
                                     message: "The provider endpoint must use HTTPS or local HTTP.")
        }
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.maximumOutputTokens = maximumOutputTokens
        self.reasoningEffort = reasoningEffort
        self.resolvedModelIDsByAlias = resolvedModelIDsByAlias
        self.transport = transport
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let body: Data
            do {
                body = try JSONEncoder().encode(DeepSeekResponsesRequestEncoder.encode(
                    request, maximumOutputTokens: maximumOutputTokens, reasoningEffort: reasoningEffort
                ))
            } catch let error as ModelProviderError {
                throw error
            } catch {
                throw ModelProviderError(kind: .invalidRequest,
                                         message: "The DeepSeek request cannot be encoded.")
            }

            var http = URLRequest(url: endpoint)
            http.httpMethod = "POST"
            http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            http.httpBody = body

            var sse = try ProviderSSEDecoder()
            let responseModelName = resolvedModelIDsByAlias[request.model.name] ?? request.model.name
            var decoder = DeepSeekResponsesStreamDecoder(
                model: request.model, responseModelName: responseModelName,
                requiresReasoningForTools: reasoningEffort != .none && !request.tools.isEmpty
            )
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
