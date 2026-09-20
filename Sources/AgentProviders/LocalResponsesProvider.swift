import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Authentication for a local or self-hosted Responses endpoint.
public struct LocalResponsesAuthentication: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    fileprivate enum Storage: Sendable {
        case none
        case bearer(String)
    }

    fileprivate let storage: Storage

    public static let none = Self(storage: .none)

    public static func bearer(_ token: String) -> Self {
        Self(storage: .bearer(token))
    }

    public var description: String {
        switch storage {
        case .none: "none"
        case .bearer: "bearer"
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["kind": description]) }
}

/// A stateless adapter for local or self-hosted OpenAI-compatible Responses
/// endpoints. Canonical SwiftAgent history is replayed on every model turn.
public struct LocalResponsesProvider: ModelProvider, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public struct Configuration: Sendable {
        public let baseURL: URL
        public let model: String
        public let authentication: LocalResponsesAuthentication
        public let maximumOutputTokens: Int
        public let capabilities: ModelCapabilities

        public init(
            baseURL: URL,
            model: String,
            authentication: LocalResponsesAuthentication = .none,
            maximumOutputTokens: Int = 4_096,
            capabilities: ModelCapabilities = []
        ) {
            self.baseURL = baseURL
            self.model = model
            self.authentication = authentication
            self.maximumOutputTokens = maximumOutputTokens
            self.capabilities = capabilities
        }
    }

    public let model: ModelID
    public let descriptor: ModelProviderDescriptor

    private let endpoint: URL
    private let authentication: LocalResponsesAuthentication
    private let maximumOutputTokens: Int
    private let transport: any ProviderHTTPTransport

    public var description: String { "LocalResponsesProvider" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["descriptor": descriptor, "model": model])
    }

    public init(
        configuration: Configuration,
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
    ) throws {
        let modelName = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty,
              modelName == configuration.model,
              configuration.maximumOutputTokens > 0 else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid local Responses configuration.")
        }
        switch configuration.authentication.storage {
        case .none:
            break
        case .bearer(let token):
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !token.contains("\r"), !token.contains("\n") else {
                throw ModelProviderError(kind: .invalidRequest, message: "Invalid local Responses authentication.")
            }
        }
        let endpoint = try Self.responsesEndpoint(from: configuration.baseURL)
        if case .bearer = configuration.authentication.storage,
           endpoint.scheme?.lowercased() != "https",
           !Self.isLoopback(endpoint.host) {
            throw ModelProviderError(
                kind: .invalidRequest,
                message: "Bearer authentication requires HTTPS or a loopback endpoint."
            )
        }
        self.endpoint = endpoint
        authentication = configuration.authentication
        maximumOutputTokens = configuration.maximumOutputTokens
        model = .init(provider: "local-responses", name: modelName)
        descriptor = .init(
            id: "local-responses",
            capabilities: configuration.capabilities.union([.streaming, .multiTurn])
        )
        self.transport = transport
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            guard request.model == model else {
                throw ModelProviderError(
                    kind: .invalidRequest,
                    message: "The local Responses request model does not match the configured model."
                )
            }
            if !request.tools.isEmpty, !descriptor.capabilities.contains(.tools) {
                throw ModelProviderError(
                    kind: .unsupportedCapability,
                    message: "The configured local model has not declared tool support."
                )
            }
            if request.structuredOutput != nil, !descriptor.capabilities.contains(.structuredOutput) {
                throw ModelProviderError(
                    kind: .unsupportedCapability,
                    message: "The configured local model has not declared structured-output support."
                )
            }

            let body: Data
            do {
                body = try JSONEncoder().encode(LocalResponsesRequestEncoder.encode(
                    request,
                    maximumOutputTokens: maximumOutputTokens
                ))
            } catch let error as ModelProviderError {
                throw error
            } catch {
                throw ModelProviderError(
                    kind: .invalidRequest,
                    message: "The local Responses request cannot be encoded."
                )
            }

            var http = URLRequest(url: endpoint)
            http.httpMethod = "POST"
            switch authentication.storage {
            case .none:
                break
            case .bearer(let token):
                http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            http.httpBody = body

            var sse = try ProviderSSEDecoder()
            var decoder = ResponsesStreamDecoder(
                model: request.model,
                providerLabel: "Local Responses",
                continuationPolicy: .none
            )
            var validation = ModelEventAccumulator()
            var receivedHeader = false
            for try await event in transport.stream(http) {
                try Task.checkCancellation()
                switch event {
                case .response(let status, let headers):
                    guard !receivedHeader else { throw ProviderJSON.invalid() }
                    guard status == 200 else {
                        throw ProviderHTTPFailure.classify(status, headers: headers)
                    }
                    receivedHeader = true
                case .data(let data):
                    guard receivedHeader else { throw ProviderJSON.invalid() }
                    for frame in try sse.consume(data) {
                        for normalized in try decoder.consume(frame) {
                            do { try validation.append(normalized) }
                            catch { throw ProviderJSON.invalid() }
                            try emit(normalized)
                        }
                    }
                }
            }
            try Task.checkCancellation()
            try sse.finish()
            try decoder.finish()
            do { _ = try validation.finish() }
            catch { throw ProviderJSON.invalid() }
        }
    }

    private static func responsesEndpoint(from baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.query == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid local Responses base URL.")
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "/responses" : "/\(path)/responses"
        guard let endpoint = components.url else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid local Responses base URL.")
        }
        return endpoint
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

enum LocalResponsesRequestEncoder {
    static func encode(_ request: ModelRequest, maximumOutputTokens: Int) throws -> JSONValue {
        guard request.model.provider == "local-responses",
              !request.model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid local Responses model identifier.")
        }
        var body: [String: JSONValue] = [
            "model": .string(request.model.name),
            "input": .array(try ResponsesCanonicalRequestEncoder.encodeMessages(request.messages)),
            "stream": .bool(true),
            "max_output_tokens": .number(Decimal(maximumOutputTokens)),
        ]
        if let tools = ResponsesCanonicalRequestEncoder.encodeTools(request.tools) {
            body["tools"] = tools
        }
        if let structured = ResponsesCanonicalRequestEncoder.encodeStructuredOutput(request.structuredOutput) {
            body["text"] = structured
        }
        return .object(body)
    }
}
