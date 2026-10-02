import AgentCore
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XCTest
@testable import AgentProviders

/// Provider failures that mean "the request exceeded the model's context window".
/// Payloads are the exact bodies observed from LM Studio on 2026-10-02 and the
/// documented OpenAI, llama.cpp server and Anthropic shapes.
struct ContextWindowExceededTests {
    // MARK: LM Studio

    @Test func lmStudioHTTP500BodyIsContextWindowExceeded() async throws {
        let failure = try await localFailure(status: 500, body: Data(lmStudioHTTP500Body.utf8))
        #expect(failure.kind == .contextWindowExceeded)
        #expect(failure.retryAfter == nil)
        expectSanitized(failure)
    }

    @Test func lmStudioStreamErrorEventIsContextWindowExceeded() async throws {
        let failure = try await localFailure(status: 200, body: lmStudioStream)
        #expect(failure.kind == .contextWindowExceeded)
        expectSanitized(failure)
    }

    @Test func lmStudioResponseFailedAloneIsContextWindowExceeded() async throws {
        let body = sse([
            ("response.failed", #"{"type":"response.failed","response":{"id":"resp_lm","object":"response","status":"failed","model":"fixture","output":[],"error":{"code":"unknown","message":"\#(lmStudioMessage)"}},"sequence_number":0}"#),
        ])
        let failure = try await localFailure(status: 200, body: body)
        #expect(failure.kind == .contextWindowExceeded)
        expectSanitized(failure)
    }

    @Test func legacyLMStudioStringErrorBodyIsContextWindowExceeded() async throws {
        let body = #"{"error":"Trying to keep the first 4994 tokens when context the overflows. However, the model is loaded with context length of only 4096 tokens, which is not enough. Try to load the model with a larger context length, or provide shorter input"}"#
        let failure = try await localFailure(status: 400, body: Data(body.utf8))
        #expect(failure.kind == .contextWindowExceeded)
        #expect(!failure.message.contains("Trying to keep"))
    }

    // MARK: llama.cpp server

    @Test func llamaServerExceedContextSizeErrorIsContextWindowExceeded() async throws {
        let body = #"{"error":{"code":400,"message":"the request exceeds the available context size, try increasing it","type":"exceed_context_size_error","n_prompt_tokens":23449,"n_ctx":16384}}"#
        let failure = try await localFailure(status: 400, body: Data(body.utf8))
        #expect(failure.kind == .contextWindowExceeded)
        #expect(!failure.message.contains("available context size"))
    }

    // MARK: OpenAI

    @Test func openAIHTTP400ContextLengthExceededIsContextWindowExceeded() async throws {
        let body = #"{"error":{"message":"Your input exceeds the context window of this model. Please adjust your input and try again.","type":"invalid_request_error","param":"input","code":"context_length_exceeded"}}"#
        let failure = try await openAIFailure(status: 400, body: Data(body.utf8))
        #expect(failure.kind == .contextWindowExceeded)
        #expect(!failure.message.contains("Your input"))
    }

    @Test func openAINestedStreamErrorContextLengthExceededIsContextWindowExceeded() async throws {
        let body = sse([
            ("response.created", #"{"type":"response.created","response":{"id":"resp-1","model":"fixture","status":"in_progress"},"sequence_number":0}"#),
            ("error", #"{"type":"error","sequence_number":1,"error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"Your input exceeds the context window of this model.","param":"input"}}"#),
        ])
        let failure = try await openAIFailure(status: 200, body: body)
        #expect(failure.kind == .contextWindowExceeded)
        #expect(!failure.message.contains("Your input"))
    }

    @Test func openAIFlatStreamErrorContextLengthExceededIsContextWindowExceeded() async throws {
        let body = sse([
            ("error", #"{"type":"error","code":"context_length_exceeded","message":"Your input exceeds the context window of this model.","param":"input","sequence_number":0}"#),
        ])
        let failure = try await openAIFailure(status: 200, body: body)
        #expect(failure.kind == .contextWindowExceeded)
    }

    @Test func openAIResponseFailedContextLengthExceededIsContextWindowExceeded() async throws {
        let body = sse([
            ("response.created", #"{"type":"response.created","response":{"id":"resp-1","model":"fixture","status":"in_progress"},"sequence_number":0}"#),
            ("response.failed", #"{"type":"response.failed","response":{"id":"resp-1","model":"fixture","status":"failed","error":{"code":"context_length_exceeded","message":"Your input exceeds the context window of this model."}},"sequence_number":1}"#),
        ])
        let failure = try await openAIFailure(status: 200, body: body)
        #expect(failure.kind == .contextWindowExceeded)
        #expect(!failure.message.contains("Your input"))
    }

    /// OpenAI documents a flat `error` event, but the live service nests the
    /// fields under `error`. Both shapes classify by the same code table.
    @Test func nestedStreamErrorEventIsClassifiedByItsCode() async throws {
        let cases: [(String, ModelProviderError.Kind)] = [
            ("rate_limit_exceeded", .rateLimited), ("server_error", .unavailable),
            ("invalid_prompt", .invalidRequest), ("insufficient_quota", .permissionDenied),
            ("future_code", .invalidResponse), ("unknown", .invalidResponse),
        ]
        for (code, expected) in cases {
            let body = sse([
                ("error", #"{"type":"error","sequence_number":0,"error":{"type":"invalid_request_error","code":"\#(code)","message":"private vendor diagnostic","param":null}}"#),
            ])
            let failure = try await openAIFailure(status: 200, body: body)
            #expect(failure.kind == expected, "code \(code)")
            #expect(!failure.message.contains("private"))
        }
        let nullCode = sse([
            ("error", #"{"type":"error","sequence_number":0,"error":{"type":"server_error","code":null,"message":"private vendor diagnostic"}}"#),
        ])
        #expect(try await openAIFailure(status: 200, body: nullCode).kind == .invalidResponse)
    }

    // MARK: Anthropic

    @Test func anthropicPromptTooLongIsContextWindowExceeded() async throws {
        let message = "prompt is too long: 203073 tokens > 200000 maximum"
        let httpBody = #"{"type":"error","error":{"type":"invalid_request_error","message":"\#(message)"},"request_id":"req_fixture"}"#
        let http = try await anthropicFailure(status: 400, body: Data(httpBody.utf8))
        #expect(http.kind == .contextWindowExceeded)
        #expect(!http.message.contains("prompt is too long"))

        let stream = providerSSE([#"{"type":"error","error":{"type":"invalid_request_error","message":"\#(message)"}}"#])
        let streamed = try await anthropicFailure(status: 200, body: stream)
        #expect(streamed.kind == .contextWindowExceeded)
        #expect(!streamed.message.contains("prompt is too long"))
    }

    @Test func anthropicOtherFailuresKeepTheirKinds() async throws {
        let invalid = #"{"type":"error","error":{"type":"invalid_request_error","message":"messages: roles must alternate"}}"#
        #expect(try await anthropicFailure(status: 400, body: Data(invalid.utf8)).kind == .invalidRequest)
        // The phrase only counts on an invalid request; elsewhere it is not a context signal.
        let overloaded = #"{"type":"error","error":{"type":"overloaded_error","message":"prompt is too long"}}"#
        #expect(try await anthropicFailure(status: 500, body: Data(overloaded.utf8)).kind == .unavailable)
        let streamed = providerSSE([#"{"type":"error","error":{"type":"api_error","message":"prompt is too long"}}"#])
        #expect(try await anthropicFailure(status: 200, body: streamed).kind == .unavailable)
    }

    // MARK: Unchanged classifications

    @Test func otherHTTPFailuresKeepTheirStatusClassification() async throws {
        let cases: [(Int, String, ModelProviderError.Kind)] = [
            (500, #"{"error":{"message":"Model crashed","type":"internal_error","param":null,"code":"unknown"}}"#, .unavailable),
            (500, "private diagnostic", .unavailable),
            (400, #"{"error":{"message":"Invalid input","type":"invalid_request_error","param":"input","code":"invalid_value"}}"#, .invalidRequest),
            (400, #"{"error":{"message":"maximum context length","type":"invalid_request_error","code":null}}"#, .invalidRequest),
            (503, #"{"error":{"message":"x","code":"context_length_exceeded"}}"#, .unavailable),
            (401, #"{"error":{"code":"context_length_exceeded"}}"#, .authentication),
            (429, #"{"error":{"code":"context_length_exceeded"}}"#, .rateLimited),
        ]
        for (status, body, expected) in cases {
            let failure = try await openAIFailure(status: status, body: Data(body.utf8))
            #expect(failure.kind == expected, "status \(status) body \(body)")
            #expect(failure.message == "Provider HTTP request failed (\(status)).")
            let local = try await localFailure(status: status, body: Data(body.utf8))
            #expect(local.kind == expected, "status \(status) body \(body)")
        }
    }

    @Test func unrelatedUnknownStreamErrorStaysInvalidResponse() async throws {
        let body = sse([
            ("response.created", #"{"type":"response.created","response":{"id":"resp_lm","model":"fixture","status":"in_progress"},"sequence_number":0}"#),
            ("error", #"{"type":"error","error":{"message":"Model crashed","type":"internal_error","code":"unknown","param":null},"sequence_number":1}"#),
        ])
        #expect(try await localFailure(status: 200, body: body).kind == .invalidResponse)
    }

    /// An oversized error body is never buffered without bound; the status decides.
    @Test(.timeLimit(.minutes(1)))
    func oversizedErrorBodyFallsBackToStatusWithoutWaitingForTheEnd() async throws {
        let provider = try LocalResponsesProvider(
            configuration: localConfiguration,
            transport: EndlessErrorBodyTransport(status: 500)
        )
        let failure = try await firstFailure(provider.stream(request: localRequest))
        #expect(failure.kind == .unavailable)
    }

    /// Waiting for an error body never delays cancellation.
    @Test func cancellingWhileReadingAnErrorBodyCancelsTheTransport() async throws {
        let entered = XCTestExpectation(description: "entered")
        let cancelled = XCTestExpectation(description: "cancelled")
        let provider = try LocalResponsesProvider(
            configuration: localConfiguration,
            transport: PendingErrorBodyTransport(entered: entered, cancelled: cancelled)
        )
        let run = try await Agent(model: provider.model, provider: provider).makeSession().run("Hi")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed)
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        #expect(await XCTWaiter.fulfillment(of: [cancelled], timeout: 2) == .completed)
    }

    // MARK: Retry, fallback and Run failure

    @Test func contextWindowExceededIsNeverRetryable() throws {
        #expect(ModelProviderError.Kind.contextWindowExceeded.rawValue == "contextWindowExceeded")
        #expect(throws: ModelProviderFallbackPolicyError.invalidRetryableKinds) {
            _ = try ModelProviderFallbackPolicy(retryableKinds: [.contextWindowExceeded])
        }
        #expect(try !ModelProviderFallbackPolicy().retryableKinds.contains(.contextWindowExceeded))
    }

    @Test func kindRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode([ModelProviderError.Kind.contextWindowExceeded])
        #expect(String(decoding: data, as: UTF8.self) == #"["contextWindowExceeded"]"#)
        #expect(try JSONDecoder().decode([ModelProviderError.Kind].self, from: data) == [.contextWindowExceeded])
    }

    /// LM Studio reports the overflow as HTTP 500, which used to classify as a
    /// retryable `unavailable`. The Route must neither retry nor fall back.
    @Test func routeDoesNotRetryOrFallBackOnContextWindowExceeded() async throws {
        let primary = ProviderRequestProbe()
        let secondary = ProviderRequestProbe()
        let route = try ModelProviderRoute(
            id: "local-responses",
            candidates: [
                .init(id: "primary", provider: try LocalResponsesProvider(
                    configuration: localConfiguration,
                    transport: FixtureHTTPTransport(probe: primary,
                                                    bodies: Array(repeating: Data(lmStudioHTTP500Body.utf8), count: 3),
                                                    status: 500, headers: ["Content-Type": "application/json"])
                )),
                .init(id: "secondary", provider: try LocalResponsesProvider(
                    configuration: localConfiguration,
                    transport: FixtureHTTPTransport(probe: secondary, bodies: [openAITextFixture])
                )),
            ],
            policy: .init(maxAttempts: 3, maxRetriesPerProvider: 2)
        )
        let failure = try await firstFailure(route.stream(request: localRequest))
        #expect(failure.kind == .contextWindowExceeded)
        #expect(await primary.requests.count == 1)
        #expect(await secondary.requests.isEmpty)
    }

    @Test func runFailsWithTheContextWindowExceededProviderFailure() async throws {
        let provider = try LocalResponsesProvider(
            configuration: localConfiguration,
            transport: FixtureHTTPTransport(probe: .init(), bodies: [lmStudioStream])
        )
        let run = try await Agent(model: provider.model, provider: provider).makeSession().run("Hi")
        var terminal: AgentEvent?
        for await event in run.events { terminal = event }
        do {
            _ = try await run.wait()
            Issue.record("An overflowing request must fail the Run")
        } catch {
            #expect((error as? ModelProviderError)?.kind == .contextWindowExceeded)
        }
        guard case .runFinished(.failed(.provider(let failure))) = terminal else {
            Issue.record("Unexpected terminal event \(String(describing: terminal))")
            return
        }
        #expect(failure.kind == .contextWindowExceeded)
    }

    // MARK: Fixtures

    private let lmStudioMessage = "The number of tokens to keep from the initial prompt is greater than the context length. Try to load the model with a larger context length, or provide a shorter input"

    private var lmStudioHTTP500Body: String {
        #"{"error":{"message":"\#(lmStudioMessage)","type":"internal_error","param":null,"code":"unknown"}}"#
    }

    private var lmStudioStream: Data {
        sse([
            ("response.created", #"{"type":"response.created","response":{"id":"resp_lm","object":"response","status":"in_progress","model":"fixture","output":[]},"sequence_number":0}"#),
            ("response.in_progress", #"{"type":"response.in_progress","response":{"id":"resp_lm","object":"response","status":"in_progress","model":"fixture","output":[]},"sequence_number":1}"#),
            ("error", #"{"type":"error","error":{"message":"\#(lmStudioMessage)","type":"internal_error","code":"unknown","param":null},"sequence_number":2}"#),
            ("response.failed", #"{"type":"response.failed","response":{"id":"resp_lm","object":"response","status":"failed","model":"fixture","output":[],"error":{"code":"unknown","message":"\#(lmStudioMessage)"}},"sequence_number":3}"#),
        ])
    }

    private var localConfiguration: LocalResponsesProvider.Configuration {
        .init(baseURL: URL(string: "http://127.0.0.1:1234/v1")!, model: "fixture")
    }

    private var localRequest: ModelRequest {
        .init(model: .init(provider: "local-responses", name: "fixture"), messages: [.user([.text("Hi")])])
    }

    private func sse(_ frames: [(String, String)]) -> Data {
        Data(frames.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined().utf8)
    }

    private func localFailure(status: Int, body: Data) async throws -> ModelProviderError {
        let provider = try LocalResponsesProvider(
            configuration: localConfiguration,
            transport: FixtureHTTPTransport(probe: .init(), bodies: [body], status: status)
        )
        return try await firstFailure(provider.stream(request: localRequest))
    }

    private func openAIFailure(status: Int, body: Data) async throws -> ModelProviderError {
        let provider = try OpenAIResponsesProvider(
            apiKey: "key",
            transport: FixtureHTTPTransport(probe: .init(), bodies: [body], status: status)
        )
        return try await firstFailure(provider.stream(request: .init(
            model: .init(provider: "openai", name: "fixture"), messages: [.user([.text("Hi")])]
        )))
    }

    private func anthropicFailure(status: Int, body: Data) async throws -> ModelProviderError {
        let provider = try AnthropicProvider(
            apiKey: "key",
            transport: FixtureHTTPTransport(probe: .init(), bodies: [body], status: status)
        )
        return try await firstFailure(provider.stream(request: .init(
            model: .init(provider: "anthropic", name: "fixture"), messages: [.user([.text("Hi")])]
        )))
    }

    private func firstFailure(_ stream: AsyncThrowingStream<ModelEvent, Error>) async throws -> ModelProviderError {
        do {
            for try await _ in stream {}
        } catch let error as ModelProviderError {
            return error
        }
        throw FixtureExpectationFailure()
    }
}

private struct FixtureExpectationFailure: Error {}

/// A classified failure never carries the provider's raw message.
private func expectSanitized(_ failure: ModelProviderError, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!failure.message.contains("tokens to keep"), sourceLocation: sourceLocation)
    #expect(!failure.message.contains("Try to load"), sourceLocation: sourceLocation)
}

/// Sends an error status and keeps sending body bytes without ever finishing.
private struct EndlessErrorBodyTransport: ProviderHTTPTransport {
    let status: Int

    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.response(status: status, headers: ["Content-Type": "application/json"]))
            continuation.yield(.data(Data(repeating: UInt8(ascii: " "), count: 256 * 1_024)))
        }
    }
}

/// Sends HTTP 500 and part of a body, then waits until it is cancelled.
private struct PendingErrorBodyTransport: ProviderHTTPTransport {
    let entered: XCTestExpectation
    let cancelled: XCTestExpectation

    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in cancelled.fulfill() }
            continuation.yield(.response(status: 500, headers: ["Content-Type": "application/json"]))
            continuation.yield(.data(Data(#"{"error":{"message":"The number of tokens"#.utf8)))
            entered.fulfill()
        }
    }
}
