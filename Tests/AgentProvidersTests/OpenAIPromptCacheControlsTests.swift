import AgentCore
import AgentModels
import AgentUsage
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentProviders

struct OpenAIPromptCacheControlsTests {
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let model = ModelID(provider: "openai", name: "fixture")

    private func configuration(mode: OpenAIResponsesPromptCaching.Mode = .explicit,
                               breakpoints: [OpenAIResponsesPromptCaching.Breakpoint] = [.init(messageIndex: 0)]) -> OpenAIResponsesPromptCaching {
        .init(endpoint: endpoint, modelNames: [model.name], capabilities: [.modernControls, .prewarm],
              policy: .modern(mode: mode, ttl: .thirtyMinutes, breakpoints: breakpoints))
    }

    @Test func explicitPrefixMarkerAndModernOptionsReachTheActualRequest() async throws {
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(apiKey: "fixture", promptCacheKey: "stable-group",
            promptCaching: configuration(), transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
        for try await _ in provider.stream(request: .init(model: model, messages: [.developer("stable"), .user([.text("suffix")])])) {}
        let body = try requestBody(await probe.requests.first)
        #expect(body["prompt_cache_key"] == .string("stable-group"))
        #expect(body["prompt_cache_options"] == .object(["mode": .string("explicit"), "ttl": .string("30m")]))
        guard case .array(let input) = body["input"], case .object(let developer) = input.first else {
            Issue.record("Missing developer input"); return
        }
        #expect(developer["content"] == .array([.object([
            "type": .string("input_text"), "text": .string("stable"),
            "prompt_cache_breakpoint": .object(["mode": .string("explicit")]),
        ])]))
        #expect(body["prompt_cache_retention"] == nil)
    }

    @Test func prewarmIsSeparateFromNormalGenerationAndRetainsWriteUsage() async throws {
        let probe = ProviderRequestProbe()
        let empty = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"prewarm-1","model":"fixture","status":"in_progress"}}"#),
            ("response.completed", #"{"type":"response.completed","response":{"id":"prewarm-1","model":"fixture","status":"completed","incomplete_details":null,"output":[],"usage":{"input_tokens":15000,"output_tokens":0,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":15000}}}}"#),
        ])
        let provider = try OpenAIResponsesProvider(apiKey: "fixture", promptCacheKey: "stable-group",
            promptCaching: configuration(), transport: FixtureHTTPTransport(probe: probe, bodies: [empty, openAITextFixture]))
        let request = ModelRequest(model: model, messages: [.developer("stable")])
        var response = ModelEventAccumulator()
        var usage = UsageAccumulator()
        let identity = UsageRecordIdentity(source: .modelResponse, invocationID: "host-prewarm-1", model: model)
        for try await event in provider.prewarm(request: request) {
            try response.append(event)
            switch event {
            case .usage(let snapshot): _ = usage.record(.init(identity: identity, usage: snapshot, status: .provisional))
            case .responseCompleted(let final):
                let observation = UsageObservation(identity: identity, usage: final.usage, status: .finalized)
                #expect(usage.record(observation).accepted)
                #expect(usage.record(observation).disposition == .duplicate)
            default: break
            }
        }
        #expect(try response.finish().usage.cacheWriteInputTokens == 15_000)
        #expect(usage.summary().observedResponseCount == 1)
        #expect(usage.summary().cacheWriteInputTokens.reportedSubtotal == 15_000)
        #expect(usage.summary().totalTokens == 15_000)
        #expect(try JSONDecoder().decode(UsageSummary.self, from: JSONEncoder().encode(usage.summary())) == usage.summary())
        for try await _ in provider.stream(request: request) {}
        let bodies = try await probe.requests.map(requestBody)
        #expect(bodies.count == 2)
        guard case .object(let warmOptions) = bodies[0]["prompt_cache_options"],
              case .object(let normalOptions) = bodies[1]["prompt_cache_options"] else {
            Issue.record("Missing options"); return
        }
        #expect(warmOptions["prewarm"] == .bool(true))
        #expect(normalOptions["prewarm"] == nil)
        #expect(bodies.allSatisfy { $0["prompt_cache_key"] == .string("stable-group") })
    }

    @Test func legacyRetentionIsQualifiedSeparatelyFromModernControls() async throws {
        let probe = ProviderRequestProbe()
        let retention = OpenAIResponsesPromptCaching(endpoint: endpoint, modelNames: ["gpt-5.5"],
            capabilities: [.legacy24HourRetention], policy: .legacy(retention: .twentyFourHours))
        let fixture = Data(String(decoding: openAITextFixture, as: UTF8.self)
            .replacingOccurrences(of: "fixture", with: "gpt-5.5").utf8)
        let provider = try OpenAIResponsesProvider(apiKey: "fixture", promptCaching: retention,
            transport: FixtureHTTPTransport(probe: probe, bodies: [fixture]))
        for try await _ in provider.stream(request: .init(model: .init(provider: "openai", name: "gpt-5.5"),
                                                          messages: [.user([.text("Hello")])])) {}
        let body = try requestBody(await probe.requests.first)
        #expect(body["prompt_cache_retention"] == .string("24h"))
        #expect(body["prompt_cache_options"] == nil)
        await #expect(throws: ModelProviderError.self) {
            for try await _ in provider.prewarm(request: .init(model: .init(provider: "openai", name: "gpt-5.5"),
                messages: [.user([.text("Hello")])])) {}
        }
        #expect(await probe.requests.count == 1)
    }

    @Test func absentControlsPreserveOriginalBytesAndUnsupportedControlsFailBeforeHTTP() async throws {
        let request = ModelRequest(model: model, messages: [.developer("stable"), .user([.text("dynamic")])])
        let original = try OpenAIResponsesRequestEncoder.encode(request, maximumOutputTokens: 100,
            reasoningEffort: nil, reasoningSummary: nil)
        let plain = try OpenAIResponsesRequestEncoder.encode(request, maximumOutputTokens: 100,
            reasoningEffort: nil, reasoningSummary: nil, promptCaching: nil)
        #expect(try ProviderJSON.encode(original) == ProviderJSON.encode(plain))
        #expect(throws: ModelProviderError.self) {
            try OpenAIResponsesProvider(apiKey: "fixture", endpoint: URL(string: "https://gateway.example/v1/responses"),
                                        promptCaching: configuration())
        }
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(apiKey: "fixture", promptCaching: configuration(),
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
        await #expect(throws: ModelProviderError.self) {
            for try await _ in provider.stream(request: .init(model: .init(provider: "openai", name: "unqualified"),
                                                              messages: request.messages)) {}
        }
        #expect(await probe.requests.isEmpty)
        let noControls = try OpenAIResponsesProvider(apiKey: "fixture",
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
        await #expect(throws: ModelProviderError.self) { for try await _ in noControls.prewarm(request: request) {} }
        #expect(await probe.requests.isEmpty)
    }

    @Test func modernSlotLimitsDuplicateCoordinatesAndIneligibleTargetsAreRejected() throws {
        let request = ModelRequest(model: model, messages: [.developer("stable"), .user([.text("dynamic")]),
            .assistant(content: [.text("history")], toolCalls: [])])
        let invalid = [
            configuration(mode: .implicit, breakpoints: (0..<4).map { .init(messageIndex: $0) }),
            configuration(breakpoints: (0..<5).map { .init(messageIndex: $0) }),
            configuration(breakpoints: [.init(messageIndex: 0), .init(messageIndex: 0)]),
            configuration(breakpoints: [.init(messageIndex: -1)]),
            configuration(breakpoints: [.init(messageIndex: 20)]),
            configuration(breakpoints: [.init(messageIndex: 0, contentBlock: 20)]),
            configuration(breakpoints: [.init(messageIndex: 2)]),
            OpenAIResponsesPromptCaching(endpoint: endpoint, modelNames: [model.name], capabilities: [],
                policy: .modern(mode: .implicit, ttl: .thirtyMinutes, breakpoints: [])),
            OpenAIResponsesPromptCaching(endpoint: endpoint, modelNames: [model.name], capabilities: [.legacy24HourRetention],
                policy: .legacy(retention: .inMemory)),
        ]
        for cache in invalid {
            #expect(throws: ModelProviderError.self) {
                try OpenAIResponsesRequestEncoder.encode(request, maximumOutputTokens: 100,
                    reasoningEffort: nil, reasoningSummary: nil, promptCaching: cache)
            }
        }
        _ = try OpenAIResponsesRequestEncoder.encode(request, maximumOutputTokens: 100,
            reasoningEffort: nil, reasoningSummary: nil,
            promptCaching: configuration(mode: .explicit, breakpoints: []))
    }

    @Test func localControlsRequireOptInForTheDerivedEndpointAndKeepTheKey() async throws {
        let probe = ProviderRequestProbe()
        let localEndpoint = URL(string: "http://localhost:1234/v1/responses")!
        let cache = OpenAIResponsesPromptCaching(endpoint: localEndpoint, modelNames: [model.name],
            capabilities: [.modernControls], policy: .modern(mode: .implicit, ttl: .thirtyMinutes, breakpoints: []))
        let provider = try LocalResponsesProvider(configuration: .init(baseURL: URL(string: "http://localhost:1234/v1")!,
            model: model.name, promptCacheKey: "host-local", promptCaching: cache),
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
        for try await _ in provider.stream(request: .init(model: provider.model, messages: [.user([.text("Hello")])])) {}
        let body = try requestBody(await probe.requests.first)
        #expect(body["prompt_cache_key"] == .string("host-local"))
        #expect(body["prompt_cache_options"] == .object(["mode": .string("implicit"), "ttl": .string("30m")]))
        #expect(throws: ModelProviderError.self) {
            try LocalResponsesProvider(configuration: .init(baseURL: URL(string: "http://localhost:1234/v1")!,
                model: model.name, promptCaching: configuration()))
        }
        let localRequest = ModelRequest(model: provider.model, messages: [.user([.text("Hello")])])
        let plain = try LocalResponsesRequestEncoder.encode(localRequest, maximumOutputTokens: 100, images: false)
        let nilControls = try LocalResponsesRequestEncoder.encode(localRequest, maximumOutputTokens: 100,
            images: false, promptCaching: nil)
        #expect(try ProviderJSON.encode(plain) == ProviderJSON.encode(nilControls))
    }

    @Test func canonicalToolResultMarkerKeepsErrorContentAndNativeContinuation() async throws {
        var decoded = ModelEventAccumulator()
        let source = try OpenAIResponsesProvider(apiKey: "fixture",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [openAIToolFixture]))
        for try await event in source.stream(request: .init(model: model, messages: [.user([.text("Compute")])])) {
            try decoded.append(event)
        }
        let response = try decoded.finish()
        let call = try #require(response.toolCalls.first)
        let request = ModelRequest(model: model, messages: [.user([.text("Compute")]),
            .assistant(content: response.content, toolCalls: response.toolCalls),
            .tool(.init(callID: call.id, content: [.text("failure")], isError: true)),
        ])
        let cache = configuration(breakpoints: [.init(messageIndex: 2)])
        guard case .object(let original) = try OpenAIResponsesRequestEncoder.encode(request, maximumOutputTokens: 100,
            reasoningEffort: nil, reasoningSummary: nil),
              case .object(let cached) = try OpenAIResponsesRequestEncoder.encode(request, maximumOutputTokens: 100,
            reasoningEffort: nil, reasoningSummary: nil, promptCaching: cache),
              case .array(let before) = original["input"], case .array(let after) = cached["input"],
              case .object(let originalTool) = before.last, case .object(let cachedTool) = after.last,
              case .array(let output) = cachedTool["output"], case .object(let block) = output.first else {
            Issue.record("Missing tool output cache target"); return
        }
        #expect(Array(before.dropLast()) == Array(after.dropLast()))
        #expect(block["text"] == originalTool["output"])
        #expect(block["prompt_cache_breakpoint"] == .object(["mode": .string("explicit")]))
        var tampered = request.messages
        tampered[1] = .assistant(content: response.content + [.text("tampered")], toolCalls: response.toolCalls)
        #expect(throws: ModelProviderError.self) {
            try OpenAIResponsesRequestEncoder.encode(.init(model: model, messages: tampered), maximumOutputTokens: 100,
                reasoningEffort: nil, reasoningSummary: nil, promptCaching: cache)
        }
    }

    @Test func staticPrefixSurvivesSuffixChangesButContextChangesInvalidateItsBytes() throws {
        let cache = configuration()
        var encoded: [[String: JSONValue]] = []
        for (prefix, suffix) in [("reference-v1", "suffix-a"), ("reference-v1", "suffix-b"), ("reference-v2", "suffix-b")] {
            guard case .object(let body) = try OpenAIResponsesRequestEncoder.encode(.init(model: model, messages: [
                .developer(prefix), .developer(suffix), .user([.text("question")]),
            ]), maximumOutputTokens: 100, reasoningEffort: nil, reasoningSummary: nil, promptCaching: cache) else { return }
            encoded.append(body)
        }
        guard case .array(let first) = encoded[0]["input"], case .array(let second) = encoded[1]["input"],
              case .array(let changed) = encoded[2]["input"] else { Issue.record("Missing input"); return }
        #expect(try ProviderJSON.encode(first[0]) == ProviderJSON.encode(second[0]))
        #expect(first[1] != second[1])
        #expect(first[0] != changed[0])
    }

    @Test func toolRoundsAndSessionRunsKeepTheSameConfiguredPrefixAndKey() async throws {
        let probe = ProviderRequestProbe()
        let secondToolRound = Data(String(decoding: openAIToolFixture, as: UTF8.self)
            .replacingOccurrences(of: "resp-tool", with: "resp-tool-2")
            .replacingOccurrences(of: "fc-1", with: "fc-2")
            .replacingOccurrences(of: "call-1", with: "call-2").utf8)
        let provider = try OpenAIResponsesProvider(apiKey: "fixture", promptCacheKey: "shared-prefix-v1",
            promptCaching: configuration(), transport: FixtureHTTPTransport(probe: probe,
                bodies: [openAIToolFixture, secondToolRound, openAITextFixture, openAITextFixture, openAITextFixture]))
        let agent = try Agent(model: model, provider: provider, tools: [ProviderCalculator()],
                              configuration: .init(instructions: "stable"))
        let session = try agent.makeSession()
        #expect(try await session.run("Compute").wait().outcome == .completed)
        #expect(try await session.run("Continue").wait().outcome == .completed)
        #expect(try await agent.makeSession().run("Other session").wait().outcome == .completed)
        let bodies = try await probe.requests.map(requestBody)
        #expect(bodies.count == 5)
        #expect(bodies.allSatisfy { $0["prompt_cache_key"] == .string("shared-prefix-v1") })
        #expect(bodies.allSatisfy { $0["prompt_cache_options"] == bodies[0]["prompt_cache_options"] && $0["tools"] == bodies[0]["tools"] })
        var prefixes: [JSONValue] = []
        for body in bodies {
            guard case .array(let input) = body["input"], let first = input.first else { Issue.record("Missing prefix"); return }
            prefixes.append(first)
        }
        #expect(prefixes.allSatisfy { $0 == prefixes[0] })
    }

    @Test func reconstructedProviderCarriesPersistedSessionStrategyAndPreservesHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-controls-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ProviderRequestProbe()
        let id = UUID()
        for restored in [false, true] {
            let journal = try restored ? openTestJournal(at: directory) : makeTestJournal(at: directory)
            let provider = try OpenAIResponsesProvider(apiKey: "fixture", promptCacheKey: "persisted-group",
                promptCaching: configuration(), transport: FixtureHTTPTransport(probe: probe,
                    bodies: [openAITextFixture, openAITextFixture]))
            let session = try Agent(model: model, provider: provider, configuration: .init(instructions: "stable"))
                .makeSession(id: id, journal: journal)
            if restored { #expect(try await session.conversationSnapshot().messages.contains(.user([.text("remember")]))) }
            let run = try await session.run(restored ? "continue" : "remember")
            #expect(try await run.wait().outcome == .completed)
            try await run.waitForDrain()
            try await journal.close()
        }
        let bodies = try await probe.requests.map(requestBody)
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0["prompt_cache_key"] == .string("persisted-group") && $0["prompt_cache_options"] == bodies[0]["prompt_cache_options"] })
        guard case .array(let original) = bodies[0]["input"], case .array(let restored) = bodies[1]["input"] else { return }
        #expect(Array(restored.prefix(original.count)) == original)
    }

    @Test func qualifiedAliasesUseResolvedIdentityWhileWireIdentityStaysTheAlias() async throws {
        let probe = ProviderRequestProbe()
        let cache = OpenAIResponsesPromptCaching(endpoint: endpoint, modelNames: ["fixture"], capabilities: [.modernControls],
            policy: .modern(mode: .implicit, ttl: .thirtyMinutes, breakpoints: []))
        let provider = try OpenAIResponsesProvider(apiKey: "fixture", resolvedModelIDsByAlias: ["alias": "fixture"],
            promptCaching: cache, transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
        for try await _ in provider.stream(request: .init(model: .init(provider: "openai", name: "alias"),
            messages: [.user([.text("Hi")])])) {}
        #expect(try requestBody(await probe.requests.first)["model"] == .string("alias"))
    }

    @Test func markerAfterAnOmittedEmptyAssistantUsesTheCorrectCanonicalMessage() throws {
        let request = ModelRequest(model: model, messages: [.assistant(content: [], toolCalls: []), .user([.text("stable")])])
        _ = try OpenAIResponsesRequestEncoder.encode(request, maximumOutputTokens: 100, reasoningEffort: nil,
            reasoningSummary: nil, promptCaching: configuration(breakpoints: [.init(messageIndex: 1)]))
    }

    @Test func aServiceIgnoringPrewarmIsRejectedWhileReportedUsageIsRetained() async throws {
        let provider = try OpenAIResponsesProvider(apiKey: "fixture", promptCaching: configuration(),
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [openAITextFixture]))
        var reported: ModelUsage?
        await #expect(throws: ModelProviderError.self) {
            for try await event in provider.prewarm(request: .init(model: model, messages: [.developer("stable")])) {
                if case .usage(let usage) = event { reported = usage }
            }
        }
        #expect(reported?.inputTokens == 5)
        #expect(reported?.outputTokens == 3)
    }

    @Test func controlsCodableRoundTripPreservesQualificationAndPolicy() throws {
        for cache in [configuration(), .init(endpoint: endpoint, modelNames: [model.name], capabilities: [.legacyInMemoryRetention],
                                              policy: .legacy(retention: .inMemory))] {
            #expect(try JSONDecoder().decode(OpenAIResponsesPromptCaching.self, from: JSONEncoder().encode(cache)) == cache)
        }
    }

    @Test func unknownPersistedCapabilitiesFailClearlyInsteadOfBeingSilentlyEnabled() throws {
        let modern = String(decoding: try JSONEncoder().encode(configuration()), as: UTF8.self)
            .replacingOccurrences(of: "modernControls", with: "futureUnsupportedControl")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OpenAIResponsesPromptCaching.self, from: Data(modern.utf8))
        }
        let anthropic = AnthropicPromptCaching(endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
            modelNames: ["fixture"], capabilities: [.automatic], automaticTTL: .fiveMinutes)
        let unknown = String(decoding: try JSONEncoder().encode(anthropic), as: UTF8.self)
            .replacingOccurrences(of: "automatic", with: "futureUnsupportedControl")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AnthropicPromptCaching.self, from: Data(unknown.utf8))
        }
    }

    @Test func imageMarkersPreserveBytesAndKeepTheInputCapabilityBoundary() throws {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        png.append(contentsOf: Array("IHDR".utf8))
        png.append(contentsOf: [0, 0, 0, 4, 0, 0, 0, 3, 8, 2, 0, 0, 0, 0, 0, 0, 0])
        let image = try ModelImage(data: png, description: "fixture image")
        let request = ModelRequest(model: model, messages: [.user([.text("stable"), .image(image)])])
        guard case .object(let body) = try OpenAIResponsesRequestEncoder.encode(request, maximumOutputTokens: 100,
            reasoningEffort: nil, reasoningSummary: nil,
            promptCaching: configuration(breakpoints: [.init(messageIndex: 0, contentBlock: 1)])),
              case .array(let input) = body["input"], case .object(let user) = input.first,
              case .array(let blocks) = user["content"], case .object(let imageBlock) = blocks.last else {
            Issue.record("Missing image marker"); return
        }
        #expect(imageBlock["image_url"] == .string("data:image/png;base64,\(image.data.base64EncodedString())"))
        #expect(imageBlock["prompt_cache_breakpoint"] == .object(["mode": .string("explicit")]))
        let localRequest = ModelRequest(model: .init(provider: "local-responses", name: model.name), messages: request.messages)
        #expect(throws: ModelProviderError.self) {
            try LocalResponsesRequestEncoder.encode(localRequest, maximumOutputTokens: 100, images: false,
                promptCaching: configuration(breakpoints: [.init(messageIndex: 0, contentBlock: 1)]))
        }
    }

    private func requestBody(_ request: URLRequest?) throws -> [String: JSONValue] {
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: #require(request?.httpBody)) else {
            throw ModelProviderError(kind: .invalidResponse, message: "Missing fixture body.")
        }
        return body
    }
}
