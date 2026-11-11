import AgentModels
import Foundation
import Testing
@testable import AgentProviders

struct GeminiForeignHistoryTests {
    private let model = ModelID(provider: "gemini", name: "fixture")
    private let call = ToolCall(id: .init(rawValue: "foreign-call-1"), name: "lookup", argumentsJSON: "{}", completeness: .complete)
    // REST qualification on 2026-11-11: both literal and base64 bypass values returned HTTP 200
    // and consumed a synthetic function result; the no-call control also returned 200.
    // Keep Google's documented literal. This qualifies one endpoint, not every deployment.
    private let dummy = "skip_thought_signature_validator"

    private func configuration(_ profile: GeminiPreservedThinkingProfile = .requireCurrentTurnFunctionSignatures) throws -> GeminiConfiguration {
        try .init(baseURL: GeminiProvider.defaultBaseURL, streaming: false, thinking: nil, profile: profile,
            maximumOutputTokens: nil, maximumRequestBytes: 100_000_000, maximumResponseBytes: 16_000_000,
            authorizationScopeID: "default", caching: .implicit)
    }
    private func history(_ content: [ModelContent], calls: [ToolCall]? = nil, older: Bool = false) -> ModelRequest {
        let calls = calls ?? [call]
        return .init(model: model, messages: [.user([.text("Look up the token")]), .assistant(content: content, toolCalls: calls)]
            + calls.map { .tool(.init(callID: $0.id, content: [.json(.object(["token": .string("CEDAR")]))], isError: false)) }
            + (older ? [.user([.text("Next question")])] : []))
    }
    private func parts(_ request: ModelRequest, profile: GeminiPreservedThinkingProfile = .requireCurrentTurnFunctionSignatures) throws -> [JSONValue] {
        let body = try JSONDecoder().decode(JSONValue.self, from: GeminiRequestEncoder.encode(request, configuration: configuration(profile)))
        guard case .array(let contents) = body["contents"], case .array(let parts) = contents[1]["parts"] else {
            Issue.record("Missing model parts"); return []
        }
        return parts
    }
    private func native(_ parts: [JSONValue], model: ModelID? = nil, endpoint: String? = nil) throws -> ModelContent {
        .providerContinuation(.init(model: model ?? self.model, format: GeminiNativeState.format,
            payload: try ProviderJSON.encode(GeminiNativeState(endpoint: endpoint ?? GeminiProvider.defaultBaseURL.absoluteString,
                parts: parts, calls: [.init(canonicalID: call.id.rawValue, partIndex: 0)]))))
    }

    @Test(arguments: [GeminiPreservedThinkingProfile.preserve, .requireCurrentTurnFunctionSignatures])
    func foreignHistoryKeepsVisibleContentAndCallResponseIDs(_ profile: GeminiPreservedThinkingProfile) throws {
        let continuation = ModelProviderContinuation(model: .init(provider: "openai", name: "foreign"),
            format: "openai-responses-v1", payload: Data("private foreign continuation".utf8))
        let request = history([.text("Visible"), .reasoning("private foreign reasoning"), .json(.object(["shown": .bool(true)])), .providerContinuation(continuation)])
        let body = try JSONDecoder().decode(JSONValue.self, from: GeminiRequestEncoder.encode(request, configuration: configuration(profile)))
        guard case .array(let contents) = body["contents"], case .array(let parts) = contents[1]["parts"] else {
            Issue.record("Missing model contents"); return
        }
        #expect(parts[0] == .object(["text": .string("Visible")]))
        #expect(parts[1]["text"] == .string("{\"shown\":true}"))
        #expect(parts[2]["functionCall"]?["id"] == .string(call.id.rawValue))
        #expect(parts[2]["thoughtSignature"] == .string(dummy))
        #expect(parts[2]["thoughtSignature"] != .string(Data(dummy.utf8).base64EncodedString()))
        #expect(contents[2]["parts"]?[0]?["functionResponse"]?["id"] == .string(call.id.rawValue))
        let encoded = try ProviderJSON.text(body)
        #expect(!encoded.contains("private foreign") && !encoded.contains("openai-responses"))
    }

    @Test func earlierForeignCallsNeedNoDummySignature() throws {
        let result = try parts(history([.reasoning("discard")], older: true))
        #expect(result.count == 1 && result[0]["thoughtSignature"] == nil)
    }

    @Test func onlyTheFirstCallInEachForeignStepGetsADummy() throws {
        let second = ToolCall(id: .init(rawValue: "second"), name: "lookup", argumentsJSON: "{}", completeness: .complete)
        var messages = history([], calls: [call, second]).messages
        let third = ToolCall(id: .init(rawValue: "third"), name: "lookup", argumentsJSON: "{}", completeness: .complete)
        messages += [.assistant(content: [], toolCalls: [third]), .tool(.init(callID: third.id, content: [.text("done")], isError: false))]
        let body = try JSONDecoder().decode(JSONValue.self, from: GeminiRequestEncoder.encode(.init(model: model, messages: messages), configuration: configuration()))
        #expect(body["contents"]?[1]?["parts"]?[0]?["thoughtSignature"] == .string(dummy))
        #expect(body["contents"]?[1]?["parts"]?[1]?["thoughtSignature"] == nil)
        #expect(body["contents"]?[3]?["parts"]?[0]?["thoughtSignature"] == .string(dummy))
    }

