import AgentCore
import AgentModels
import AgentTools
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XCTest
@testable import AgentProviders

struct DeepSeekResponsesProviderTests {
    @Test func textRequestIsStatelessAndUsesDefaultHighReasoning() async throws {
        let probe = ProviderRequestProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            maximumOutputTokens: 1_024,
            transport: FixtureHTTPTransport(probe: probe, bodies: [deepSeekTextFixture])
        )
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(
            model: .init(provider: "deepseek", name: "deepseek-flash"),
            messages: [.system("Be concise"), .user([.text("Hi")])]
        )) { try accumulator.append(event) }
        let response = try accumulator.finish()
        #expect(response.content.contains(.reasoning("Considered.")))
        #expect(response.content.contains(.text("Hello")))
        #expect(response.usage == .init(inputTokens: 5, outputTokens: 3, cachedInputTokens: 0,
                                        reasoningTokens: 1))
        #expect(provider.descriptor.id == "deepseek")

        let body = try requestBody(await probe.requests.first)
        #expect(body["model"] == .string("deepseek-flash"))
        #expect(body["stream"] == .bool(true))
        #expect(body["max_output_tokens"] == .number(1_024))
        #expect(body["reasoning"] == .object(["effort": .string("high")]))
        #expect(body["previous_response_id"] == nil)
        #expect(body["conversation"] == nil)
        #expect(body["store"] == nil)
        #expect(body["include"] == nil)
        #expect(body["input"] == .array([
            .object(["type": .string("message"), "role": .string("system"),
                     "content": .string("Be concise")]),
            .object(["type": .string("message"), "role": .string("user"),
                     "content": .string("Hi")]),
        ]))
    }

    @Test func reasoningEffortAcceptsAndPreservesFutureWireValues() async throws {
        let effort = DeepSeekReasoningEffort(rawValue: "medium")
        let encoded = try JSONEncoder().encode(effort)
        #expect(try JSONDecoder().decode(DeepSeekReasoningEffort.self, from: encoded) == effort)

        let probe = ProviderRequestProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            reasoningEffort: effort,
            transport: FixtureHTTPTransport(probe: probe, bodies: [deepSeekTextFixture])
        )
        for try await _ in provider.stream(request: .init(
            model: .init(provider: "deepseek", name: "deepseek-flash"),
            messages: [.user([.text("Hi")])]
        )) {}

        let body = try requestBody(await probe.requests.first)
        #expect(body["reasoning"] == .object(["effort": .string("medium")]))
    }

    @Test func invalidReasoningEffortFailsDuringProviderConstruction() {
        #expect(throws: ModelProviderError.self) {
            try DeepSeekResponsesProvider(
                apiKey: "fixture-key",
                reasoningEffort: .init(rawValue: "")
            )
        }
        #expect(throws: ModelProviderError.self) {
            try DeepSeekResponsesProvider(
                apiKey: "fixture-key",
                reasoningEffort: .init(rawValue: " high ")
            )
        }
    }

    @Test func developerRoleFailsBeforeNetwork() async throws {
        let probe = ProviderRequestProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: probe, bodies: [deepSeekTextFixture])
        )
        do {
            for try await _ in provider.stream(request: .init(
                model: .init(provider: "deepseek", name: "deepseek-flash"),
                messages: [.developer("Trusted instruction"), .user([.text("Hi")])]
            )) {}
            Issue.record("Expected developer-role rejection")
        } catch let error as ModelProviderError {
            #expect(error.kind == .unsupportedCapability)
        }
        #expect(await probe.requests.isEmpty)
    }

    @Test func reasoningTextAndFunctionCallRoundTripAcrossThreeTurns() async throws {
        let probe = ProviderRequestProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(
                probe: probe,
                bodies: [deepSeekReasoningToolFixture(call: 1), deepSeekReasoningToolFixture(call: 2),
                         deepSeekTextFixture]
            )
        )
        let result = try await Agent(
            model: .init(provider: "deepseek", name: "deepseek-flash"), provider: provider,
            tools: [ProviderCalculator()],
            configuration: .init(maxModelTurns: 3, maxToolCalls: 2)
        ).makeSession().run("Add values twice").wait()
        #expect(result.modelTurns == 3)
        #expect(result.toolCalls == 2)

        let requests = await probe.requests
        #expect(requests.count == 3)
        let second = try requestBody(requests[1])
        let third = try requestBody(requests[2])
        guard case .array(let secondInput) = second["input"],
              case .array(let thirdInput) = third["input"] else {
            Issue.record("Missing stateless input"); return
        }
        #expect(secondInput.contains(deepSeekReasoningItem(call: 1)))
        #expect(secondInput.contains(deepSeekFunctionItem(call: 1)))
        #expect(secondInput.contains(deepSeekFunctionOutput(call: 1)))
        #expect(thirdInput.contains(deepSeekReasoningItem(call: 1)))
        #expect(thirdInput.contains(deepSeekReasoningItem(call: 2)))
        #expect(thirdInput.contains(deepSeekFunctionOutput(call: 2)))
    }

    @Test func missingReasoningForThinkingToolHistoryFailsBeforeNetwork() async throws {
        let probe = ProviderRequestProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: probe, bodies: [deepSeekTextFixture])
        )
        let call = ToolCall(id: .init(rawValue: "call-1"), name: "calculator",
                            argumentsJSON: #"{"a":2,"b":3}"#, completeness: .complete)
        let request = ModelRequest(
            model: .init(provider: "deepseek", name: "deepseek-flash"),
            messages: [
                .user([.text("Add")]),
                .assistant(content: [], toolCalls: [call]),
                .tool(.init(callID: call.id, content: [.text(#"{"sum":5}"#)], isError: false)),
            ],
            tools: [.init(name: "calculator", description: "Add", inputSchema: .object([:]))]
        )
        do {
            for try await _ in provider.stream(request: request) {}
            Issue.record("Expected missing reasoning rejection")
        } catch let error as ModelProviderError {
            #expect(error.kind == .invalidRequest)
        }
        #expect(await probe.requests.isEmpty)
    }

    @Test func reasoningDisabledAllowsCanonicalAssistantHistory() async throws {
        let probe = ProviderRequestProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key", reasoningEffort: .none,
            transport: FixtureHTTPTransport(probe: probe, bodies: [deepSeekTextWithoutReasoningFixture])
        )
        for try await _ in provider.stream(request: .init(
            model: .init(provider: "deepseek", name: "deepseek-flash"),
            messages: [.assistant(content: [.text("Earlier")], toolCalls: []), .user([.text("Continue")])],
            tools: [.init(name: "calculator", description: "Add", inputSchema: .object([:]))]
        )) {}
        let body = try requestBody(await probe.requests.first)
        #expect(body["reasoning"] == .object(["effort": .string("none")]))
    }

    @Test func thinkingWithAvailableToolsAllowsATextOnlyTerminalResponse() async throws {
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(),
                bodies: [deepSeekTextWithoutReasoningFixture]
            )
        )

        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(
            model: .init(provider: "deepseek", name: "deepseek-flash"),
            messages: [.user([.text("Answer without another tool call")])],
            tools: [.init(name: "calculator", description: "Add", inputSchema: .object([:]))]
        )) {
            try accumulator.append(event)
        }

        let response = try accumulator.finish()
        #expect(response.toolCalls.isEmpty)
        #expect(response.content == [.text("Hello")])
    }

    @Test func thinkingToolResultCanFinishWithTextWithoutMoreReasoning() async throws {
        let probe = ProviderRequestProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(
                probe: probe,
                bodies: [deepSeekReasoningToolFixture(call: 1), deepSeekTextWithoutReasoningFixture]
            )
        )
        let result = try await Agent(
            model: .init(provider: "deepseek", name: "deepseek-flash"),
            provider: provider,
            tools: [ProviderCalculator()],
            configuration: .init(maxModelTurns: 2, maxToolCalls: 1)
        ).makeSession().run("Use the calculator, then answer").wait()

        #expect(result.modelTurns == 2)
        #expect(result.toolCalls == 1)
        #expect(result.response.content == [.text("Hello")])

        let requests = await probe.requests
        #expect(requests.count == 2)
        let second = try requestBody(requests[1])
        guard case .array(let input) = second["input"] else {
            Issue.record("Missing stateless input")
            return
        }
        #expect(input.contains(deepSeekReasoningItem(call: 1)))
        #expect(input.contains(deepSeekFunctionItem(call: 1)))
        #expect(input.contains(deepSeekFunctionOutput(call: 1)))
    }

    @Test func thinkingToolCallWithoutReasoningStillFailsClosed() async throws {
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(),
                bodies: [openAIToolFixture]
            )
        )

        await #expect(throws: ModelProviderError.self) {
            for try await _ in provider.stream(request: .init(
                model: .init(provider: "deepseek", name: "fixture"),
                messages: [.user([.text("Use the calculator")])],
                tools: [.init(name: "calculator", description: "Add", inputSchema: .object([:]))]
            )) {}
        }
    }

    @Test func structuredOutputAndFunctionToolsUseDeepSeekShapes() async throws {
        let probe = ProviderRequestProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key", reasoningEffort: .low,
            transport: FixtureHTTPTransport(probe: probe, bodies: [deepSeekTextFixture])
        )
        let schema = ToolSchema.object(properties: ["answer": .string], required: ["answer"]).json
        for try await _ in provider.stream(request: .init(
            model: .init(provider: "deepseek", name: "deepseek-flash"),
            messages: [.user([.text("Hi")])],
            tools: [.init(name: "lookup", description: "Look up", inputSchema: schema)],
            structuredOutput: .init(name: "answer", description: "Ignored by wire contract", schema: schema)
        )) {}
        let body = try requestBody(await probe.requests.first)
        #expect(body["tools"] == .array([.object([
            "type": .string("function"), "name": .string("lookup"),
            "description": .string("Look up"), "parameters": schema,
        ])]))
        #expect(body["text"] == .object(["format": .object([
            "type": .string("json_schema"), "name": .string("answer"), "schema": schema,
        ])]))
        #expect(body["reasoning"] == .object(["effort": .string("low")]))
    }

    @Test func usagePreservesNilAndZeroSubsets() async throws {
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [deepSeekUsageFixture])
        )
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(
            model: .init(provider: "deepseek", name: "deepseek-flash"),
            messages: [.user([.text("Hi")])]
        )) { try accumulator.append(event) }
        #expect(try accumulator.finish().usage == .init(inputTokens: 0, outputTokens: 0,
                                                        cachedInputTokens: nil, reasoningTokens: 0))
    }

    @Test func eventDataMismatchAndHostedItemsFailClosed() async throws {
        let mismatch = Data("event: response.output_text.delta\ndata: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"r\",\"model\":\"deepseek-flash\",\"status\":\"in_progress\"}}\n\n".utf8)
        await expectInvalidStream(mismatch)

        let hosted = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"r","model":"deepseek-flash","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"host-1","type":"web_search_call"}}"#),
        ])
        await expectUnsupportedStream(hosted)
    }

    @Test func malformedEventReportsOnlyTheSafeEventType() async throws {
        let body = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"r","model":"deepseek-flash","status":"in_progress"}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","output_index":0,"content_index":0,"item_id":"private-item","delta":"private-response-text"}"#),
        ])
        do {
            let provider = try DeepSeekResponsesProvider(
                apiKey: "key",
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body])
            )
            for try await _ in provider.stream(request: .init(
                model: .init(provider: "deepseek", name: "deepseek-flash"),
                messages: [.user([.text("Hi")])]
            )) {}
            Issue.record("Expected invalid response")
        } catch let error as ModelProviderError {
            #expect(error.kind == .invalidResponse)
            #expect(error.message == "Invalid DeepSeek event 'response.output_text.delta'.")
            #expect(!error.message.contains("private-item"))
            #expect(!error.message.contains("private-response-text"))
        }
    }

    @Test func completedSnapshotMismatchReportsOnlyTheValidationStage() async throws {
        let body = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"r","model":"deepseek-flash","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"m","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
            ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"m","output_index":0,"content_index":0,"part":{"type":"output_text","text":""}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"m","output_index":0,"content_index":0,"delta":"Hello"}"#),
            ("response.output_text.done", #"{"type":"response.output_text.done","item_id":"m","output_index":0,"content_index":0,"text":"Hello"}"#),
            ("response.content_part.done", #"{"type":"response.content_part.done","item_id":"m","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Hello"}}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"m","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}}"#),
            ("response.completed", #"{"type":"response.completed","response":{"id":"r","model":"deepseek-flash","status":"completed","output":[{"id":"m","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"private-rewrite"}]}],"usage":{"input_tokens":1,"output_tokens":1}}}"#),
        ])
        do {
            let provider = try DeepSeekResponsesProvider(
                apiKey: "key",
                reasoningEffort: .none,
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body])
            )
            for try await _ in provider.stream(request: .init(
                model: .init(provider: "deepseek", name: "deepseek-flash"),
                messages: [.user([.text("Hi")])]
            )) {}
            Issue.record("Expected invalid response")
        } catch let error as ModelProviderError {
            #expect(error.kind == .invalidResponse)
            #expect(error.message == "Invalid DeepSeek completed output snapshot.")
            #expect(!error.message.contains("private-rewrite"))
        }
    }

    @Test func configuredModelAliasBindsResponseIdentity() async throws {
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            resolvedModelIDsByAlias: ["fast": "deepseek-flash"],
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [deepSeekTextFixture])
        )
        for try await _ in provider.stream(request: .init(
            model: .init(provider: "deepseek", name: "fast"), messages: [.user([.text("Hi")])]
        )) {}

        let wrong = makeDeepSeekTextFixture(model: "deepseek-v4-pro")
        let wrongProvider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            resolvedModelIDsByAlias: ["fast": "deepseek-flash"],
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [wrong])
        )
        do {
            for try await _ in wrongProvider.stream(request: .init(
                model: .init(provider: "deepseek", name: "fast"), messages: [.user([.text("Hi")])]
            )) {}
            Issue.record("Expected model mismatch")
        } catch let error as ModelProviderError {
            #expect(error.kind == .invalidResponse)
        }
    }

    @Test func cancellationStopsTransportAndHTTPFailuresRemainTyped() async throws {
        let entered = XCTestExpectation(description: "DeepSeek HTTP entered")
        let cancelled = XCTestExpectation(description: "DeepSeek HTTP cancelled")
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key", transport: DeepSeekPendingHTTP(entered: entered, cancelled: cancelled)
        )
        let execution = ProviderExecutionProbe()
        let run = try await Agent(
            model: .init(provider: "deepseek", name: "deepseek-flash"), provider: provider,
            tools: [ProviderCalculator(probe: execution)]
        ).makeSession().run("Hi")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed)
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        #expect(await XCTWaiter.fulfillment(of: [cancelled], timeout: 2) == .completed)
        #expect(await execution.count == 0)

        let failing = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data()], status: 429,
                                            headers: ["Retry-After": "7"])
        )
        do {
            for try await _ in failing.stream(request: .init(
                model: .init(provider: "deepseek", name: "deepseek-flash"),
                messages: [.user([.text("Hi")])]
            )) {}
            Issue.record("Expected HTTP failure")
        } catch let error as ModelProviderError {
            #expect(error.kind == .rateLimited)
            #expect(error.retryAfter == .seconds(7))
        }
    }

    private func requestBody(_ request: URLRequest?) throws -> [String: JSONValue] {
        guard let data = try #require(request?.httpBody),
              case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            Issue.record("Missing request body"); return [:]
        }
        return body
    }

    private func expectInvalidStream(_ body: Data) async {
        do {
            let provider = try DeepSeekResponsesProvider(apiKey: "key",
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body]))
            for try await _ in provider.stream(request: .init(
                model: .init(provider: "deepseek", name: "deepseek-flash"),
                messages: [.user([.text("Hi")])]
            )) {}
            Issue.record("Expected invalid response")
        } catch let error as ModelProviderError { #expect(error.kind == .invalidResponse) }
        catch { Issue.record("Unexpected error: \(error)") }
    }

    private func expectUnsupportedStream(_ body: Data) async {
        do {
            let provider = try DeepSeekResponsesProvider(apiKey: "key",
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body]))
            for try await _ in provider.stream(request: .init(
                model: .init(provider: "deepseek", name: "deepseek-flash"),
                messages: [.user([.text("Hi")])]
            )) {}
            Issue.record("Expected unsupported capability")
        } catch let error as ModelProviderError { #expect(error.kind == .unsupportedCapability) }
        catch { Issue.record("Unexpected error: \(error)") }
    }
}

