import AgentCore
import AgentModels
import Foundation
import Testing
@testable import AgentProviders

/// The Host configures a provider-wide grouping/routing key. These request tests
/// verify propagation and lifecycle, not upstream cache hits or gateway stickiness.
struct PromptCacheKeyTests {
    private static let model = ModelID(provider: "openai", name: "fixture")

    private static func bodies(_ probe: ProviderRequestProbe) async throws -> [[String: JSONValue]] {
        try await probe.requests.map { request in
            guard case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)) else {
                throw ModelProviderError(kind: .invalidRequest, message: "Request body is not an object.")
            }
            return body
        }
    }

    @Test func everyRequestOfAConversationCarriesTheSameKey() async throws {
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(
            apiKey: "fixture-key", promptCacheKey: "conversation-1",
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAIToolFixture, openAITextFixture])
        )
        let result = try await Agent(model: Self.model, provider: provider, tools: [ProviderCalculator()])
            .makeSession().run("Add 2 and 3").wait()
        #expect(result.outcome == .completed)

        let bodies = try await Self.bodies(probe)
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0["prompt_cache_key"] == .string("conversation-1") })
        // Verify request parameter propagation across changing tool-round transcripts.
        let raw = await probe.requests.compactMap(\.httpBody).map { String(decoding: $0, as: UTF8.self) }
        #expect(raw.allSatisfy { $0.contains(#""prompt_cache_key":"conversation-1""#) })
    }

    @Test func aProviderGivenNoKeyWritesTheSameBodyAsBefore() async throws {
        let keyed = ProviderRequestProbe()
        let plain = ProviderRequestProbe()
        let request = ModelRequest(model: Self.model, messages: [.user([.text("Hi")])])
        for (probe, key) in [(keyed, Optional("conversation-1")), (plain, nil)] {
            let provider = try OpenAIResponsesProvider(
                apiKey: "fixture-key", promptCacheKey: key,
                transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture])
            )
            for try await _ in provider.stream(request: request) {}
        }
        let plainBody = try #require(await plain.requests.first?.httpBody)
        #expect(!String(decoding: plainBody, as: UTF8.self).contains("prompt_cache_key"))
        var keyedBody = try #require(try await Self.bodies(keyed).first)
        #expect(keyedBody.removeValue(forKey: "prompt_cache_key") == .string("conversation-1"))
        #expect(try ProviderJSON.encode(JSONValue.object(keyedBody)) == plainBody)

        let defaulted = try OpenAIResponsesRequestEncoder.encode(
            request, maximumOutputTokens: 4_096, reasoningEffort: nil, reasoningSummary: nil)
        #expect(try ProviderJSON.encode(defaulted) == plainBody)
    }

    @Test func separatelyConfiguredProvidersAndSessionsCarryTheirOwnKeys() async throws {
        for key in ["a", "b"] {
            let probe = ProviderRequestProbe()
            let provider = try OpenAIResponsesProvider(apiKey: "fixture-key", promptCacheKey: key,
                transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
            let session = try Agent(model: Self.model, provider: provider).makeSession()
            #expect(try await session.run("Hi").wait().outcome == .completed)
            #expect(try await Self.bodies(probe).first?["prompt_cache_key"] == .string(key))
        }
    }

    @Test func repeatedRunsAndSharedProviderSessionsKeepTheConfiguredGroup() async throws {
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(apiKey: "fixture-key", promptCacheKey: "shared-group",
            transport: FixtureHTTPTransport(probe: probe, bodies: Array(repeating: openAITextFixture, count: 3)))
        let agent = try Agent(model: Self.model, provider: provider)
        let first = try agent.makeSession()
        let second = try agent.makeSession()
        #expect(first.id != second.id)
        for session in [first, first, second] {
            let run = try await session.run("Hi")
            #expect(try await run.wait().outcome == .completed)
            try await run.waitForDrain()
        }
        let bodies = try await Self.bodies(probe)
        #expect(bodies.count == 3)
        #expect(bodies.allSatisfy { $0["prompt_cache_key"] == .string("shared-group") })
        // The key must never enter the model-visible transcript or opaque continuation.
        #expect(bodies.allSatisfy { !String(describing: $0["input"]).contains("shared-group") })
    }

    @Test func restoredPersistentSessionUsesTheHostsReconstructedProviderKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-key-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let key = "host-persisted-group"
        let probe = ProviderRequestProbe()
        for restored in [false, true] {
            let journal = try restored ? openTestJournal(at: directory) : makeTestJournal(at: directory)
            let provider = try OpenAIResponsesProvider(apiKey: "fixture-key", promptCacheKey: key,
                transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture, openAITextFixture]))
            let session = try Agent(model: Self.model, provider: provider).makeSession(id: sessionID, journal: journal)
            if restored {
                #expect(try await session.conversationSnapshot().messages.contains(.user([.text("remember")])))
            }
            let run = try await session.run(restored ? "continue" : "remember")
            #expect(try await run.wait().outcome == .completed)
            try await run.waitForDrain()
            try await journal.close()
        }
        let bodies = try await Self.bodies(probe)
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0["prompt_cache_key"] == .string(key) })
    }

    @Test(arguments: ["", "  ", " key", "key ", "a\nb", "a\u{0}b"])
    func anUnusableKeyIsRefused(_ key: String) {
        #expect(throws: ModelProviderError.self) {
            _ = try OpenAIResponsesProvider(apiKey: "fixture-key", promptCacheKey: key)
        }
        #expect(throws: ModelProviderError.self) {
            _ = try LocalResponsesProvider(configuration: .init(
                baseURL: URL(string: "http://localhost:1234/v1")!, model: "fixture", promptCacheKey: key))
        }
    }

    @Test func theLocalResponsesProviderCarriesTheKeyOnlyWhenGiven() async throws {
        let keyed = ProviderRequestProbe()
        let plain = ProviderRequestProbe()
        let request = ModelRequest(model: .init(provider: "local-responses", name: "fixture"), messages: [.user([.text("Hi")])])
        for (probe, key) in [(keyed, Optional("conversation-1")), (plain, nil)] {
            let provider = try LocalResponsesProvider(
                configuration: .init(baseURL: URL(string: "http://localhost:1234/v1")!, model: "fixture",
                                     promptCacheKey: key),
                transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture])
            )
            for try await _ in provider.stream(request: request) {}
        }
        #expect(try await Self.bodies(keyed).first?["prompt_cache_key"] == .string("conversation-1"))
        let plainBody = try #require(await plain.requests.first?.httpBody)
        #expect(!String(decoding: plainBody, as: UTF8.self).contains("prompt_cache_key"))
    }

    @Test func otherProvidersDoNotWriteTheKey() throws {
        let deepSeek = try DeepSeekResponsesRequestEncoder.encode(
            .init(model: .init(provider: "deepseek", name: "fixture"), messages: [.user([.text("Hi")])]),
            maximumOutputTokens: 64, reasoningEffort: .none)
        let anthropic = try AnthropicRequestEncoder.encode(
            .init(model: .init(provider: "anthropic", name: "fixture"), messages: [.user([.text("Hi")])]),
            maximumOutputTokens: 64, thinking: .disabled)
        for body in [deepSeek, anthropic] {
            #expect(!String(decoding: try ProviderJSON.encode(body), as: UTF8.self).contains("prompt_cache_key"))
        }
    }
}
