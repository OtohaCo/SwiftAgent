import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Responses API reasoning-effort wire value.
public struct OpenAIReasoningEffort: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let disabled = Self(rawValue: "none")
    public static let minimal = Self(rawValue: "minimal")
    public static let low = Self(rawValue: "low")
    public static let medium = Self(rawValue: "medium")
    public static let high = Self(rawValue: "high")
    public static let xhigh = Self(rawValue: "xhigh")
    public static let max = Self(rawValue: "max")

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A Responses API reasoning-summary wire value.
public struct OpenAIReasoningSummary: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let auto = Self(rawValue: "auto")
    public static let concise = Self(rawValue: "concise")
    public static let detailed = Self(rawValue: "detailed")

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An OpenAI Responses API adapter. SwiftAgent remains the canonical owner of
/// conversation state and host tool execution.
public struct OpenAIResponsesProvider: ModelProvider, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var descriptor: ModelProviderDescriptor {
        var capabilities: ModelCapabilities = [.streaming, .multiTurn, .tools, .structuredOutput]
        if reasoningEffort != nil || reasoningSummary != nil { capabilities.insert(.reasoning) }
        return .init(id: "openai", capabilities: capabilities)
    }

    private let apiKey: String
    private let endpoint: URL
    private let maximumOutputTokens: Int
    private let reasoningEffort: OpenAIReasoningEffort?
    private let reasoningSummary: OpenAIReasoningSummary?
    private let resolvedModelIDsByAlias: [String: String]
    private let transport: any ProviderHTTPTransport

    public var description: String { "OpenAIResponsesProvider" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["descriptor": descriptor]) }

    public init(
        apiKey: String,
        endpoint: URL? = nil,
        maximumOutputTokens: Int = 4_096,
        reasoningEffort: OpenAIReasoningEffort? = nil,
        reasoningSummary: OpenAIReasoningSummary? = nil,
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
    ) throws {
        try self.init(apiKey: apiKey, endpoint: endpoint, maximumOutputTokens: maximumOutputTokens,
                      reasoningEffort: reasoningEffort, reasoningSummary: reasoningSummary,
                      resolvedModelIDsByAlias: [:], transport: transport)
    }

    public init(
        apiKey: String,
        endpoint: URL? = nil,
        maximumOutputTokens: Int = 4_096,
        reasoningEffort: OpenAIReasoningEffort? = nil,
        reasoningSummary: OpenAIReasoningSummary? = nil,
        resolvedModelIDsByAlias: [String: String],
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
    ) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains("\r"), !apiKey.contains("\n"), maximumOutputTokens > 0,
              let endpoint = endpoint ?? URL(string: "https://api.openai.com/v1/responses") else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid provider configuration.")
        }
        guard reasoningEffort.map({ $0.rawValue == $0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            && !$0.rawValue.isEmpty }) ?? true,
              reasoningSummary.map({ $0.rawValue == $0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            && !$0.rawValue.isEmpty }) ?? true else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid OpenAI reasoning configuration.")
        }
        guard resolvedModelIDsByAlias.allSatisfy({ alias, resolved in
            !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid OpenAI model alias configuration.")
        }
        let host = endpoint.host?.lowercased() ?? ""
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard !host.isEmpty, endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              endpoint.scheme?.lowercased() == "https" || (endpoint.scheme?.lowercased() == "http" && loopback) else {
            throw ModelProviderError(kind: .invalidRequest, message: "The provider endpoint must use HTTPS or local HTTP.")
        }
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.maximumOutputTokens = maximumOutputTokens
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.resolvedModelIDsByAlias = resolvedModelIDsByAlias
        self.transport = transport
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let body: Data
            do {
                body = try JSONEncoder().encode(OpenAIResponsesRequestEncoder.encode(
                    request, maximumOutputTokens: maximumOutputTokens,
                    reasoningEffort: reasoningEffort, reasoningSummary: reasoningSummary
                ))
            } catch let error as ModelProviderError {
                throw error
            } catch {
                throw ModelProviderError(kind: .invalidRequest, message: "The provider request cannot be encoded.")
            }

            var http = URLRequest(url: endpoint)
            http.httpMethod = "POST"
            http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            http.httpBody = body

            var sse = try ProviderSSEDecoder()
            let responseModelName = resolvedModelIDsByAlias[request.model.name] ?? request.model.name
            var decoder = OpenAIResponsesStreamDecoder(model: request.model, responseModelName: responseModelName)
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