    @Test(arguments: ["model", "endpoint"])
    func geminiStateFromAnotherScopeIsForeign(_ mismatch: String) throws {
        let state = try native([.object(["functionCall": .object(["name": .string(call.name), "args": .object([:])]), "thoughtSignature": .string("cHJpdmF0ZQ==")])],
            model: mismatch == "model" ? .init(provider: "gemini", name: "other") : nil,
            endpoint: mismatch == "endpoint" ? "https://another.example/v1beta" : nil)
        let replay = try parts(history([.reasoning("foreign thought"), state]))
        #expect(replay.count == 1 && replay[0]["thoughtSignature"] == .string(dummy))
        #expect(replay[0]["functionCall"]?["id"] == .string(call.id.rawValue))
    }

    @Test func mixedNativeAndForeignHistoryPreservesNativePartsExactly() throws {
        let signed: JSONValue = .object(["functionCall": .object(["name": .string(call.name), "args": .object([:]), "id": .string("native-id")]), "thoughtSignature": .string("cmVhbA==")])
        var request = history([try native([signed])])
        let other = ToolCall(id: .init(rawValue: "foreign-next"), name: "lookup", argumentsJSON: "{}", completeness: .complete)
        request = .init(model: model, messages: request.messages + [.assistant(content: [.reasoning("discard")], toolCalls: [other]), .tool(.init(callID: other.id, content: [.text("done")], isError: false))])
        #expect(try parts(request) == [signed])
        let body = try JSONDecoder().decode(JSONValue.self, from: GeminiRequestEncoder.encode(request, configuration: configuration()))
        #expect(body["contents"]?[3]?["parts"]?[0]?["thoughtSignature"] == .string(dummy))
    }

    @Test func nativeUnsignedCurrentTurnIsStillRejectedByTheStrictProfile() throws {
        let unsigned: JSONValue = .object(["functionCall": .object(["name": .string(call.name), "args": .object([:])])])
        let request = history([try native([unsigned])])
        #expect(throws: ModelProviderError.self) { _ = try parts(request) }
        #expect(try parts(request, profile: .preserve) == [unsigned])
    }

    @Test func foreignCachePrefixCannotMatchNativePartsWithTheSameWireContent() async throws {
        let prefix = history([], older: true)
        let config = try configuration()
        let client = try GeminiCachedContentClient(credentials: .init(apiKey: { "fixture" }), authorizationScopeID: "default",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [geminiCacheFixture]))
        let binding = try await client.create(prefix: prefix)
        let request = ModelRequest(model: model, messages: prefix.messages + [.user([.text("Follow up")])])
        try binding.validate(request: request, context: GeminiRequestEncoder.context(request, configuration: config), configuration: config, now: Date())
        let plain: JSONValue = .object(["functionCall": .object(["name": .string(call.name), "args": .object([:]), "id": .string(call.id.rawValue)])])
        let nativePrefix = history([try native([plain])], older: true)
        let nativeRequest = ModelRequest(model: model, messages: nativePrefix.messages + [.user([.text("Follow up")])])
        let nativeContext = try GeminiRequestEncoder.context(nativeRequest, configuration: config)
        #expect(nativeContext.contents == (try GeminiRequestEncoder.context(request, configuration: config)).contents)
        #expect(throws: ModelProviderError.self) {
            try binding.validate(request: nativeRequest, context: nativeContext, configuration: config, now: Date())
        }
    }

    @Test func malformedForeignCallsAndUnpairedResultsStillFail() throws {
        let badCalls = [ToolCall(id: call.id, name: call.name, argumentsJSON: "{}", completeness: .incomplete),
            .init(id: call.id, name: "bad name", argumentsJSON: "{}", completeness: .complete),
            .init(id: call.id, name: call.name, argumentsJSON: "[]", completeness: .complete),
            .init(id: .init(rawValue: ""), name: call.name, argumentsJSON: "{}", completeness: .complete)]
        for bad in badCalls { #expect(throws: ModelProviderError.self) { _ = try parts(history([], calls: [bad])) } }
        #expect(throws: ModelProviderError.self) { _ = try parts(history([], calls: [call, call])) }
        let missingCall = ModelRequest(model: model, messages: [.user([.text("Hi")]), .tool(.init(callID: call.id, content: [.text("orphan")], isError: false))])
        #expect(throws: ModelProviderError.self) { _ = try parts(missingCall) }
        #expect(throws: ModelProviderError.self) { _ = try parts(.init(model: model, messages: Array(history([]).messages.dropLast()))) }
    }
}

private extension JSONValue {
    subscript(_ index: Int) -> JSONValue? {
        guard case .array(let values) = self, values.indices.contains(index) else { return nil }
        return values[index]
    }
}
