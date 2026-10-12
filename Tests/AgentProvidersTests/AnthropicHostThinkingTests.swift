import AgentCore
import AgentModels
import AgentProviders
import Foundation
import Testing

struct AnthropicHostThinkingTests {
    let host = AnthropicHostCompactionTests()

    @Test(arguments: [AnthropicThinking.serviceDefault, .betweenTools, .disabled])
    func finalHTTPThinkingContract(_ thinking: AnthropicThinking) async throws {
        let probe = ProviderRequestProbe()
        let provider: AnthropicProvider
        if thinking == .disabled {
            provider = try .init(apiKey: "fixture", transport: FixtureHTTPTransport(probe: probe, bodies: [host.fixture(anthropicTextFixture)]))
        } else {
            provider = try .init(apiKey: "fixture", thinking: thinking,
                transport: FixtureHTTPTransport(probe: probe, bodies: [host.fixture(anthropicTextFixture)]))
        }
        for try await _ in provider.stream(request: .init(model: host.model, messages: [.user([.text("Hi")])])) {}
        let request = try #require(await probe.requests.first)
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!) else { Issue.record("no body"); return }
        #expect(fields["thinking"] == (thinking == .serviceDefault ? nil : .object(["type": .string(thinking == .betweenTools ? "between_tools" : "disabled")])))
        #expect(fields["output_config"] == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func betweenToolsProgressIsRetainedAndReplayedExactly() async throws {
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture", thinking: .betweenTools, effort: .high,
            transport: FixtureHTTPTransport(probe: probe, bodies: [host.fixture(anthropicThinkingToolFixture), host.fixture(anthropicTextFixture)]))
        let session = try Agent(model: host.model, provider: provider, tools: [ProviderCalculator()]).makeSession()
        let run = try await session.run("Calculate")
        let result = try await run.wait(); try await run.waitForDrain()
        #expect(result.outcome == .completed && result.toolCalls == 1)
        let requests = await probe.requests
        #expect(requests.count == 2)
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: requests[1].httpBody!),
              case .array(let messages) = fields["messages"], case .object(let assistant) = messages[1],
              case .array(let blocks) = assistant["content"] else { Issue.record("no replay"); return }
        #expect(blocks.first == .object(["type": .string("thinking"), "thinking": .string("Consider inputs."), "signature": .string("signature-1")]))
        #expect(fields["thinking"] == .object(["type": .string("between_tools")]))
    }

    @Test(arguments: [AnthropicThinking.serviceDefault, .betweenTools])
    func newModesCannotClaimBindingControlsOrThinkingTailQualification(_ thinking: AnthropicThinking) async throws {
        let probe = ProviderRequestProbe()
        let qualification = try NativeContextQualification(endpoint: host.endpoint, resolvedModelNames: [host.model.name], modes: [.anthropicOnDemand])
        for mismatch in [AnthropicThinkingPrefixMismatch.error, .dropBlock] {
            #expect(throws: ModelProviderError.self) {
                try AnthropicProvider(apiKey: "fixture", thinking: thinking,
                    nativeContext: .init(qualification: qualification, thinkingPrefixMismatch: mismatch),
                    transport: FixtureHTTPTransport(probe: probe, bodies: []))
            }
        }
        #expect(throws: ModelProviderError.self) {
            try AnthropicProvider(apiKey: "fixture", thinking: thinking,
                nativeContext: .init(qualification: qualification, preservedThinking: true),
                transport: FixtureHTTPTransport(probe: probe, bodies: []))
        }
        let provider = try AnthropicProvider(apiKey: "fixture", thinking: thinking,
            nativeContext: .init(qualification: qualification), transport: FixtureHTTPTransport(probe: probe, bodies: []))
        #expect(!provider.supportsPreservedThinkingCompaction)
        #expect(await probe.requests.isEmpty)
    }

    @Test func betweenToolsUnsupportedEffortAndModelNeverDispatch() async throws {
        let probe = ProviderRequestProbe()
        for effort in ["xhigh", "max"] {
            #expect(throws: ModelProviderError.self) {
                try AnthropicProvider(apiKey: "fixture", thinking: .betweenTools, effort: .init(rawValue: effort),
                    transport: FixtureHTTPTransport(probe: probe, bodies: []))
            }
        }
        let provider = try AnthropicProvider(apiKey: "fixture", thinking: .betweenTools,
            transport: FixtureHTTPTransport(probe: probe, bodies: []))
        do {
            for try await _ in provider.stream(request: .init(model: .init(provider: "anthropic", name: "claude-opus-5-5"), messages: [.user([.text("Hi")])])) {}
            Issue.record("unsupported model dispatched")
        } catch let error as ModelProviderError { #expect(error.kind == .unsupportedCapability) }
        #expect(await probe.requests.isEmpty)
    }

    @Test func catalogOnlyExposesExplicitBetweenTools() async throws {
        let body = #"{"data":[{"id":"claude-sonnet-5-5","capabilities":{"thinking":{"supported":true,"types":["between_tools"]}}},{"id":"claude-unknown","capabilities":{"thinking":{"supported":true,"types":["adaptive"]}}}],"has_more":false}"#
        let provider = try AnthropicModelCatalogProvider(apiKey: "fixture", serviceInstanceID: "fixture",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(body.utf8)], headers: ["Content-Type": "application/json"]))
        let models = try await provider.listModels(.init()).models
        #expect(models[0].reasoningControls.first { $0.kind == .thinkingMode }?.allowedValues == ["between_tools"])
        #expect(models[0].reasoningControls.first { $0.kind == .thinkingMode }?.executability == .executable)
        #expect(models[1].reasoningControls.first { $0.kind == .thinkingMode }?.allowedValues == ["adaptive"])
    }
}
