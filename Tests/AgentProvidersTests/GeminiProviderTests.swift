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

struct GeminiProviderTests {
    @Test func signedParallelBatchAndEmptySignedTextReplayExactly() async throws {
        let probe = ProviderRequestProbe()
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }), preservedThinking: .requireCurrentTurnFunctionSignatures,
            transport: FixtureHTTPTransport(probe: probe, bodies: [try geminiFixture(parts: geminiParallelParts), geminiTextFixture], chunkBytes: 7))
        let first = try await geminiResponse(provider, geminiToolRequest)
        #expect(first.toolCalls.count == 2 && first.stopReason == .toolCalls)
        #expect(Set(first.toolCalls.map(\.id)).count == 2)
        let followup = ModelRequest(model: geminiToolRequest.model,
            messages: geminiToolRequest.messages + [.assistant(content: first.content, toolCalls: first.toolCalls)] + first.toolCalls.reversed().map {
                .tool(.init(callID: $0.id, content: [.json(.object(["answer": .number(5)]))], isError: false))
            }, tools: geminiToolRequest.tools)
        _ = try await geminiResponse(provider, followup)
        let body = try geminiHTTPBody(await probe.requests.last!)
        let contents = try #require(body["contents"].array)
        #expect(try ProviderJSON.encode(contents[1]["parts"]) == ProviderJSON.encode(JSONValue.array(geminiParallelParts)))
        let results = try #require(contents[2]["parts"].array)
        #expect(results.count == 2 && results[0]["functionResponse"]?["id"] == .string("vendor-id"))
        #expect(results[1]["functionResponse"]?["id"] == nil)
        #expect(Set(try ProviderJSON.object(results[0]).keys) == ["functionResponse"])
    }

    @Test func deferredExpansionAllowedButMissingOrChangedCurrentSignatureStateFailsLocally() async throws {
        let probe = ProviderRequestProbe()
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }), preservedThinking: .requireCurrentTurnFunctionSignatures,
            transport: FixtureHTTPTransport(probe: probe, bodies: [try geminiFixture(parts: geminiParallelParts), geminiTextFixture, geminiTextFixture]))
        let first = try await geminiResponse(provider, geminiToolRequest)
        let history = geminiToolRequest.messages + [.assistant(content: first.content, toolCalls: first.toolCalls)] + first.toolCalls.map {
            ModelMessage.tool(.init(callID: $0.id, content: [.text("done")], isError: false))
        }
        let expanded = geminiToolRequest.tools + [.init(name: "new.tool", description: "Deferred", inputSchema: .object(["type": .string("object")]))]
        _ = try await geminiResponse(provider, .init(model: geminiRequest.model, messages: history, tools: expanded))
        // Next ordinary Run restores initial declarations and preserves the prior signed history.
        _ = try await geminiResponse(provider, .init(model: geminiRequest.model, messages: history + [.user([.text("Next")])], tools: geminiToolRequest.tools))
        for content in [first.content.filter { if case .providerContinuation = $0 { return false }; return true }, [.text("changed")]] {
            let bad = ModelRequest(model: geminiRequest.model, messages: geminiRequest.messages + [.assistant(content: content, toolCalls: first.toolCalls)] + first.toolCalls.map {
                .tool(.init(callID: $0.id, content: [.text("done")], isError: false))
            }, tools: geminiToolRequest.tools)
            await #expect(throws: ModelProviderError.self) { _ = try await geminiResponse(provider, bad) }
        }
        #expect(await probe.requests.count == 3)
    }

    @Test func strictRejectsUnsignedFunctionStepWhileLegacyRetainsIt() async throws {
        let unsigned = geminiParallelParts.map { value -> JSONValue in
            var fields = try! ProviderJSON.object(value); fields.removeValue(forKey: "thoughtSignature"); return .object(fields)
        }
        let probe = ProviderRequestProbe()
        let strict = try GeminiProvider(credentials: .init(apiKey: { "key" }), preservedThinking: .requireCurrentTurnFunctionSignatures,
            transport: FixtureHTTPTransport(probe: probe, bodies: [try geminiFixture(parts: unsigned)]))
        await #expect(throws: ModelProviderError.self) { _ = try await geminiResponse(strict, geminiToolRequest) }
        let legacy = try GeminiProvider(credentials: .init(apiKey: { "key" }), transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [try geminiFixture(parts: unsigned)]))
        #expect(try await geminiResponse(legacy, geminiToolRequest).toolCalls.count == 2)
    }

    @Test func canonicalUnicodeTamperingIsNotAcceptedAsExactNativeReplay() async throws {
        let probe = ProviderRequestProbe(), provider = try GeminiProvider(credentials: .init(apiKey: { "key" }),
            transport: FixtureHTTPTransport(probe: probe, bodies: [try geminiFixture(parts: [.object(["text": .string("é"), "thoughtSignature": .string("c2ln")])])]))
        let response = try await geminiResponse(provider, geminiRequest)
        let changed = response.content.map { part -> ModelContent in if case .text = part { return .text("e\u{301}") }; return part }
        #expect(throws: ModelProviderError.self) { try provider.validate(request: .init(model: geminiRequest.model,
            messages: geminiRequest.messages + [.assistant(content: changed, toolCalls: []), .user([.text("Next")])])) }
        #expect(await probe.requests.count == 1)
    }

    @Test func nativeFilesImagesSystemToolsAndStructuredOutputUseActualBody() async throws {
        let image = try ModelImage(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!, description: "pixel")
        let file = try ModelFileReference(uri: URL(string: "https://files.example/immutable.pdf")!, mediaType: .pdf, description: "PDF", estimatedInputTokens: 100)
        let request = ModelRequest(model: geminiRequest.model, messages: [.system("Keep"), .developer("Order"), .user([.text("Read"), .image(image), .file(file)])], tools: geminiToolRequest.tools,
            structuredOutput: .init(name: "answer", schema: .object(["type": .string("object")])) )
        let probe = ProviderRequestProbe()
        let provider = try GeminiProvider(credentials: .init(bearerToken: { "token" }), thinking: .init(level: .low, includeThoughts: true), maximumOutputTokens: 200,
            transport: FixtureHTTPTransport(probe: probe, bodies: [geminiTextFixture]))
        _ = try await geminiResponse(provider, request)
        let http = try #require(await probe.requests.first), body = try geminiHTTPBody(http)
        #expect(http.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(body["cachedContent"] == nil)
        #expect(body["systemInstruction"]?["parts"].array?.count == 2)
        let parts = try #require(body["contents"].array?.first?["parts"].array)
        #expect(parts[1]["inlineData"]?["data"] == .string(image.data.base64EncodedString()))
        #expect(parts[2]["fileData"]?["fileUri"] == .string(file.uri.absoluteString))
        #expect(body["generationConfig"]?["thinkingConfig"]?["thinkingLevel"] == .string("LOW"))
        #expect(body["generationConfig"]?["responseFormat"]?["text"]?["mimeType"] == .string("APPLICATION_JSON"))
    }

    @Test func finalBodyBoundaryAcceptsExactBytesAndRejectsOneByteBelowWithoutCredentialsOrHTTP() async throws {
        let probe = ProviderRequestProbe(), tokens = PlanRotatingTokens()
        let image = try ModelImage(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!, description: "pixel")
        let request = ModelRequest(model: geminiRequest.model, messages: [.system("escape\n\""), .user([.text(String(repeating: "bounded\n", count: 500)), .image(image)])], tools: geminiToolRequest.tools)
        let config = try geminiConfiguration()
        let bytes = try GeminiRequestEncoder.encode(request, configuration: config)
        for limit in [bytes.count, bytes.count - 1] {
            let provider = try GeminiProvider(credentials: .init(apiKey: { await tokens.next() }), maximumRequestBytes: limit,
                transport: FixtureHTTPTransport(probe: probe, bodies: [geminiTextFixture]))
            if limit == bytes.count { _ = try await geminiResponse(provider, request) }
            else { await #expect(throws: ModelProviderError.self) { _ = try await geminiResponse(provider, request) } }
        }
        #expect(await probe.requests.count == 1)
        #expect(await tokens.count == 1)
        #expect(await probe.requests.first?.httpBody == bytes)
    }

    @Test func nonstreamAndSparseUsageAreNormalizedWithoutDoubleCounting() async throws {
        let usage: JSONValue = .object(["promptTokenCount": .number(100), "cachedContentTokenCount": .number(70), "candidatesTokenCount": .number(4), "thoughtsTokenCount": .number(6)])
        let fixture = try geminiFixture(parts: [.object(["text": .string("Hello")])], usage: usage, streaming: false)
        let probe = ProviderRequestProbe(), provider = try GeminiProvider(credentials: .init(apiKey: { "key" }), streaming: false,
            transport: FixtureHTTPTransport(probe: probe, bodies: [fixture], chunkBytes: 3))
        let response = try await geminiResponse(provider, geminiRequest)
        #expect(response.usage == .init(inputTokens: 100, outputTokens: 10, cachedInputTokens: 70, reasoningTokens: 6))
        #expect(await probe.requests.first?.url?.lastPathComponent == "fixture:generateContent")
        var decoder = GeminiResponseDecoder(request: geminiRequest, configuration: try geminiConfiguration())
        try decoder.consume(["usageMetadata": .object(["promptTokenCount": .number(100), "candidatesTokenCount": .number(4)])])
        try decoder.consume(["usageMetadata": .object(["cachedContentTokenCount": .number(70), "thoughtsTokenCount": .number(6)]),
            "candidates": .array([.object(["content": .object(["role": .string("model"), "parts": .array([.object(["text": .string("ok")])])]), "finishReason": .string("STOP")])])])
        var accumulator = ModelEventAccumulator(); for event in try decoder.finish() { try accumulator.append(event) }
        #expect(try accumulator.finish().usage.outputTokens == 10)
    }

    @Test(arguments: ["MAX_TOKENS", "SAFETY", "MALFORMED_FUNCTION_CALL", "unfinished"])
    func blockedTruncatedMalformedAndEOFNeverAuthorizeTools(reason: String) async throws {
        let probe = ProviderRequestProbe(), provider = try GeminiProvider(credentials: .init(apiKey: { "key" }),
            transport: FixtureHTTPTransport(probe: probe, bodies: [try geminiFixture(parts: geminiParallelParts, reason: reason == "unfinished" ? nil : reason)]))
        var calls = 0
        do { for try await event in provider.stream(request: geminiToolRequest) { if case .toolCallCompleted = event { calls += 1 } } }
        catch let error as ModelProviderError { #expect(["MALFORMED_FUNCTION_CALL", "unfinished"].contains(reason) && error.kind == .invalidResponse) }
        #expect(calls == 0)
    }

    @Test func blockedPromptWithCandidateCannotAuthorizeCallsAndResponseAccumulationIsBounded() async throws {
        var object = try ProviderJSON.decode(String(decoding: try geminiFixture(parts: geminiParallelParts, streaming: false), as: UTF8.self))
        object["promptFeedback"] = .object(["blockReason": .string("SAFETY")])
        let blocked = Data("data: ".utf8) + (try ProviderJSON.encode(JSONValue.object(object))) + Data("\n\n".utf8)
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }), transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [blocked]))
        let response = try await geminiResponse(provider, geminiToolRequest)
        #expect(response.stopReason == .refusal && response.toolCalls.isEmpty)
        let bounded = try GeminiProvider(credentials: .init(apiKey: { "key" }), maximumResponseBytes: geminiTextFixture.count - 1,
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [geminiTextFixture], chunkBytes: 3))
        await #expect(throws: ModelProviderError.self) { _ = try await geminiResponse(bounded, geminiRequest) }
    }

    @Test func unsupportedRequestsAndMalformedConfigurationNeverAcquireCredentials() async throws {
        let probe = ProviderRequestProbe(), tokens = PlanRotatingTokens()
        let provider = try GeminiProvider(credentials: .init(apiKey: { await tokens.next() }), transport: FixtureHTTPTransport(probe: probe, bodies: [geminiTextFixture]))
        let foreign = ModelProviderContinuation(model: geminiRequest.model, format: "other", payload: Data("{}".utf8))
        for request in [ModelRequest(model: .init(provider: "gemini", name: "../escape"), messages: geminiRequest.messages),
                        .init(model: geminiRequest.model, messages: [.assistant(content: [.providerContinuation(foreign)], toolCalls: []), .user([.text("Hi")])])] {
            await #expect(throws: ModelProviderError.self) { _ = try await geminiResponse(provider, request) }
        }
        for url in ["http://remote.example/v1beta", "https://key:secret@host/v1beta", "https://host/v1beta?key=secret", "https://host/%2Fescape"] {
            #expect(throws: ModelProviderError.self) { try GeminiProvider(credentials: .init(apiKey: { "key" }), baseURL: URL(string: url)!) }
        }
        #expect(throws: ModelProviderError.self) { try GeminiThinkingConfiguration(level: .low, budget: 1) }
        #expect(await tokens.count == 0)
        #expect(await probe.requests.isEmpty)
    }

    @Test(arguments: [401, 403, 404, 429, 503]) func failuresSanitized(status: Int) async throws {
        let probe = ProviderRequestProbe(), provider = try GeminiProvider(credentials: .init(apiKey: { "fixture-secret" }),
            transport: FixtureHTTPTransport(probe: probe, bodies: [Data("fixture-secret".utf8)], status: status, headers: ["Retry-After": "7"]))
        do { _ = try await geminiResponse(provider, geminiRequest); Issue.record("Expected HTTP failure") }
        catch let error as ModelProviderError {
            #expect(error.kind == ProviderHTTPFailure.classify(status, headers: [:]).kind)
            #expect(error.retryAfter == .seconds(7))
            #expect(!String(reflecting: error).contains("fixture-secret"))
        }
        #expect(!String(reflecting: provider).contains("fixture-secret"))
        #expect(Mirror(reflecting: GeminiCredentials(apiKey: { "secret" })).children.isEmpty)
    }

    @Test(arguments: [false, true]) func lateCredentialPhysicalDrainPreventsDispatch(deadline: Bool) async throws {
        let started = XCTestExpectation(description: "Gemini credentials entered"), probe = ProviderRequestProbe()
        let gate = PlanCredentialGate(started: started)
        let provider = try GeminiProvider(credentials: .init(apiKey: { await gate.token() }), transport: FixtureHTTPTransport(probe: probe, bodies: [geminiTextFixture]))
        let session = try Agent(model: geminiRequest.model, provider: provider).makeSession()
        let run = try await session.run("Hi", budget: .init(maxModelTurns: 2, maxToolCalls: 1, deadline: .now.advanced(by: .seconds(deadline ? 1 : 10))))
        #expect(await XCTWaiter.fulfillment(of: [started], timeout: 2) == .completed)
        if deadline { await #expect(throws: AgentLoopError.deadlineExceeded) { try await run.wait() } }
        else { await run.cancel(); await #expect(throws: CancellationError.self) { try await run.wait() } }
        let premature = XCTestExpectation(description: "premature drain"); premature.isInverted = true
        let drain = Task { try await run.waitForDrain(); premature.fulfill() }
        #expect(await XCTWaiter.fulfillment(of: [premature], timeout: 0.1) == .completed)
        await gate.release(); try await drain.value
        #expect(await gate.finished)
        #expect(await probe.requests.isEmpty)
    }
}

let geminiToolRequest = ModelRequest(model: geminiRequest.model, messages: geminiRequest.messages,
    tools: [.init(name: "calculator", description: "Add", inputSchema: .object(["type": .string("object")]))])
let geminiParallelParts: [JSONValue] = [
    .object(["text": .string("consider"), "thought": .bool(true), "thoughtSignature": .string("dGhvdWdodA==")]),
    .object(["functionCall": .object(["name": .string("calculator"), "args": .object(["a": .number(2), "b": .number(3)]), "id": .string("vendor-id")]), "thoughtSignature": .string("ZnVuY3Rpb24=")]),
    .object(["functionCall": .object(["name": .string("calculator"), "args": .object(["a": .number(3), "b": .number(2)])])]),
    .object(["text": .string(""), "thoughtSignature": .string("ZW1wdHk=")]),
]
func geminiFixture(parts: [JSONValue], reason: String? = "STOP", usage: JSONValue? = nil, streaming: Bool = true) throws -> Data {
    var candidate: [String: JSONValue] = ["index": .number(0), "content": .object(["role": .string("model"), "parts": .array(parts)])]
    if let reason { candidate["finishReason"] = .string(reason) }
    var root: [String: JSONValue] = ["responseId": .string("r"), "candidates": .array([.object(candidate)])]
    if let usage { root["usageMetadata"] = usage }
    let data = try ProviderJSON.encode(JSONValue.object(root))
    return streaming ? Data("data: ".utf8) + data + Data("\n\n".utf8) : data
}
func geminiResponse(_ provider: GeminiProvider, _ request: ModelRequest) async throws -> ModelResponse {
    var accumulator = ModelEventAccumulator(); for try await event in provider.stream(request: request) { try accumulator.append(event) }; return try accumulator.finish()
}
func geminiHTTPBody(_ request: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)) }
func geminiConfiguration() throws -> GeminiConfiguration { try .init(baseURL: GeminiProvider.defaultBaseURL, streaming: true, thinking: nil, profile: .preserve, maximumOutputTokens: nil, maximumRequestBytes: 100_000_000, maximumResponseBytes: 16_000_000, authorizationScopeID: "default", caching: .implicit) }
private extension Optional where Wrapped == JSONValue { var array: [JSONValue]? { if case .array(let values) = self { return values }; return nil } }
