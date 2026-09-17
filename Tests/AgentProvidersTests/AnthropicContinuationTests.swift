import AgentModels
import Foundation
import Testing
@testable import AgentProviders

struct AnthropicContinuationTests {
    @Test func alteredSnapshotsCannotOverrideTheCanonicalToolAndVisibleContent() async throws {
        let source = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [anthropicThinkingToolFixture]))
        let model = ModelID(provider: "anthropic", name: "fixture")
        var accumulator = ModelEventAccumulator()
        for try await event in source.stream(request: .init(model: model, messages: [.user([.text("Compute")])])) {
            try accumulator.append(event)
        }
        let response = try accumulator.finish()
        let state = try #require(response.content.compactMap { part -> ModelProviderContinuation? in
            if case .providerContinuation(let state) = part { state } else { nil }
        }.first)
        guard case .object(var payload) = try JSONDecoder().decode(JSONValue.self, from: state.payload),
              case .array(var blocks) = payload["content"], case .object(var call) = blocks.last else {
            Issue.record("Missing native snapshot"); return
        }
        call["name"] = .string("different_tool")
        blocks[blocks.count - 1] = .object(call)
        payload["content"] = .array(blocks)
        let changed = ModelProviderContinuation(model: model, format: state.format,
                                                 payload: try JSONEncoder().encode(JSONValue.object(payload)))
        let reasoning = ModelContent.reasoning("Consider inputs.")
        let cases: [([ModelContent], [ToolCall])] = [
            ([.reasoning("Changed"), .providerContinuation(state)], response.toolCalls),
            ([reasoning, .providerContinuation(changed)], response.toolCalls),
            ([reasoning, .providerContinuation(state), .providerContinuation(state)], response.toolCalls),
            ([reasoning, .providerContinuation(.init(model: model, format: "unknown", payload: state.payload))], response.toolCalls),
            ([reasoning, .providerContinuation(.init(model: model, format: state.format, payload: Data([255])))], response.toolCalls),
            ([reasoning, .providerContinuation(state)], []),
        ]
        for (content, calls) in cases {
            let probe = ProviderRequestProbe()
            let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture]))
            let request = ModelRequest(model: model, messages: [.user([.text("Compute")]), .assistant(content: content, toolCalls: calls), .user([.text("Continue")])])
            do {
                for try await _ in provider.stream(request: request) {}
                Issue.record("Altered continuation must fail")
            } catch { #expect((error as? ModelProviderError)?.kind == .invalidRequest) }
            #expect(await probe.requests.isEmpty)
        }
    }

    @Test func anotherProvidersOpaqueStateIsNotSentToThisEndpoint() async throws {
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture]))
        let foreign = ModelProviderContinuation(model: .init(provider: "other", name: "fixture"), format: "other.v1", payload: Data("must-not-leak".utf8))
        let request = ModelRequest(model: .init(provider: "anthropic", name: "fixture"), messages: [
            .user([.text("Hi")]), .assistant(content: [.text("Earlier"), .providerContinuation(foreign)], toolCalls: []), .user([.text("Continue")]),
        ])
        for try await _ in provider.stream(request: request) {}
        let requests = await probe.requests
        let body = String(decoding: try #require(requests.first?.httpBody), as: UTF8.self)
        #expect(body.contains("Earlier"))
        #expect(!body.contains("must-not-leak"))
    }
}
