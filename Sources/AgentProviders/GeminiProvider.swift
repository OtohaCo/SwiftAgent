import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native generateContent dialect; not Interactions, Vertex, Live API or an Anthropic shim.
/// Received signed parts are replayed exactly. No live model/account qualification is implied.
public struct GeminiProvider: ModelProvider, ModelProviderRequestValidator, ModelProviderRunDrain,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    private let credentials: GeminiCredentials
    private let transport: any ProviderHTTPTransport
    private let configuration: GeminiConfiguration
    private let drain = ProviderRunDrain()
    public var descriptor: ModelProviderDescriptor { .init(id: "gemini", capabilities: [.streaming, .multiTurn, .tools, .structuredOutput, .reasoning, .imageInput, .fileInput]) }
    public var description: String { "GeminiProvider" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["descriptor": descriptor]) }
    public init(credentials: GeminiCredentials, baseURL: URL = Self.defaultBaseURL,
                streaming: Bool = true, thinking: GeminiThinkingConfiguration? = nil,
                preservedThinking: GeminiPreservedThinkingProfile = .preserve,
                maximumOutputTokens: Int? = nil, maximumRequestBytes: Int = 100_000_000,
                maximumResponseBytes: Int = 16_000_000, authorizationScopeID: String = "default",
                promptCaching: GeminiPromptCaching = .implicit,
                transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) throws {
        self.credentials = credentials; self.transport = transport
        configuration = try .init(baseURL: baseURL, streaming: streaming, thinking: thinking, profile: preservedThinking,
            maximumOutputTokens: maximumOutputTokens, maximumRequestBytes: maximumRequestBytes,
            maximumResponseBytes: maximumResponseBytes, authorizationScopeID: authorizationScopeID, caching: promptCaching)
    }
    public func validate(request: ModelRequest) throws { _ = try GeminiRequestEncoder.encode(request, configuration: configuration) }
    public func waitForRunToDrain(sessionID: UUID, runID: UUID) async { await drain.wait(sessionID: sessionID, runID: runID) }
    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !Task.isCancelled else { continuation.finish(throwing: CancellationError()); return }
            let key = drain.begin(request)
            let producer = Task {
                defer { drain.end(key) }
                do {
                    try await produce(request) { event in
                        try Task.checkCancellation()
                        if case .terminated = continuation.yield(event) { throw CancellationError() }
                    }
                    try Task.checkCancellation(); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }
    private func produce(_ request: ModelRequest, emit: ModelEventStream.Emit) async throws {
        try Task.checkCancellation()
        let body = try GeminiRequestEncoder.encode(request, configuration: configuration)
        var http = URLRequest(url: try configuration.endpoint(model: request.model)); http.httpMethod = "POST"; http.httpBody = body
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue(configuration.streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        try await credentials.authorize(&http)
        if case .explicit(let binding) = configuration.caching { guard Date() < binding.expiresAt else { throw GeminiBoundary.unsupported() } }
        try Task.checkCancellation()
        var header = false, receivedBytes = 0, json = Data()
        var sse = try ProviderSSEDecoder(), decoder = GeminiResponseDecoder(request: request, configuration: configuration)
        var iterator = transport.stream(http).makeAsyncIterator()
        while let event = try await iterator.next() {
            try Task.checkCancellation()
            switch event {
            case .response(let status, let headers):
                guard !header else { throw ProviderJSON.invalid() }; header = true
                guard status == 200 else { throw ProviderHTTPFailure.classify(status, headers: headers) }
            case .data(let data):
                guard header, data.count <= configuration.maximumResponseBytes - receivedBytes else { throw ProviderJSON.invalid() }
                receivedBytes += data.count
                if configuration.streaming {
                    for frame in try sse.consume(data) {
                        guard frame.name == nil || frame.name == "message" else { throw ProviderJSON.invalid() }
                        try decoder.consume(ProviderJSON.decode(frame.data))
                    }
                } else { json.append(data) }
            }
        }
        try Task.checkCancellation()
        guard header else { throw ProviderJSON.invalid() }
        if configuration.streaming { try sse.finish() }
        else {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: json) else { throw ProviderJSON.invalid() }
            try decoder.consume(ProviderJSON.object(value))
        }
        var validation = ModelEventAccumulator()
        for event in try decoder.finish() { try validation.append(event); try emit(event) }
        _ = try validation.finish()
    }
}