private struct DeepSeekPendingHTTP: ProviderHTTPTransport {
    let entered: XCTestExpectation
    let cancelled: XCTestExpectation

    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in cancelled.fulfill() }
            continuation.yield(.response(status: 200, headers: ["Content-Type": "text/event-stream"]))
            continuation.yield(.data(providerNamedSSE([
                ("response.created", #"{"type":"response.created","response":{"id":"pending","model":"deepseek-flash","status":"in_progress"}}"#),
            ])))
            entered.fulfill()
        }
    }
}

private func makeDeepSeekTextFixture(model: String = "deepseek-flash") -> Data {
    providerNamedSSE([
        ("response.created", #"{"type":"response.created","response":{"id":"resp-text","model":"\#(model)","status":"in_progress"}}"#),
        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs-text","type":"reasoning","status":"in_progress","content":[]}}"#),
        ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"rs-text","output_index":0,"content_index":0,"part":{"type":"reasoning_text","text":""}}"#),
        ("response.reasoning_text.delta", #"{"type":"response.reasoning_text.delta","item_id":"rs-text","output_index":0,"content_index":0,"delta":"Considered."}"#),
        ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs-text","type":"reasoning","status":"completed","content":[{"type":"reasoning_text","text":"Considered."}]}}"#),
        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"msg-text","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
        ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"msg-text","output_index":1,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
        ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg-text","output_index":1,"content_index":0,"delta":"Hello"}"#),
        ("response.output_item.done", #"{"type":"response.output_item.done","output_index":1,"item":{"id":"msg-text","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello","annotations":[]}]}}"#),
        ("response.completed", #"{"type":"response.completed","response":{"id":"resp-text","model":"\#(model)","status":"completed","output":[{"id":"rs-text","type":"reasoning","status":"completed","content":[{"type":"reasoning_text","text":"Considered."}]},{"id":"msg-text","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello","annotations":[]}]}],"usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens":3,"output_tokens_details":{"reasoning_tokens":1},"total_tokens":8}}}"#),
    ])
}

private let deepSeekTextFixture = makeDeepSeekTextFixture()

private let deepSeekTextWithoutReasoningFixture = providerNamedSSE([
    ("response.created", #"{"type":"response.created","response":{"id":"resp-plain","model":"deepseek-flash","status":"in_progress"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg-plain","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
    ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"msg-plain","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
    ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg-plain","output_index":0,"content_index":0,"delta":"Hello"}"#),
    ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg-plain","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello","annotations":[]}]}}"#),
    ("response.completed", #"{"type":"response.completed","response":{"id":"resp-plain","model":"deepseek-flash","status":"completed","output":[{"id":"msg-plain","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":1}}}"#),
])

private func deepSeekReasoningItem(call: Int) -> JSONValue {
    .object(["type": .string("reasoning"), "id": .string("rs-\(call)"),
             "status": .string("completed"), "content": .array([
                 .object(["type": .string("reasoning_text"), "text": .string("Reason \(call).")]),
             ])])
}

private func deepSeekFunctionItem(call: Int) -> JSONValue {
    .object(["type": .string("function_call"), "id": .string("fc-\(call)"),
             "call_id": .string("call-\(call)"), "name": .string("calculator"),
             "arguments": .string(#"{"a":2,"b":3}"#), "status": .string("completed")])
}

private func deepSeekFunctionOutput(call: Int) -> JSONValue {
    .object(["type": .string("function_call_output"), "call_id": .string("call-\(call)"),
             "output": .string(#"{"sum":5}"#)])
}

private func deepSeekReasoningToolFixture(call: Int) -> Data {
    providerNamedSSE([
        ("response.created", #"{"type":"response.created","response":{"id":"resp-tool-\#(call)","model":"deepseek-flash","status":"in_progress"}}"#),
        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs-\#(call)","type":"reasoning","status":"in_progress","content":[]}}"#),
        ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"rs-\#(call)","output_index":0,"content_index":0,"part":{"type":"reasoning_text","text":""}}"#),
        ("response.reasoning_text.delta", #"{"type":"response.reasoning_text.delta","item_id":"rs-\#(call)","output_index":0,"content_index":0,"delta":"Reason \#(call)."}"#),
        ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs-\#(call)","type":"reasoning","status":"completed","content":[{"type":"reasoning_text","text":"Reason \#(call)."}]}}"#),
        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"fc-\#(call)","type":"function_call","call_id":"call-\#(call)","name":"calculator","arguments":"","status":"in_progress"}}"#),
        ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","item_id":"fc-\#(call)","output_index":1,"delta":"{\"a\":2,\"b\":3}"}"#),
        ("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","item_id":"fc-\#(call)","output_index":1,"arguments":"{\"a\":2,\"b\":3}"}"#),
        ("response.output_item.done", #"{"type":"response.output_item.done","output_index":1,"item":{"id":"fc-\#(call)","type":"function_call","call_id":"call-\#(call)","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"}}"#),
        ("response.completed", #"{"type":"response.completed","response":{"id":"resp-tool-\#(call)","model":"deepseek-flash","status":"completed","output":[{"id":"rs-\#(call)","type":"reasoning","status":"completed","content":[{"type":"reasoning_text","text":"Reason \#(call)."}]},{"id":"fc-\#(call)","type":"function_call","call_id":"call-\#(call)","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"}],"usage":{"input_tokens":5,"output_tokens":4,"output_tokens_details":{"reasoning_tokens":2}}}}"#),
    ])
}

private let deepSeekUsageFixture = providerNamedSSE([
    ("response.created", #"{"type":"response.created","response":{"id":"resp-usage","model":"deepseek-flash","status":"in_progress"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg-usage","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
    ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg-usage","type":"message","role":"assistant","status":"completed","content":[]}}"#),
    ("response.completed", #"{"type":"response.completed","response":{"id":"resp-usage","model":"deepseek-flash","status":"completed","output":[{"id":"msg-usage","type":"message","role":"assistant","status":"completed","content":[]}],"usage":{"input_tokens":0,"output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":0}}}"#),
])
