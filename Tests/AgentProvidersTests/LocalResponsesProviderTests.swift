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

struct LocalResponsesProviderTests {
    @Test func configurationBuildsResponsesURLAndCanonicalRequestWithoutOpenAIState() async throws {
        let probe = ProviderRequestProbe()
        let provider = try LocalResponsesProvider(
            configuration: .init(
                baseURL: URL(string: "http://127.0.0.1:1234/v1/")!,
                model: "fixture",
                authentication: .bearer("local-token"),
                capabilities: [.tools, .structuredOutput]
            ),
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture])
        )
        let schema = ToolSchema.object(
            properties: ["query": .string],
            required: ["query"]
        ).json
        let request = ModelRequest(
            model: provider.model,
            messages: [
                .system("System"),
                .developer("Developer"),
                .user([.text("Question")]),
                .assistant(
                    content: [.reasoning("not replayed"), .text("Calling")],
                    toolCalls: [.init(
                        id: .init(rawValue: "call-1"),
                        name: "lookup",
                        argumentsJSON: #"{"query":"A"}"#,
                        completeness: .complete
                    )]
                ),
                .tool(.init(
                    callID: .init(rawValue: "call-1"),
                    content: [.json(.object(["result": .string("found")]))],
                    isError: false
                )),
            ],
            tools: [.init(name: "lookup", description: "Lookup", inputSchema: schema)],
            structuredOutput: .init(name: "answer", schema: schema)
        )

        for try await _ in provider.stream(request: request) {}

        let sent = try #require(await probe.requests.first)
        #expect(sent.url?.absoluteString == "http://127.0.0.1:1234/v1/responses")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer local-token")
        guard case .object(let body) = try JSONDecoder().decode(
            JSONValue.self,
            from: #require(sent.httpBody)
        ), case .array(let input) = body["input"] else {
            Issue.record("Missing local Responses request")
            return
        }
        #expect(body["model"] == .string("fixture"))
        #expect(body["previous_response_id"] == nil)
        #expect(body["conversation"] == nil)
        #expect(body["include"] == nil)
        #expect(body["reasoning"] == nil)
        #expect(body["store"] == nil)
        #expect(body["tools"] == .array([.object([
            "type": .string("function"), "name": .string("lookup"),
            "description": .string("Lookup"), "parameters": schema,
            "strict": .bool(false),
        ])]))
        #expect(body["text"] == .object(["format": .object([
            "type": .string("json_schema"), "name": .string("answer"),
            "schema": schema, "strict": .bool(true),
        ])]))
        #expect(input == [
            .object(["type": .string("message"), "role": .string("system"), "content": .string("System")]),
            .object(["type": .string("message"), "role": .string("developer"), "content": .string("Developer")]),
            .object(["type": .string("message"), "role": .string("user"), "content": .string("Question")]),
            .object(["type": .string("message"), "role": .string("assistant"), "content": .string("Calling")]),
            .object([
                "type": .string("function_call"), "call_id": .string("call-1"),
                "name": .string("lookup"), "arguments": .string(#"{"query":"A"}"#),
            ]),
            .object([
                "type": .string("function_call_output"), "call_id": .string("call-1"),
                "output": .string(#"{"result":"found"}"#),
            ]),
        ])
        #expect(provider.descriptor.id == "local-responses")
        #expect(provider.descriptor.capabilities.contains([.streaming, .multiTurn, .tools, .structuredOutput]))
        #expect(!provider.descriptor.capabilities.contains(.reasoning))
    }

    @Test func toolRoundUsesCanonicalReplayAndExecutesExactlyOnce() async throws {
        let probe = ProviderRequestProbe()
        let execution = ProviderExecutionProbe()
        let provider = try LocalResponsesProvider(
            configuration: .init(
                baseURL: URL(string: "http://localhost:1234/v1")!,
                model: "fixture",
                capabilities: [.tools]
            ),
            transport: FixtureHTTPTransport(
                probe: probe,
                bodies: [openAIToolFixture, openAITextFixture]
            )
        )
        let result = try await Agent(
            model: provider.model,
            provider: provider,
            tools: [ProviderCalculator(probe: execution)]
        ).makeSession().run("Add 2 and 3").wait()

        #expect(result.outcome == .completed)
        #expect(result.modelTurns == 2)
        #expect(result.toolCalls == 1)
        #expect(await execution.count == 1)
        #expect(!result.history.contains { message in
            guard case .assistant(let content, _) = message else { return false }
            return content.contains { if case .providerContinuation = $0 { true } else { false } }
        })

        let requests = await probe.requests
        #expect(requests.count == 2)
        guard case .object(let body) = try JSONDecoder().decode(
            JSONValue.self,
            from: #require(requests.last?.httpBody)
        ), case .array(let input) = body["input"] else {
            Issue.record("Missing second local request")
            return
        }
        #expect(body["previous_response_id"] == nil)
        #expect(input.contains(.object([
            "type": .string("function_call"), "call_id": .string("call-1"),
            "name": .string("calculator"), "arguments": .string(#"{"a":2,"b":3}"#),
        ])))
        #expect(input.contains(.object([
            "type": .string("function_call_output"), "call_id": .string("call-1"),
            "output": .string(#"{"sum":5}"#),
        ])))
    }

    @Test func responseStreamPreservesTextUsageAndSafeUnknownEventsWithoutContinuation() async throws {
        let body = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"local-1","model":"fixture","status":"in_progress"}}"#),
            ("response.local_metadata", #"{"type":"response.local_metadata","backend":"fixture"}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg-1","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
            ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"msg-1","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg-1","output_index":0,"content_index":0,"delta":"Hello"}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg-1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello","annotations":[]}]}}"#),
            ("response.completed", #"{"type":"response.completed","response":{"id":"local-1","model":"fixture","status":"completed","output":[{"id":"msg-1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello","annotations":[]}]}],"usage":{"input_tokens":10,"output_tokens":4,"output_tokens_details":{"reasoning_tokens":1}}}}"#),
        ])
        let provider = try localProvider(body: body)
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: localRequest()) {
            try accumulator.append(event)
        }
        let response = try accumulator.finish()
        #expect(response.content == [.text("Hello")])
        #expect(response.usage == .init(inputTokens: 10, outputTokens: 4, reasoningTokens: 1))
        #expect(!response.content.contains { if case .providerContinuation = $0 { true } else { false } })
    }

    @Test func semanticUnknownItemsAndServerErrorsFailClosed() async throws {
        let unknown = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"local-1","model":"fixture","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"unknown-1","type":"future_semantic_item"}}"#),
        ])
        do {
            for try await _ in try localProvider(body: unknown).stream(request: localRequest()) {}
            Issue.record("Semantic output items must not be ignored")
        } catch {
            #expect((error as? ModelProviderError)?.kind == .unsupportedCapability)
        }

        let failed = providerNamedSSE([
            ("error", #"{"type":"error","code":"server_error","message":"private backend detail"}"#),
        ])
        do {
            for try await _ in try localProvider(body: failed).stream(request: localRequest()) {}
            Issue.record("Server errors must fail")
        } catch {
            let failure = try #require(error as? ModelProviderError)
            #expect(failure.kind == .unavailable)
            #expect(!failure.message.contains("private"))
        }
    }

    @Test func undeclaredModelCapabilitiesFailBeforeNetworking() async throws {
        let probe = ProviderRequestProbe()
        let provider = try LocalResponsesProvider(
            configuration: .init(
                baseURL: URL(string: "http://localhost:1234/v1")!,
                model: "fixture"
            ),
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture])
        )
        let schema = ToolSchema.object(properties: [:]).json
        do {
            for try await _ in provider.stream(request: .init(
                model: provider.model,
                messages: [.user([.text("Hi")])],
                tools: [.init(name: "lookup", description: "Lookup", inputSchema: schema)]
            )) {}
            Issue.record("Undeclared tool support must fail")
        } catch {
            #expect((error as? ModelProviderError)?.kind == .unsupportedCapability)
        }
        #expect(await probe.requests.isEmpty)
    }

    @Test func authenticationIsOptionalButBearerTokensRequireATransportSafeEndpoint() async throws {
        let probe = ProviderRequestProbe()
        let provider = try LocalResponsesProvider(
            configuration: .init(
                baseURL: URL(string: "http://192.168.1.10:1234/v1")!,
                model: "fixture"
            ),
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture])
        )
        for try await _ in provider.stream(request: localRequest()) {}
        #expect(await probe.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)

        #expect(throws: ModelProviderError.self) {
            _ = try LocalResponsesProvider(configuration: .init(
                baseURL: URL(string: "http://192.168.1.10:1234/v1")!,
                model: "fixture",
                authentication: .bearer("secret")
            ))
        }

        _ = try LocalResponsesProvider(configuration: .init(
            baseURL: URL(string: "https://models.example.test/v1")!,
            model: "fixture",
            authentication: .bearer("secret")
        ))
    }

    @Test func cancellationTerminatesUnderlyingRequestAndDrains() async throws {
        let entered = XCTestExpectation(description: "entered")
        let cancelled = XCTestExpectation(description: "cancelled")
        let execution = ProviderExecutionProbe()
        let provider = try LocalResponsesProvider(
            configuration: .init(
                baseURL: URL(string: "http://localhost:1234/v1")!,
                model: "fixture",
                capabilities: [.tools]
            ),
            transport: PendingLocalHTTP(entered: entered, cancelled: cancelled)
        )
        let run = try await Agent(
            model: provider.model,
            provider: provider,
            tools: [ProviderCalculator(probe: execution)]
        ).makeSession().run("Compute")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed)
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await XCTWaiter.fulfillment(of: [cancelled], timeout: 2) == .completed)
        #expect(await execution.count == 0)
    }

    @Test func durableTextRestartRebuildsTheNextRequestFromCanonicalHistory() async throws {
        let state = try DurableLocalFixture()
        defer { state.cleanup() }
        let firstProbe = ProviderRequestProbe()
        let firstProvider = try localProvider(body: openAITextFixture, probe: firstProbe)
        let firstRun = try await Agent(model: firstProvider.model, provider: firstProvider)
            .makeSession(id: state.sessionID, journal: state.journal)
            .run("First")
        _ = try await firstRun.wait()
        try await firstRun.waitForDrain()

        let secondProbe = ProviderRequestProbe()
        let secondProvider = try localProvider(body: openAITextFixture, probe: secondProbe)
        let restored = try Agent(model: secondProvider.model, provider: secondProvider)
            .makeSession(id: state.sessionID, journal: try AgentJournal.load(from: state.url))
        _ = try await restored.run("Second").wait()

        let input = try requestInput(await secondProbe.requests.first)
        #expect(input == [
            .object(["type": .string("message"), "role": .string("user"), "content": .string("First")]),
            .object(["type": .string("message"), "role": .string("assistant"), "content": .string("Hello")]),
            .object(["type": .string("message"), "role": .string("user"), "content": .string("Second")]),
        ])
    }

    @Test func durableToolRestartReplaysCommittedCallAndResultWithoutReexecution() async throws {
        let state = try DurableLocalFixture()
        defer { state.cleanup() }
        let execution = ProviderExecutionProbe()
        let firstProvider = try LocalResponsesProvider(
            configuration: localConfiguration(capabilities: [.tools]),
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(),
                bodies: [openAIToolFixture, openAITextFixture]
            )
        )
        let agent = try Agent(
            model: firstProvider.model,
            provider: firstProvider,
            tools: [ProviderCalculator(probe: execution)]
        )
        let firstRun = try await agent.makeSession(id: state.sessionID, journal: state.journal).run("Compute")
        _ = try await firstRun.wait()
        try await firstRun.waitForDrain()
        #expect(await execution.count == 1)

        let secondProbe = ProviderRequestProbe()
        let secondProvider = try localProvider(body: openAITextFixture, probe: secondProbe, capabilities: [.tools])
        let restored = try Agent(
            model: secondProvider.model,
            provider: secondProvider,
            tools: [ProviderCalculator(probe: execution)]
        ).makeSession(id: state.sessionID, journal: try AgentJournal.load(from: state.url))
        _ = try await restored.run("Continue").wait()
        #expect(await execution.count == 1)

        let input = try requestInput(await secondProbe.requests.first)
        #expect(input.contains(.object([
            "type": .string("function_call"), "call_id": .string("call-1"),
            "name": .string("calculator"), "arguments": .string(#"{"a":2,"b":3}"#),
        ])))
        #expect(input.contains(.object([
            "type": .string("function_call_output"), "call_id": .string("call-1"),
            "output": .string(#"{"sum":5}"#),
        ])))
    }

    private func localProvider(
        body: Data,
        probe: ProviderRequestProbe = .init(),
        capabilities: ModelCapabilities = []
    ) throws -> LocalResponsesProvider {
        try LocalResponsesProvider(
            configuration: localConfiguration(capabilities: capabilities),
            transport: FixtureHTTPTransport(probe: probe, bodies: [body])
        )
    }

    private func localConfiguration(
        capabilities: ModelCapabilities = []
    ) -> LocalResponsesProvider.Configuration {
        .init(
            baseURL: URL(string: "http://localhost:1234/v1")!,
            model: "fixture",
            capabilities: capabilities
        )
    }

    private func localRequest() -> ModelRequest {
        .init(
            model: .init(provider: "local-responses", name: "fixture"),
            messages: [.user([.text("Hi")])]
        )
    }

    private func requestInput(_ request: URLRequest?) throws -> [JSONValue] {
        guard case .object(let body) = try JSONDecoder().decode(
            JSONValue.self,
            from: #require(request?.httpBody)
        ), case .array(let input) = body["input"] else {
            Issue.record("Missing request input")
            return []
        }
        #expect(body["previous_response_id"] == nil)
        return input
    }
}

private struct PendingLocalHTTP: ProviderHTTPTransport {
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

private struct DurableLocalFixture {
    let url: URL
    let sessionID = UUID()
    let journal: AgentJournal

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-local-responses-\(UUID().uuidString).log")
        journal = try AgentJournal(persistenceURL: url)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + ".lock")
    }
}
