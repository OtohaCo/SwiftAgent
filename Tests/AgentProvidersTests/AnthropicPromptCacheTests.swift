import AgentCore
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentProviders

struct AnthropicPromptCacheTests {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = ModelID(provider: "anthropic", name: "fixture")

    private func configuration(automaticTTL: AnthropicPromptCaching.TTL? = nil,
                               breakpoints: [AnthropicPromptCaching.Breakpoint] = []) -> AnthropicPromptCaching {
        .init(endpoint: endpoint, modelNames: [model.name], capabilities: [.automatic, .explicitBreakpoints, .oneHourTTL],
              automaticTTL: automaticTTL, breakpoints: breakpoints)
    }

    @Test func automaticAndExplicitCacheControlsReachTheActualRequest() async throws {
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture", promptCaching: configuration(
            automaticTTL: .fiveMinutes,
            breakpoints: [.init(target: .system(index: 0), ttl: .oneHour)]),
            transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture]))
        for try await _ in provider.stream(request: .init(model: model, messages: [
            .system("stable"), .developer("dynamic"), .user([.text("question")]),
        ])) {}
        let body = try requestBody(await probe.requests.first)
        #expect(body["cache_control"] == .object(["type": .string("ephemeral"), "ttl": .string("5m")]))
        #expect(body["system"] == .array([
            .object(["type": .string("text"), "text": .string("stable"),
                     "cache_control": .object(["type": .string("ephemeral"), "ttl": .string("1h")])]),
            .object(["type": .string("text"), "text": .string("\ndynamic")]),
        ]))
    }

    @Test func ineligibleEndpointOrModelFailsBeforeHTTP() async throws {
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture", promptCaching: configuration(automaticTTL: .fiveMinutes),
            transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture]))
        await #expect(throws: ModelProviderError.self) {
            for try await _ in provider.stream(request: .init(model: .init(provider: "anthropic", name: "unqualified"),
                messages: [.user([.text("hello")])])) {}
        }
        #expect(await probe.requests.isEmpty)
        #expect(throws: ModelProviderError.self) {
            try AnthropicProvider(apiKey: "fixture", endpoint: URL(string: "https://gateway.example/v1/messages"),
                                  promptCaching: configuration(automaticTTL: .fiveMinutes))
        }
    }

    @Test func nilConfigurationRetainsPreviousRequestBytes() throws {
        let request = ModelRequest(model: model, messages: [.system("one"), .developer("two"), .user([.text("Hi")])])
        let original = try AnthropicRequestEncoder.encode(request, maximumOutputTokens: 100, thinking: .disabled)
        let explicitNil = try AnthropicRequestEncoder.encode(request, maximumOutputTokens: 100, thinking: .disabled,
                                                             promptCaching: nil)
        #expect(try ProviderJSON.encode(original) == ProviderJSON.encode(explicitNil))
        guard case .object(let body) = original else { Issue.record("Missing object"); return }
        #expect(body["system"] == .string("one\ntwo"))
        #expect(body["cache_control"] == nil)
    }

    @Test func explicitToolAndMessageCoordinatesPreserveOrderWhenRolesAreGrouped() throws {
        let cache = configuration(breakpoints: [
            .init(target: .message(index: 2, contentBlock: 0), ttl: .fiveMinutes),
            .init(target: .lastTool, ttl: .oneHour),
        ])
        let request = ModelRequest(model: model, messages: [
            .system("instruction"), .user([.text("stable reference")]), .user([.text("second reference")]),
        ], tools: [
            .init(name: "zeta", description: "first", inputSchema: .object([:])),
            .init(name: "alpha", description: "second", inputSchema: .object([:])),
        ])
        guard case .object(let body) = try AnthropicRequestEncoder.encode(
            request, maximumOutputTokens: 100, thinking: .disabled, promptCaching: cache),
              case .array(let tools) = body["tools"], case .object(let lastTool) = tools.last,
              case .array(let messages) = body["messages"], case .object(let message) = messages.first,
              case .array(let content) = message["content"], case .object(let first) = content[0],
              case .object(let last) = content[1] else { Issue.record("Missing cache targets"); return }
        #expect(lastTool["name"] == .string("alpha"))
        #expect(lastTool["cache_control"] == cache.control(.oneHour))
        #expect(first["text"] == .string("stable reference"))
        #expect(first["cache_control"] == nil)
        #expect(last["cache_control"] == cache.control(.fiveMinutes))
        #expect(messages.count == 1)
    }

    @Test func illegalControlsFailBeforeSending() throws {
        let request = ModelRequest(model: model, messages: [.system("stable"), .user([.text("dynamic")])])
        let invalid: [AnthropicPromptCaching] = [
            configuration(automaticTTL: .oneHour, breakpoints: [.init(target: .system(index: 0), ttl: .fiveMinutes)]),
            configuration(automaticTTL: .fiveMinutes, breakpoints: [.init(target: .message(index: 1, contentBlock: 0), ttl: .oneHour)]),
            configuration(breakpoints: [.init(target: .system(index: 0)), .init(target: .system(index: 0))]),
            configuration(breakpoints: [.init(target: .system(index: 8))]),
            configuration(breakpoints: [.init(target: .lastTool)]),
            configuration(breakpoints: [.init(target: .message(index: 0, contentBlock: 0))]),
            configuration(breakpoints: [.init(target: .message(index: 1, contentBlock: 8))]),
            configuration(breakpoints: [.init(target: .message(index: -1, contentBlock: 0))]),
            configuration(automaticTTL: .fiveMinutes, breakpoints: (0..<4).map { .init(target: .system(index: $0)) }),
            .init(endpoint: endpoint, modelNames: [model.name], capabilities: [.explicitBreakpoints], automaticTTL: .fiveMinutes),
            .init(endpoint: endpoint, modelNames: [model.name], capabilities: [.automatic], automaticTTL: .oneHour),
        ]
        for cache in invalid {
            #expect(throws: ModelProviderError.self) {
                try AnthropicRequestEncoder.encode(request, maximumOutputTokens: 100, thinking: .disabled, promptCaching: cache)
            }
        }
    }

    @Test func strategySurvivesToolRoundsRunsSharedSessionsAndProviderReconstruction() async throws {
        let probe = ProviderRequestProbe()
        let cache = configuration(automaticTTL: .fiveMinutes, breakpoints: [
            .init(target: .lastTool, ttl: .oneHour), .init(target: .system(index: 0), ttl: .oneHour),
        ])
        let fixtures = [anthropicThinkingToolFixture] + Array(repeating: anthropicTextFixture, count: 4)
        func provider() throws -> AnthropicProvider {
            try AnthropicProvider(apiKey: "fixture", promptCaching: cache,
                transport: FixtureHTTPTransport(probe: probe, bodies: fixtures))
        }
        let agent = try Agent(model: model, provider: provider(), tools: [ProviderCalculator()],
                              configuration: .init(instructions: "stable"))
        let session = try agent.makeSession()
        #expect(try await session.run("Compute").wait().outcome == .completed)
        #expect(try await session.run("Continue").wait().outcome == .completed)
        #expect(try await agent.makeSession().run("Other session").wait().outcome == .completed)
        let rebuilt = try Agent(model: model, provider: provider(), tools: [ProviderCalculator()],
                                configuration: .init(instructions: "stable"))
        #expect(try await rebuilt.makeSession().run("Rebuilt").wait().outcome == .completed)
        let bodies = try await probe.requests.map(requestBody)
        #expect(bodies.count == 5)
        #expect(bodies.allSatisfy { $0["cache_control"] == cache.control(.fiveMinutes) })
        #expect(bodies.allSatisfy { $0["tools"] == bodies[0]["tools"] && $0["system"] == bodies[0]["system"] })
        guard case .array(let messages) = bodies[1]["messages"], case .object(let assistant) = messages[1],
              case .array(let blocks) = assistant["content"], case .object(let thinking) = blocks.first else {
            Issue.record("Missing signed continuation"); return
        }
        #expect(thinking["type"] == .string("thinking"))
        #expect(thinking["signature"] == .string("signature-1"))
        #expect(thinking["cache_control"] == nil)
    }

    @Test func thinkingCannotBeMarkedAndContinuationValidationStillRuns() async throws {
        var source = ModelEventAccumulator()
        let provider = try AnthropicProvider(apiKey: "fixture",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [anthropicThinkingToolFixture]))
        for try await event in provider.stream(request: .init(model: model, messages: [.user([.text("Compute")])])) {
            try source.append(event)
        }
        let response = try source.finish()
        let request = ModelRequest(model: model, messages: [.user([.text("Compute")]),
            .assistant(content: response.content, toolCalls: response.toolCalls), .user([.text("Continue")])])
        #expect(throws: ModelProviderError.self) {
            try AnthropicRequestEncoder.encode(request, maximumOutputTokens: 100, thinking: .disabled,
                promptCaching: configuration(breakpoints: [.init(target: .message(index: 1, contentBlock: 0))]))
        }
        _ = try AnthropicRequestEncoder.encode(request, maximumOutputTokens: 100, thinking: .disabled,
            promptCaching: configuration(breakpoints: [.init(target: .message(index: 1, contentBlock: 1))]))
        var alteredMessages = request.messages
        alteredMessages[1] = .assistant(content: response.content + [.text("altered")], toolCalls: response.toolCalls)
        let altered = ModelRequest(model: model, messages: alteredMessages)
        #expect(throws: ModelProviderError.self) {
            try AnthropicRequestEncoder.encode(altered, maximumOutputTokens: 100, thinking: .disabled,
                promptCaching: configuration(automaticTTL: .fiveMinutes))
        }
    }

    @Test func explicitPrefixChangesOnlyWhenTheHostChangesItsContext() throws {
        let cache = configuration(breakpoints: [.init(target: .system(index: 0), ttl: .oneHour)])
        var encoded: [[String: JSONValue]] = []
        for (stable, dynamic) in [("reference-v1", "suffix-a"), ("reference-v1", "suffix-b"), ("reference-v2", "suffix-b")] {
            guard case .object(let body) = try AnthropicRequestEncoder.encode(.init(model: model, messages: [
                .system(stable), .developer(dynamic), .user([.text("question")]),
            ]), maximumOutputTokens: 100, thinking: .disabled, promptCaching: cache) else { return }
            encoded.append(body)
        }
        guard case .array(let first) = encoded[0]["system"], case .array(let second) = encoded[1]["system"],
              case .array(let changed) = encoded[2]["system"] else { Issue.record("Missing instructions"); return }
        #expect(first[0] == second[0])
        #expect(first[0] != changed[0])
        #expect(first[1] != second[1])
    }

    @Test func restoredSessionUsesTheHostsResuppliedConfigurationAndOriginalPrefix() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anthropic-cache-restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ProviderRequestProbe()
        let id = UUID()
        let cache = configuration(automaticTTL: .fiveMinutes,
                                  breakpoints: [.init(target: .system(index: 0), ttl: .oneHour)])
        for restored in [false, true] {
            let journal = try restored ? openTestJournal(at: directory) : makeTestJournal(at: directory)
            let provider = try AnthropicProvider(apiKey: "fixture", promptCaching: cache,
                transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture, anthropicTextFixture]))
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
        #expect(bodies.allSatisfy { $0["cache_control"] == cache.control(.fiveMinutes) && $0["system"] == bodies[0]["system"] })
        guard case .array(let original) = bodies[0]["messages"], case .array(let restored) = bodies[1]["messages"] else { return }
        #expect(Array(restored.prefix(original.count)) == original)
    }

    @Test func strategyCodableRoundTripPreservesQualificationAndTTL() throws {
        let cache = configuration(automaticTTL: .fiveMinutes, breakpoints: [
            .init(target: .system(index: 0), ttl: .oneHour), .init(target: .message(index: 1, contentBlock: 0)),
        ])
        #expect(try JSONDecoder().decode(AnthropicPromptCaching.self, from: JSONEncoder().encode(cache)) == cache)
        for names in [Set<String>(), [""], [" fixture"], ["fixture\n"]] {
            #expect(throws: ModelProviderError.self) {
                try AnthropicProvider(apiKey: "fixture", promptCaching: .init(endpoint: endpoint,
                    modelNames: names, capabilities: [.automatic], automaticTTL: .fiveMinutes))
            }
        }
    }

    private func requestBody(_ request: URLRequest?) throws -> [String: JSONValue] {
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: #require(request?.httpBody)) else {
            throw ModelProviderError(kind: .invalidResponse, message: "Missing fixture body.")
        }
        return body
    }
}
