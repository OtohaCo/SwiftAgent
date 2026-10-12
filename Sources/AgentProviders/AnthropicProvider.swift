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

/// Anthropic output-config effort wire value. Static values are conveniences,
/// not a closed list of values supported by every model deployment.
public struct AnthropicEffort: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let low = Self(rawValue: "low")
    public static let medium = Self(rawValue: "medium")
    public static let high = Self(rawValue: "high")

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AnthropicProvider: ModelProvider, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var descriptor: ModelProviderDescriptor {
        var capabilities: ModelCapabilities = [.streaming, .multiTurn, .tools, .structuredOutput, .imageInput]
        if thinking != .disabled || effort != nil { capabilities.insert(.reasoning) }
        return .init(id: "anthropic", capabilities: capabilities)
    }
    private let apiKey: String
    private let endpoint: URL
    private let maximumOutputTokens: Int
    private let thinking: AnthropicThinking
    private let effort: AnthropicEffort?
    let nativeContext: AnthropicNativeContextConfiguration?
    private let promptCaching: AnthropicPromptCaching?
    private let resolvedModelIDsByAlias: [String: String]
    private let transport: any ProviderHTTPTransport
    public var description: String { "AnthropicProvider" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["descriptor": descriptor]) }

    public init(apiKey: String, endpoint: URL? = nil, maximumOutputTokens: Int = 4_096,
                thinking: AnthropicThinking = .disabled,
                transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) throws {
        try self.init(
            apiKey: apiKey,
            endpoint: endpoint,
            maximumOutputTokens: maximumOutputTokens,
            thinking: thinking,
            effort: nil,
            resolvedModelIDsByAlias: [:],
            transport: transport
        )
    }

    public init(apiKey: String, endpoint: URL? = nil, maximumOutputTokens: Int = 4_096,
                thinking: AnthropicThinking = .disabled,
                effort: AnthropicEffort?,
                transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) throws {
        try self.init(
            apiKey: apiKey,
            endpoint: endpoint,
            maximumOutputTokens: maximumOutputTokens,
            thinking: thinking,
            effort: effort,
            resolvedModelIDsByAlias: [:],
            transport: transport
        )
    }

    public init(apiKey: String, endpoint: URL? = nil, maximumOutputTokens: Int = 4_096,
                thinking: AnthropicThinking = .disabled,
                effort: AnthropicEffort?,
                resolvedModelIDsByAlias: [String: String],
                transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) throws {
        try self.init(apiKey: apiKey, endpoint: endpoint, maximumOutputTokens: maximumOutputTokens,
                      thinking: thinking, effort: effort, resolvedModelIDsByAlias: resolvedModelIDsByAlias,
                      promptCaching: nil, transport: transport)
    }

    /// Optional cache strategy qualified by the Host for this endpoint and resolved model.
    /// The strategy is provider-wide and must be supplied again when rebuilding it.
    public init(apiKey: String, endpoint: URL? = nil, maximumOutputTokens: Int = 4_096,
                thinking: AnthropicThinking = .disabled, effort: AnthropicEffort? = nil,
                resolvedModelIDsByAlias: [String: String] = [:],
                promptCaching: AnthropicPromptCaching?,
                transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) throws {
        try self.init(apiKey: apiKey, endpoint: endpoint, maximumOutputTokens: maximumOutputTokens,
            thinking: thinking, effort: effort, resolvedModelIDsByAlias: resolvedModelIDsByAlias,
            promptCaching: promptCaching, nativeContext: nil, transport: transport)
    }

    public init(apiKey: String, endpoint: URL? = nil, maximumOutputTokens: Int = 4_096,
                thinking: AnthropicThinking = .disabled, effort: AnthropicEffort? = nil,
                resolvedModelIDsByAlias: [String: String] = [:], promptCaching: AnthropicPromptCaching? = nil,
                nativeContext: AnthropicNativeContextConfiguration?,
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
        guard effort.map({ value in
            value.rawValue == value.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                && !value.rawValue.isEmpty
        }) ?? true else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid Anthropic effort configuration.")
        }
        guard resolvedModelIDsByAlias.allSatisfy({ alias, resolved in
            !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid Anthropic model alias configuration.")
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
        self.effort = effort
        try promptCaching?.validate(endpoint: endpoint)
        guard nativeContext == nil || nativeContext?.qualification.endpoint == endpoint else {
            throw ModelProviderError(kind: .unsupportedCapability, message: "Native qualification does not match the endpoint.")
        }
        self.nativeContext = nativeContext
        self.promptCaching = promptCaching
        self.resolvedModelIDsByAlias = resolvedModelIDsByAlias
        self.transport = transport
    }

    public init(apiKey: String, endpoint: URL? = nil, maximumOutputTokens: Int = 4_096,
                thinking: AnthropicThinking = .disabled,
                resolvedModelIDsByAlias: [String: String],
                transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) throws {
        try self.init(
            apiKey: apiKey,
            endpoint: endpoint,
            maximumOutputTokens: maximumOutputTokens,
            thinking: thinking,
            effort: nil,
            resolvedModelIDsByAlias: resolvedModelIDsByAlias,
            transport: transport
        )
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        stream(request: request, compactionMode: nil)
    }

    private func stream(request: ModelRequest, compactionMode: ModelCompactionMode?) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let (body, encoded, sources) = try encodedRequest(request, compactionMode: compactionMode)
            if compactionMode != nil || nativeContext?.automatic != nil || request.nativeContext != nil {
                guard let source = request.nativeContextSource, request.invocationID != nil,
                      source.requestDigest == ModelImageDigest.sha256Hex(body) else {
                    throw ModelProviderError(kind: .invalidRequest, message: "Native context requires an unchanged Core-managed source snapshot.")
                }
            }
            if let source = request.nativeContextSource, source.requestDigest != ModelImageDigest.sha256Hex(body) {
                throw ModelProviderError(kind: .invalidRequest, message: "Native source does not match the final encoded body.")
            }
            var http = URLRequest(url: endpoint)
            http.httpMethod = "POST"
            http.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            http.httpBody = body
            let betas = AnthropicNativeContext.betas(request: request, mode: compactionMode, configuration: nativeContext)
            if !betas.isEmpty { http.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
            var sse = try ProviderSSEDecoder()
            let responseModelName = resolvedModelIDsByAlias[request.model.name] ?? request.model.name
            let fields = try ProviderJSON.object(encoded)
            guard case .array(let messages) = fields["messages"] else { throw ProviderJSON.invalid() }
            var decoder = AnthropicStreamDecoder(model: request.model, responseModelName: responseModelName,
                requestPrefix: AnthropicContinuation.prefix(system: fields["system"], tools: fields["tools"], messages: messages),
                nativeRequest: compactionMode != nil || nativeContext?.automatic != nil ? request : nil,
                compactionMode: compactionMode ?? nativeContext?.automatic?.mode, inputSources: sources,
                nativeIterationUsage: request.nativeContext != nil)
            var validation = ModelEventAccumulator()
            var receivedHeader = false
            try Task.checkCancellation()
            var events = transport.stream(http).makeAsyncIterator()
            while let event = try await events.next() {
                try Task.checkCancellation()
                switch event {
                case .response(let status, let headers):
                    guard !receivedHeader else { throw ProviderJSON.invalid() }
                    guard status == 200 else {
                        throw try await ProviderHTTPFailure.classify(
                            status, headers: headers, remainingBody: &events, signals: .anthropic
                        )
                    }
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

extension AnthropicProvider: ModelProviderRequestValidator {
    public func validate(request: ModelRequest) throws {
        _ = try encodedRequest(request)
    }

    /// The checked bytes are the same bytes assigned to the actual HTTP body.
    private func encodedRequest(_ request: ModelRequest, compactionMode: ModelCompactionMode? = nil) throws -> (Data, JSONValue, [String: ModelInputSourceIdentity]) {
        do {
            let ordinary = try AnthropicRequestEncoder.encodeWithMapping(request,
                maximumOutputTokens: maximumOutputTokens, thinking: thinking, effort: effort,
                promptCaching: promptCaching,
                resolvedModelName: resolvedModelIDsByAlias[request.model.name] ?? request.model.name, nativeContext: nativeContext)
            let encoded = try AnthropicNativeContext.configure(ordinary.body, request: request, mode: compactionMode,
                configuration: nativeContext, endpoint: endpoint, resolvedModelName: resolvedModelIDsByAlias[request.model.name] ?? request.model.name, thinking: thinking)
            let body = try ProviderJSON.encode(encoded)
            // The official limit is 32 MB. Use decimal MB conservatively, not 32 MiB.
            guard body.count <= 32_000_000 else {
                throw ModelProviderError(kind: .invalidRequest,
                    message: "Anthropic encoded request body is \(body.count) bytes; the local limit is 32000000 bytes (32 MB), including base64 images and all JSON fields.")
            }
            return (body, encoded, ordinary.sources)
        } catch let error as ModelProviderError { throw error }
        catch { throw ModelProviderError(kind: .invalidRequest, message: "The provider request cannot be encoded.") }
    }
}

extension AnthropicProvider: ModelProviderNativeContextWitness {
    public var compactionModes: Set<ModelCompactionMode> { nativeContext?.qualification.modes ?? [] }
    public var automaticCompaction: ModelAutomaticCompaction? { nativeContext?.automatic }
    public func nativeContextRequestDigest(request: ModelRequest, compactionMode: ModelCompactionMode?) throws -> String {
        ModelImageDigest.sha256Hex(try encodedRequest(request, compactionMode: compactionMode).0)
    }
    public func validateCompaction(request: ModelCompactionRequest) throws {
        _ = try encodedRequest(request.request, compactionMode: request.mode)
    }
    private static func nativeStopReason(_ reason: StopReason) -> String {
        switch reason {
        case .endTurn: "end_turn"
        case .toolCalls: "tool_use"
        case .maxOutputTokens: "max_tokens"
        case .stopSequence: "stop_sequence"
        case .refusal: "refusal"
        case .cancelled: "cancelled"
        case .unknown(let value): value
        }
    }

    public func compact(request: ModelCompactionRequest) -> AsyncThrowingStream<ModelCompactionEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !Task.isCancelled else { continuation.finish(throwing: CancellationError()); return }
            let worker = Task {
                do {
                    try Task.checkCancellation()
                    for try await event in stream(request: request.request, compactionMode: request.mode) {
                        try Task.checkCancellation()
                        switch event {
                        case .usage(let usage): continuation.yield(.usage(usage))
                        case .inputTransformations(let values): continuation.yield(.inputTransformations(values))
                        case .compactionProgress(let progress): continuation.yield(.progress(progress))
                        case .responseCompleted(let response):
                            guard response.toolCalls.isEmpty, response.content.allSatisfy({
                                if case .providerContinuation = $0 { true } else { false }
                            }) else { throw ProviderJSON.invalid() }
                            let state = response.content.compactMap { if case .providerContinuation(let state) = $0 { state } else { nil } }.first
                            guard state == nil || response.classification == .maintenance else { throw ProviderJSON.invalid() }
                            continuation.yield(.completed(.init(info: response.info, continuation: state, usage: response.usage, nativeStopReason: Self.nativeStopReason(response.stopReason), inputTransformations: response.inputTransformations)))
                        default: break
                        }
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}
