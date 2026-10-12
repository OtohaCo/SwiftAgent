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
        var capabilities: ModelCapabilities = [.streaming, .multiTurn, .tools, .structuredOutput, .imageInput]
        if reasoningEffort != nil || reasoningSummary != nil { capabilities.insert(.reasoning) }
        return .init(id: "openai", capabilities: capabilities)
    }

    private let apiKey: String
    private let endpoint: URL
    private let maximumOutputTokens: Int
    private let reasoningEffort: OpenAIReasoningEffort?
    private let reasoningSummary: OpenAIReasoningSummary?
    private let promptCacheKey: String?
    private let promptCaching: OpenAIResponsesPromptCaching?
    private let resolvedModelIDsByAlias: [String: String]
    private let nativeContext: OpenAINativeContextConfiguration?
    private let transport: any ProviderHTTPTransport

    public var description: String { "OpenAIResponsesProvider" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["descriptor": descriptor]) }

    /// - Parameter promptCacheKey: Optional Host-configured grouping/routing value sent as
    ///   `prompt_cache_key` on every request. All sessions sharing this provider share its key.
    ///   It does not guarantee a cache hit; model and gateway semantics vary. When rebuilding
    ///   the provider, the Host supplies the key again according to its grouping strategy.
    public init(
        apiKey: String,
        endpoint: URL? = nil,
        maximumOutputTokens: Int = 4_096,
        reasoningEffort: OpenAIReasoningEffort? = nil,
        reasoningSummary: OpenAIReasoningSummary? = nil,
        promptCacheKey: String? = nil,
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
    ) throws {
        try self.init(apiKey: apiKey, endpoint: endpoint, maximumOutputTokens: maximumOutputTokens,
                      reasoningEffort: reasoningEffort, reasoningSummary: reasoningSummary,
                      promptCacheKey: promptCacheKey, resolvedModelIDsByAlias: [:], transport: transport)
    }

    public init(
        apiKey: String,
        endpoint: URL? = nil,
        maximumOutputTokens: Int = 4_096,
        reasoningEffort: OpenAIReasoningEffort? = nil,
        reasoningSummary: OpenAIReasoningSummary? = nil,
        promptCacheKey: String? = nil,
        resolvedModelIDsByAlias: [String: String],
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
    ) throws {
        try self.init(apiKey: apiKey, endpoint: endpoint, maximumOutputTokens: maximumOutputTokens,
                      reasoningEffort: reasoningEffort, reasoningSummary: reasoningSummary,
                      promptCacheKey: promptCacheKey, resolvedModelIDsByAlias: resolvedModelIDsByAlias,
                      promptCaching: nil, transport: transport)
    }

    /// Cache controls require explicit Host qualification for the endpoint and resolved model.
    /// Omit this configuration to preserve the endpoint's existing defaults.
    public init(
        apiKey: String, endpoint: URL? = nil, maximumOutputTokens: Int = 4_096,
        reasoningEffort: OpenAIReasoningEffort? = nil, reasoningSummary: OpenAIReasoningSummary? = nil,
        promptCacheKey: String? = nil, resolvedModelIDsByAlias: [String: String] = [:],
        promptCaching: OpenAIResponsesPromptCaching?,
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
    ) throws {
        try self.init(apiKey: apiKey, endpoint: endpoint, maximumOutputTokens: maximumOutputTokens,
            reasoningEffort: reasoningEffort, reasoningSummary: reasoningSummary, promptCacheKey: promptCacheKey,
            resolvedModelIDsByAlias: resolvedModelIDsByAlias, promptCaching: promptCaching, nativeContext: nil, transport: transport)
    }

    public init(apiKey: String, endpoint: URL? = nil, maximumOutputTokens: Int = 4_096,
                reasoningEffort: OpenAIReasoningEffort? = nil, reasoningSummary: OpenAIReasoningSummary? = nil,
                promptCacheKey: String? = nil, resolvedModelIDsByAlias: [String: String] = [:],
                promptCaching: OpenAIResponsesPromptCaching? = nil, nativeContext: OpenAINativeContextConfiguration?,
                transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) throws {
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
        guard OpenAIResponsesRequestEncoder.validPromptCacheKey(promptCacheKey) else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid OpenAI prompt cache key.")
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
        self.promptCacheKey = promptCacheKey
        try promptCaching?.validate(endpoint: endpoint)
        self.promptCaching = promptCaching
        self.resolvedModelIDsByAlias = resolvedModelIDsByAlias
        self.transport = transport
        if let nativeContext, nativeContext.qualification.endpoint != endpoint {
            throw ModelProviderError(kind: .unsupportedCapability, message: "Native context endpoint qualification does not match the provider.")
        }
        self.nativeContext = nativeContext
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        stream(request: request, prewarm: false)
    }

    /// A separate Host-owned invocation which prepares the cache without generation.
    /// Consume and account for these normal model events under a distinct invocation ID;
    /// do not feed the response into an Agent run or execute tools from it.
    public func prewarm(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        stream(request: request, prewarm: true)
    }

    private func stream(request: ModelRequest, prewarm: Bool) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let body: Data
            do {
                body = try NativeContextWire.checked(OpenAIResponsesRequestEncoder.encode(
                    request, maximumOutputTokens: maximumOutputTokens,
                    reasoningEffort: reasoningEffort, reasoningSummary: reasoningSummary,
                    promptCacheKey: promptCacheKey, promptCaching: promptCaching,
                    resolvedModelName: resolvedModelIDsByAlias[request.model.name] ?? request.model.name,
                    prewarm: prewarm, nativeContext: nativeContext, endpoint: endpoint
                ))
            } catch let error as ModelProviderError {
                throw error
            } catch {
                throw ModelProviderError(kind: .invalidRequest, message: "The provider request cannot be encoded.")
            }

            if nativeContext?.automatic != nil, request.nativeContextSource == nil {
                throw ModelProviderError(kind: .invalidRequest, message: "Automatic native context requires a Core-managed source snapshot.")
            }
            if let source = request.nativeContextSource, source.requestDigest != ModelImageDigest.sha256Hex(body) {
                throw ModelProviderError(kind: .invalidRequest, message: "Native request changed after its verified source snapshot.")
            }
            var http = URLRequest(url: endpoint)
            http.httpMethod = "POST"
            http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            http.httpBody = body

            var sse = try ProviderSSEDecoder()
            let responseModelName = resolvedModelIDsByAlias[request.model.name] ?? request.model.name
            var decoder = OpenAIResponsesStreamDecoder(model: request.model, responseModelName: responseModelName, nativeRequest: nativeContext?.automatic != nil ? request : nil)
            var validation = ModelEventAccumulator()
            var receivedHeader = false
            var events = transport.stream(http).makeAsyncIterator()
            while let event = try await events.next() {
                try Task.checkCancellation()
                switch event {
                case .response(let status, let headers):
                    guard !receivedHeader else { throw ProviderJSON.invalid() }
                    guard status == 200 else {
                        throw try await ProviderHTTPFailure.classify(
                            status, headers: headers, remainingBody: &events, signals: .responses
                        )
                    }
                    receivedHeader = true
                case .data(let data):
                    guard receivedHeader else { throw ProviderJSON.invalid() }
                    for frame in try sse.consume(data) {
                        for normalized in try decoder.consume(frame) {
                            do { try validation.append(normalized) } catch { throw ProviderJSON.invalid() }
                            if prewarm { try PromptCacheQualification.validatePrewarm(normalized) }
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

extension OpenAIResponsesProvider: ModelProviderRequestValidator {
    public func validate(request: ModelRequest) throws {
        _ = try OpenAIResponsesRequestEncoder.encode(
            request,
            maximumOutputTokens: maximumOutputTokens,
            reasoningEffort: reasoningEffort,
            reasoningSummary: reasoningSummary,
            promptCacheKey: promptCacheKey, promptCaching: promptCaching,
            resolvedModelName: resolvedModelIDsByAlias[request.model.name] ?? request.model.name,
            nativeContext: nativeContext, endpoint: endpoint
        )
    }
}

extension OpenAIResponsesProvider: ModelProviderNativeContextWitness {
    public var compactionModes: Set<ModelCompactionMode> { nativeContext?.qualification.modes ?? [] }
    public var automaticCompaction: ModelAutomaticCompaction? { nativeContext?.automatic }
    public func nativeContextRequestDigest(request: ModelRequest, compactionMode: ModelCompactionMode?) throws -> String {
        ModelImageDigest.sha256Hex(try nativeBody(request, mode: compactionMode))
    }
    private func nativeBody(_ request: ModelRequest, mode: ModelCompactionMode?) throws -> Data {
        if let mode {
            guard mode == .openAIStandalone, let nativeContext else { throw ModelProviderError(kind: .unsupportedCapability, message: "OpenAI standalone compact is not qualified.") }
            try nativeContext.qualification.validate(endpoint: endpoint, model: resolvedModelIDsByAlias[request.model.name] ?? request.model.name, mode: mode)
            var fields = try ProviderJSON.object(OpenAINativeContext.standalone(request, promptCacheKey: promptCacheKey))
            try promptCaching?.validate(modelName: resolvedModelIDsByAlias[request.model.name] ?? request.model.name)
            try promptCaching?.apply(to: &fields, request: request, images: true, assistantNativeItems: { content, calls in
                try OpenAIResponsesContinuation.restore(content: content, calls: calls, model: request.model)?.items
            }, nativeWindowItemCount: try request.nativeContext.map { try OpenAINativeContext.window($0, model: request.model).count } ?? 0)
            return try NativeContextWire.checked(.object(fields))
        }
        return try NativeContextWire.checked(OpenAIResponsesRequestEncoder.encode(request,
            maximumOutputTokens: maximumOutputTokens, reasoningEffort: reasoningEffort, reasoningSummary: reasoningSummary,
            promptCacheKey: promptCacheKey, promptCaching: promptCaching,
            resolvedModelName: resolvedModelIDsByAlias[request.model.name] ?? request.model.name,
            nativeContext: nativeContext, endpoint: endpoint))
    }
    public func validateCompaction(request: ModelCompactionRequest) throws { _ = try nativeBody(request.request, mode: request.mode) }
    public func compact(request: ModelCompactionRequest) -> AsyncThrowingStream<ModelCompactionEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !Task.isCancelled else { continuation.finish(throwing: CancellationError()); return }
            let worker = Task {
                do {
                    try Task.checkCancellation()
                    guard request.request.nativeContextSource != nil else { throw ModelProviderError(kind: .invalidRequest, message: "Native compact requires a Core-managed source snapshot.") }
                    let body = try nativeBody(request.request, mode: request.mode)
                    if let source = request.request.nativeContextSource, source.requestDigest != ModelImageDigest.sha256Hex(body) { throw ProviderJSON.invalid() }
                    var http = URLRequest(url: endpoint.appendingPathComponent("compact"))
                    http.httpMethod = "POST"; http.httpBody = body
                    http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    http.setValue("application/json", forHTTPHeaderField: "Accept")
                    var receivedHeader = false, data = Data()
                    try Task.checkCancellation()
                    var events = transport.stream(http).makeAsyncIterator()
                    while let event = try await events.next() {
                        try Task.checkCancellation()
                        switch event {
                        case .response(let status, let headers):
                            guard !receivedHeader else { throw ProviderJSON.invalid() }
                            guard status == 200 else { throw try await ProviderHTTPFailure.classify(status, headers: headers, remainingBody: &events, signals: .responses) }
                            receivedHeader = true
                        case .data(let chunk):
                            guard receivedHeader, chunk.count <= 32_000_000 - data.count else { throw ProviderJSON.invalid() }
                            data.append(chunk)
                        }
                    }
                    try Task.checkCancellation()
                    guard receivedHeader, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { throw ProviderJSON.invalid() }
                    let response = try OpenAINativeContext.response(.object(try ProviderJSON.decode(text)), request: request)
                    continuation.yield(.usage(response.usage)); continuation.yield(.completed(response)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}
