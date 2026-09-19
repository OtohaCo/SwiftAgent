import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest
@testable import AgentProviders

struct OpenAIResponsesFailureTests {
    @Test func rateLimitPreservesRetryAfterWithoutLeakingBody() async throws {
        let provider = try OpenAIResponsesProvider(apiKey: "key", transport: FixtureHTTPTransport(
            probe: ProviderRequestProbe(), bodies: [Data("private diagnostic".utf8)], status: 429,
            headers: ["Retry-After": "17"]
        ))
        do { for try await _ in provider.stream(request: request) {}; Issue.record("HTTP failure must throw") }
        catch {
            let failure = try #require(error as? ModelProviderError)
            #expect(failure.kind == .rateLimited)
            #expect(failure.retryAfter == .seconds(17))
            #expect(!failure.message.contains("private"))
        }
    }

    @Test func cancellingRunTerminatesTransportBeforeAnyPartialToolExecutes() async throws {
        let entered = XCTestExpectation(description: "entered")
        let cancelled = XCTestExpectation(description: "cancelled")
        let execution = ProviderExecutionProbe()
        let provider = try OpenAIResponsesProvider(apiKey: "key",
            transport: PendingOpenAIHTTP(entered: entered, cancelled: cancelled))
        let run = try await Agent(model: request.model, provider: provider,
                                  tools: [ProviderCalculator(probe: execution)]).makeSession().run("Compute")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed)
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        #expect(await XCTWaiter.fulfillment(of: [cancelled], timeout: 2) == .completed)
        #expect(await execution.count == 0)
    }

    @Test func invalidConfigurationAndWrongProviderFailBeforeNetworking() async throws {
        #expect(throws: ModelProviderError.self) { try OpenAIResponsesProvider(apiKey: "") }
        #expect(throws: ModelProviderError.self) {
            try OpenAIResponsesProvider(apiKey: "key", endpoint: URL(string: "http://example.com/v1/responses")!)
        }
        #expect(throws: ModelProviderError.self) {
            try OpenAIResponsesProvider(apiKey: "key", reasoningEffort: .init(rawValue: ""))
        }
        #expect(throws: ModelProviderError.self) {
            try OpenAIResponsesProvider(apiKey: "key", resolvedModelIDsByAlias: ["fixture": ""])
        }
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(apiKey: "key",
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
        do {
            for try await _ in provider.stream(request: .init(model: .init(provider: "anthropic", name: "fixture"),
                                                               messages: [.user([.text("Hi")])])) {}
            Issue.record("Wrong provider must fail")
        } catch { #expect((error as? ModelProviderError)?.kind == .invalidRequest) }
        #expect(await probe.requests.isEmpty)
    }

    @Test func mismatchedEventLabelModelAndPostTerminalDataFailClosed() async throws {
        let base = String(decoding: openAITextFixture, as: UTF8.self)
        let bodies = [
            base.replacingOccurrences(of: "event: response.created", with: "event: response.completed"),
            base.replacingOccurrences(of: #""model":"fixture""#, with: #""model":"other""#),
            base + String(decoding: providerNamedSSE([("response.output_text.delta",
                #"{"type":"response.output_text.delta","item_id":"msg-1","output_index":0,"content_index":0,"delta":"late","sequence_number":5}"#)]), as: UTF8.self),
        ]
        for body in bodies {
            let provider = try OpenAIResponsesProvider(apiKey: "key",
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(body.utf8)]))
            do { for try await _ in provider.stream(request: request) {}; Issue.record("Malformed stream must fail") }
            catch { #expect((error as? ModelProviderError)?.kind == .invalidResponse) }
        }
    }

    @Test func hostedToolOutputNeverBecomesAHostToolCall() async throws {
        let body = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"resp-1","model":"fixture","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"ws-1","type":"web_search_call","status":"in_progress"}}"#),
        ])
        let provider = try OpenAIResponsesProvider(apiKey: "key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body]))
        do { for try await _ in provider.stream(request: request) {}; Issue.record("Hosted tool must be rejected") }
        catch { #expect((error as? ModelProviderError)?.kind == .unsupportedCapability) }
    }

    @Test func missingTerminalAndMalformedFunctionArgumentsFailClosed() async throws {
        let missing = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"resp-1","model":"fixture","status":"in_progress"}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg-1","output_index":0,"content_index":0,"delta":"Hi"}"#),
        ])
        let malformed = String(decoding: openAIToolFixture, as: UTF8.self)
            .replacingOccurrences(of: #"{\"a\":2,\"b\":3}"#, with: #"{\"a\":"#)
        for body in [missing, Data(malformed.utf8)] {
            let provider = try OpenAIResponsesProvider(apiKey: "key",
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body]))
            do { for try await _ in provider.stream(request: request) {}; Issue.record("Invalid stream must fail") }
            catch { #expect((error as? ModelProviderError)?.kind == .invalidResponse) }
        }
    }

    @Test func truncatedFunctionCallIsIncompleteAndNeverExecutes() async throws {
        let body = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"resp-1","model":"fixture","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"","status":"in_progress"}}"#),
            ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","item_id":"fc-1","output_index":0,"delta":"{\"a\":"}"#),
            ("response.incomplete", #"{"type":"response.incomplete","response":{"id":"resp-1","model":"fixture","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":"}],"usage":{"input_tokens":5,"output_tokens":4}}}"#),
        ])
        let execution = ProviderExecutionProbe()
        let provider = try OpenAIResponsesProvider(apiKey: "key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body]))
        let result = try await Agent(model: request.model, provider: provider,
                                     tools: [ProviderCalculator(probe: execution)]).makeSession().run("Compute").wait()
        #expect(result.outcome == .incomplete(.maxOutputTokens))
        #expect(result.response.toolCalls == [
            .init(id: .init(rawValue: "call-1"), name: "calculator", argumentsJSON: #"{"a":"#, completeness: .incomplete),
        ])
        #expect(await execution.count == 0)
    }

    @Test func explicitResolvedModelAliasIsAcceptedAndUndeclaredSnapshotIsRejected() async throws {
        let resolved = String(decoding: openAITextFixture, as: UTF8.self)
            .replacingOccurrences(of: #""model":"fixture""#, with: #""model":"fixture-2026-09-19""#)
        let accepted = try OpenAIResponsesProvider(apiKey: "key",
            resolvedModelIDsByAlias: ["fixture": "fixture-2026-09-19"],
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(resolved.utf8)]))
        for try await _ in accepted.stream(request: request) {}

        let rejected = try OpenAIResponsesProvider(apiKey: "key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(resolved.utf8)]))
        do { for try await _ in rejected.stream(request: request) {}; Issue.record("Undeclared snapshot must fail") }
        catch {
            let failure = try #require(error as? ModelProviderError)
            #expect(failure.kind == .invalidResponse)
            #expect(failure.message.contains("fixture-2026-09-19"))
            #expect(failure.message.contains("fixture"))
        }
    }

    @Test func streamFailuresUseTypedSanitizedClassification() async throws {
        let cases: [(String, ModelProviderError.Kind)] = [
            ("rate_limit_exceeded", .rateLimited), ("server_error", .unavailable),
            ("vector_store_timeout", .unavailable), ("invalid_prompt", .invalidRequest),
            ("invalid_request_error", .invalidRequest), ("data_residency_mismatch", .invalidRequest),
            ("bio_policy", .invalidRequest), ("misalignment_policy_violation", .invalidRequest),
            ("insufficient_quota", .permissionDenied), ("future_code", .invalidResponse),
        ]
        for (code, expected) in cases {
            let body = providerNamedSSE([
                ("error", #"{"type":"error","code":"\#(code)","message":"private vendor diagnostic"}"#),
            ])
            let provider = try OpenAIResponsesProvider(apiKey: "key",
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body]))
            do { for try await _ in provider.stream(request: request) {}; Issue.record("Stream error must throw") }
            catch {
                let failure = try #require(error as? ModelProviderError)
                #expect(failure.kind == expected)
                #expect(!failure.message.contains("private"))
            }
        }

        let failed = providerNamedSSE([
            ("response.failed", #"{"type":"response.failed","response":{"id":"resp-failed","model":"fixture","status":"failed","error":{"code":"invalid_prompt","message":"private vendor diagnostic"}}}"#),
        ])
        let provider = try OpenAIResponsesProvider(apiKey: "key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [failed]))
        do { for try await _ in provider.stream(request: request) {}; Issue.record("Failed response must throw") }
        catch {
            let failure = try #require(error as? ModelProviderError)
            #expect(failure.kind == .invalidRequest)
            #expect(!failure.message.contains("private"))
        }
    }

    @Test func unknownAndUnstreamedOutputItemsFailClosedWithUsefulKinds() async throws {
        let unknown = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"resp-1","model":"fixture","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"new-1","type":"future_item"}}"#),
        ])
        let unstreamed = String(decoding: openAITextFixture, as: UTF8.self)
            .replacingOccurrences(of: #""output":[{"id":"msg-1""#,
                with: #""output":[{"id":"fc-hidden","type":"function_call","call_id":"hidden","name":"calculator","arguments":"{}"},{"id":"msg-1""#)
        let fixtures: [(Data, ModelProviderError.Kind)] = [(unknown, .unsupportedCapability), (Data(unstreamed.utf8), .invalidResponse)]
        for (body, kind) in fixtures {
            let provider = try OpenAIResponsesProvider(apiKey: "key",
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body]))
            do { for try await _ in provider.stream(request: request) {}; Issue.record("Unexpected item must fail") }
            catch { #expect((error as? ModelProviderError)?.kind == kind) }
        }
    }

    private var request: ModelRequest {
        .init(model: .init(provider: "openai", name: "fixture"), messages: [.user([.text("Hi")])])
    }
}

private struct PendingOpenAIHTTP: ProviderHTTPTransport {
    let entered: XCTestExpectation
    let cancelled: XCTestExpectation

    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in cancelled.fulfill() }
            continuation.yield(.response(status: 200, headers: ["Content-Type": "text/event-stream"]))
            continuation.yield(.data(providerNamedSSE([
                ("response.created", #"{"type":"response.created","response":{"id":"pending","model":"fixture","status":"in_progress"}}"#),
                ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"","status":"in_progress"}}"#),
                ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","item_id":"fc-1","output_index":0,"delta":"{"}"#),
            ])))
            entered.fulfill()
        }
    }
}
