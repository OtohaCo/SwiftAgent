import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Explicit OAuth ChatGPT-plan route. Host owns sign-in, granted-scope checks and token refresh.
/// Supports the documented stateless text/image/function-tool path; no native compaction,
/// encrypted reasoning replay, hosted tools, automatic refresh or billing fallback.
/// The server controls output limits: this route does not accept max_output_tokens.
public struct OpenAIChatGPTPlanProvider: ModelProvider, ModelProviderRequestValidator, ModelProviderRunDrain,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let credentials: OpenAIChatGPTPlanCredentials
    private let transport: any ProviderHTTPTransport
    private let drain = ChatGPTPlanRunDrain()
    public var descriptor: ModelProviderDescriptor {
        .init(id: "openai", capabilities: [.streaming, .multiTurn, .tools, .structuredOutput, .imageInput])
    }
    public var description: String { "OpenAIChatGPTPlanProvider" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["descriptor": descriptor]) }

    public init(credentials: OpenAIChatGPTPlanCredentials,
                transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) {
        self.credentials = credentials; self.transport = transport
    }

    public func validate(request: ModelRequest) throws { _ = try ChatGPTPlanRequestEncoder.encode(request) }

    /// Physical drain includes the Host's pending access-token callback. It must
    /// cooperate with cancellation or eventually return; SDK cannot force its completion.
    public func waitForRunToDrain(sessionID: UUID, runID: UUID) async {
        await drain.wait(sessionID: sessionID, runID: runID)
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !Task.isCancelled else { continuation.finish(throwing: CancellationError()); return }
            let key = drain.begin(request)
            let producer = Task {
                defer { drain.end(key) }
                do {
                    try Task.checkCancellation()
                    try await produce(request: request) { event in
                        try Task.checkCancellation()
                        if case .terminated = continuation.yield(event) { throw CancellationError() }
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private func produce(request: ModelRequest, emit: ModelEventStream.Emit) async throws {
            let body: Data
            do { body = try ChatGPTPlanRequestEncoder.encode(request) }
            catch let error as ModelProviderError { throw error }
            catch { throw ModelProviderError(kind: .invalidRequest, message: "ChatGPT-plan request cannot be encoded.") }
            let token = try await credentials.token()
            var http = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            http.httpMethod = "POST"; http.httpBody = body
            http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            try Task.checkCancellation()
            var sse = try ProviderSSEDecoder()
            var decoder = ResponsesStreamDecoder(model: request.model, chatGPTPlanToolNames: request.tools.map(\.name))
            var validation = ModelEventAccumulator(), receivedHeader = false
            var events = transport.stream(http).makeAsyncIterator()
            while let event = try await events.next() {
                try Task.checkCancellation()
                switch event {
                case .response(let status, let headers):
                    guard !receivedHeader else { throw ProviderJSON.invalid() }
                    guard status == 200 else { throw try await ChatGPTPlanFailure.http(status, headers: headers, events: &events) }
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
            try sse.finish(); try decoder.finish()
            do { _ = try validation.finish() } catch { throw ProviderJSON.invalid() }
    }
}
