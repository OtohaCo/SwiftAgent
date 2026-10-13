import AgentCatalog
import AgentCore
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XCTest
@testable import AgentProviders

struct ChatGPTPlanProviderTests {
    @Test func imageAndStructuredOutputUseOnlySupportedFields() async throws {
        let image = try ModelImage(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!, description: "pixel")
        let request = ModelRequest(model: planRequest.model,
            messages: [.system("First"), .developer("Second"), .user([.text("See"), .image(image)])], tools: planRequest.tools,
            structuredOutput: .init(name: "answer", schema: .object(["type": .string("object")]), strict: true))
        let probe = ProviderRequestProbe()
        let provider = OpenAIChatGPTPlanProvider(credentials: .init(accessToken: { "fixture-token" }),
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
        for try await _ in provider.stream(request: request) {}
        let body = try ProviderJSON.object(JSONDecoder().decode(JSONValue.self, from: #require(await probe.requests[0].httpBody)))
        #expect(Set(body.keys) == Set(["model", "input", "tools", "text", "store", "stream"]))
        guard case .array(let input) = body["input"], case .array(let parts) = input[2]["content"] else { Issue.record("Missing image input"); return }
        #expect(input[0]["role"] == .string("developer") && input[1]["role"] == .string("developer"))
        #expect(parts[0]["type"] == .string("input_text") && parts[1]["type"] == .string("input_image"))
        #expect(parts[1]["image_url"] == .string("data:image/png;base64," + image.data.base64EncodedString()))
        #expect(body["text"]?["format"]?["type"] == .string("json_schema"))
    }

    @Test func credentialsAreReadOncePerDispatchAndNeverDuringPreflight() async throws {
        let tokens = PlanRotatingTokens(), probe = ProviderRequestProbe()
        let provider = OpenAIChatGPTPlanProvider(credentials: .init(accessToken: { await tokens.next() }),
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture, openAITextFixture]))
        try provider.validate(request: planRequest)
        #expect(await tokens.count == 0)
        for _ in 0..<2 { for try await _ in provider.stream(request: planRequest) {} }
        #expect(await tokens.count == 2)
        #expect(await probe.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer fixture-1", "Bearer fixture-2"])
        #expect(await probe.requests.allSatisfy { $0.url?.absoluteString == "https://api.openai.com/v1/responses" })
    }

    @Test func toolContinuationRetainsNamespaceIDsAndCanonicalName() async throws {
        let probe = ProviderRequestProbe()
        let provider = OpenAIChatGPTPlanProvider(credentials: .init(accessToken: { "fixture-token" }),
            transport: FixtureHTTPTransport(probe: probe, bodies: [try planToolFixture(), openAITextFixture], chunkBytes: 17))
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: planRequest) { try accumulator.append(event) }
        let response = try accumulator.finish()
        #expect(response.toolCalls.map(\.name) == ["calculator"])
        let state = try #require(response.content.compactMap { part -> ModelProviderContinuation? in
            if case .providerContinuation(let state) = part { return state }; return nil
        }.first)
        #expect(state.format == ChatGPTPlanRequestEncoder.continuationFormat)
        let followup = ModelRequest(model: planRequest.model,
            messages: planRequest.messages + [.assistant(content: response.content, toolCalls: response.toolCalls),
                .tool(.init(callID: .init(rawValue: "call-1"), content: [.text("5")], isError: false))], tools: planRequest.tools)
        for try await _ in provider.stream(request: followup) {}
        let body = try ProviderJSON.object(JSONDecoder().decode(JSONValue.self, from: #require(await probe.requests.last?.httpBody)))
        let input = try #require(body["input"].flatMap { if case .array(let array) = $0 { return array }; return nil })
        let call = try #require(input.first { $0["type"] == .string("function_call") })
        #expect(call["namespace"] == .string("swiftagent"))
        #expect(call["name"] == .string("calculator"))
        #expect(call["id"] == .string("fc-1"))
        #expect(call["call_id"] == .string("call-1"))
        #expect(input.contains { $0["type"] == .string("function_call_output") && $0["output"] == .string("5") })
        let ordinaryProbe = ProviderRequestProbe()
        let ordinary = try OpenAIResponsesProvider(apiKey: "ordinary-fixture",
            transport: FixtureHTTPTransport(probe: ordinaryProbe, bodies: [openAITextFixture]))
        await #expect(throws: ModelProviderError.self) { for try await _ in ordinary.stream(request: followup) {} }
        #expect(await ordinaryProbe.requests.isEmpty)
    }

    @Test func namespaceAndNameTamperingCannotBecomeCallableResults() async throws {
        for phase in ["response.output_item.added", "response.output_item.done", "response.completed"] {
            for namespace in [JSONValue.string("other"), .null] {
                let probe = ProviderRequestProbe()
                let provider = OpenAIChatGPTPlanProvider(credentials: .init(accessToken: { "fixture-token" }),
                    transport: FixtureHTTPTransport(probe: probe, bodies: [try planToolFixture(mutationPhase: phase, namespace: namespace)]))
                var completed = false
                do {
                    for try await event in provider.stream(request: planRequest) { if case .responseCompleted = event { completed = true } }
                    Issue.record("Tampered namespace must fail")
                } catch let error as ModelProviderError { #expect(error.kind == .unsupportedCapability) }
                #expect(!completed)
                #expect(await probe.requests.count == 1)
            }
        }
        let provider = OpenAIChatGPTPlanProvider(credentials: .init(accessToken: { "fixture-token" }),
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [try planToolFixture(callName: "swiftagent.calculator")]))
        await #expect(throws: ModelProviderError.self) { for try await _ in provider.stream(request: planRequest) {} }
    }

    @Test func toolLoopExecutesOnceAndRestoresAllInputHistory() async throws {
        let probe = ProviderRequestProbe(), execution = ProviderExecutionProbe()
        let provider = OpenAIChatGPTPlanProvider(credentials: .init(accessToken: { "fixture-token" }),
            transport: FixtureHTTPTransport(probe: probe, bodies: [try planToolFixture(), openAITextFixture]))
        let run = try await Agent(model: planRequest.model, provider: provider,
            tools: [ProviderCalculator(probe: execution)], configuration: .init(instructions: "Keep constraint")).makeSession().run("Add")
        #expect(try await run.wait().outcome == .completed)
        try await run.waitForDrain()
        #expect(await execution.count == 1)
        #expect(await probe.requests.count == 2)
    }

    @Test func failuresAfterTextNeverProduceCompletedOrExposeVendorText() async throws {
        var decoder = try ProviderSSEDecoder()
        let frames = try decoder.consume(openAITextFixture).filter { $0.name != "response.completed" }
        for (code, kind, reason) in [
            ("subscription_sharing_usage_limit_exceeded", ModelProviderError.Kind.rateLimited, ModelProviderError.Diagnostic.Reason.subscriptionSharingUsageLimitExceeded),
            ("subscription_sharing_usage_unavailable", .unavailable, .subscriptionSharingUsageUnavailable),
            ("unknown-fixture-secret", .invalidResponse, .serverFailure),
        ] {
            let fixture = providerNamedSSE(frames.map { ($0.name!, $0.data) } + [("response.failed",
                "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"\(code)\",\"message\":\"fixture-secret\"}}}")])
            let provider = OpenAIChatGPTPlanProvider(credentials: .init(accessToken: { "fixture-secret" }),
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [fixture]))
            var textSeen = false, completed = false
            do {
                for try await event in provider.stream(request: planRequest) {
                    if case .textDelta = event { textSeen = true }
                    if case .responseCompleted = event { completed = true }
                }
                Issue.record("Failed response cannot succeed")
            } catch let error as ModelProviderError {
                #expect(error.kind == kind)
                #expect(error.diagnostic?.reason == reason)
                #expect(!String(reflecting: error).contains("fixture-secret"))
            }
            #expect(textSeen && !completed)
        }
    }

    @Test func incompleteAndEOFWithoutCompletedAreFailures() async throws {
        let created = ("response.created", #"{"type":"response.created","response":{"id":"r","model":"fixture","status":"in_progress"}}"#)
        for frames in [[created], [created, ("response.incomplete", #"{"type":"response.incomplete","response":{"id":"r","model":"fixture","status":"incomplete","output":[],"incomplete_details":{"reason":"max_output_tokens"}}}"#)]] {
            let provider = OpenAIChatGPTPlanProvider(credentials: .init(accessToken: { "fixture-token" }),
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [providerNamedSSE(frames)]))
            var completed = false
            do { for try await event in provider.stream(request: planRequest) { if case .responseCompleted = event { completed = true } }; Issue.record("Missing completed must fail") }
            catch let error as ModelProviderError { #expect(error.kind == .invalidResponse) }
            #expect(!completed)
        }
    }

    @Test func encryptedAndCompactionOutputAreUnsupported() async throws {
        for item in [#"{"id":"rs","type":"reasoning","summary":[],"encrypted_content":"opaque"}"#,
                     #"{"id":"cp","type":"compaction","encrypted_content":"opaque"}"#] {
            let body = providerNamedSSE([
                ("response.created", #"{"type":"response.created","response":{"id":"r","model":"fixture","status":"in_progress"}}"#),
                ("response.output_item.added", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":\(item)}"),
            ])
            let provider = OpenAIChatGPTPlanProvider(credentials: .init(accessToken: { "fixture-token" }),
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body]))
            do { for try await _ in provider.stream(request: planRequest) {}; Issue.record("Unsupported native output must fail") }
            catch let error as ModelProviderError { #expect(error.kind == .unsupportedCapability) }
        }
    }

    @Test func foreignOpaqueHistoryRejectsBeforeTokenOrTransport() async throws {
        let tokens = PlanRotatingTokens(), probe = ProviderRequestProbe()
        let provider = OpenAIChatGPTPlanProvider(credentials: .init(accessToken: { await tokens.next() }),
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
        let foreign = ModelProviderContinuation(model: planRequest.model, format: OpenAIResponsesContinuation.format, payload: Data("{}".utf8))
        let request = ModelRequest(model: planRequest.model, messages: [.assistant(content: [.providerContinuation(foreign)], toolCalls: []), .user([.text("Next")])])
        await #expect(throws: ModelProviderError.self) { for try await _ in provider.stream(request: request) {} }
        #expect(await tokens.count == 0)
        #expect(await probe.requests.isEmpty)
    }

    @Test func HTTPPlanCodesAndStatusFallbackAreBoundedAndSanitized() async throws {
        let fixtures: [(Int, String, ModelProviderError.Kind)] = [
            (429, #"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"fixture-secret"}}"#, .rateLimited),
            (503, #"{"error":{"code":"subscription_sharing_usage_unavailable","message":"fixture-secret"}}"#, .unavailable),
            (401, #"{"detail":"fixture-secret"}"#, .authentication),
            (403, #"{"detail":"fixture-secret"}"#, .permissionDenied),
            (401, String(repeating: "x", count: 65_537), .authentication),
        ]
        for (status, body, kind) in fixtures {
            let provider = OpenAIChatGPTPlanProvider(credentials: .init(accessToken: { "fixture-secret" }),
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(body.utf8)], chunkBytes: 1024,
                    status: status, headers: ["retry-after": "7"]))
            do { for try await _ in provider.stream(request: planRequest) {}; Issue.record("HTTP failure must throw") }
            catch let error as ModelProviderError {
                #expect(error.kind == kind && error.retryAfter == .seconds(7))
                #expect(!String(reflecting: error).contains("fixture-secret"))
            }
        }
    }

    @Test func credentialsFailuresAndReflectionAreRedacted() async throws {
        struct SecretFailure: Error { let secret = "fixture-secret" }
        for credentials in [OpenAIChatGPTPlanCredentials(accessToken: { throw SecretFailure() }), .init(accessToken: { "bad\r\ntoken" })] {
            let probe = ProviderRequestProbe()
            let provider = OpenAIChatGPTPlanProvider(credentials: credentials,
                transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
            #expect(!String(reflecting: credentials).contains("fixture-secret"))
            #expect(!String(reflecting: provider).contains("fixture-secret"))
            #expect(Mirror(reflecting: credentials).children.isEmpty)
            do { for try await _ in provider.stream(request: planRequest) {}; Issue.record("Bad credential source must fail") }
            catch let error as ModelProviderError { #expect(error.kind == .authentication); #expect(!String(reflecting: error).contains("fixture-secret")) }
            #expect(await probe.requests.isEmpty)
        }
    }

    @Test func physicalDrainWaitsForLateCredentialSourceAndPreventsDispatch() async throws {
        let started = XCTestExpectation(description: "credential source entered")
        let gate = PlanCredentialGate(started: started), probe = ProviderRequestProbe()
        let provider = OpenAIChatGPTPlanProvider(credentials: .init(accessToken: { await gate.token() }),
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
        let run = try await Agent(model: planRequest.model, provider: provider).makeSession().run("Hi")
        #expect(await XCTWaiter.fulfillment(of: [started], timeout: 2) == .completed)
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        let premature = XCTestExpectation(description: "physical drain before source returned")
        premature.isInverted = true
        let drain = Task { try await run.waitForDrain(); premature.fulfill() }
        #expect(await XCTWaiter.fulfillment(of: [premature], timeout: 0.1) == .completed)
        await gate.release()
        try await drain.value
        #expect(await gate.finished)
        #expect(await probe.requests.isEmpty)
    }
}

let planRequest = ModelRequest(model: .init(provider: "openai", name: "fixture"), messages: [.user([.text("Hi")])],
    tools: [.init(name: "calculator", description: "Add", inputSchema: .object(["type": .string("object")]))])

func planToolFixture(mutationPhase: String? = nil, namespace: JSONValue = .string("swiftagent"), callName: String = "calculator") throws -> Data {
    var sse = try ProviderSSEDecoder()
    let frames = try sse.consume(openAIToolFixture)
    return try providerNamedSSE(frames.map { frame in
        var object = try ProviderJSON.decode(frame.data)
        func qualify(_ item: JSONValue) throws -> JSONValue {
            var fields = try ProviderJSON.object(item)
            if fields["type"] == .string("function_call") {
                fields["namespace"] = mutationPhase == nil || mutationPhase == frame.name ? namespace : .string("swiftagent")
                fields["name"] = .string(callName)
            }
            return .object(fields)
        }
        if let item = object["item"] { object["item"] = try qualify(item) }
        if case .object(var response) = object["response"], case .array(let output) = response["output"] {
            response["output"] = .array(try output.map(qualify)); object["response"] = .object(response)
        }
        return (frame.name!, try ProviderJSON.text(JSONValue.object(object)))
    })
}

actor PlanRotatingTokens {
    private(set) var count = 0
    func next() -> String { count += 1; return "fixture-\(count)" }
}
actor PlanCredentialGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var finished = false
    init(started: XCTestExpectation) { self.started = started }
    func token() async -> String {
        let value = await withCheckedContinuation { continuation = $0; started.fulfill() }
        finished = true
        return value
    }
    func release() { continuation?.resume(returning: "late-fixture-token"); continuation = nil }
}
