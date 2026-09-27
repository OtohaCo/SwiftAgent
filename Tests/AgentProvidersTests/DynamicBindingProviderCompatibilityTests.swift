import AgentCore
import AgentModels
import AgentProviders
import Foundation
import Testing

struct DynamicBindingProviderCompatibilityTests {
    @Test func deepSeekThinkingWithToolsRejectsHistoryWithoutNativeReasoningBeforeNetworkOrAppend() async throws {
        let model = ModelID(provider: "deepseek", name: "fixture")
        let seed = SeedDeepSeekProvider()
        let session = try Agent(
            model: model,
            provider: seed,
            tools: [try ProviderCalculator()]
        ).makeSession()
        let first = try await session.run("calculate")
        _ = try await first.wait()
        let before = try await session.conversationSnapshot()
        let network = ProviderRequestProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-secret",
            reasoningEffort: .high,
            transport: FixtureHTTPTransport(probe: network, bodies: [])
        )
        let binding = try AgentModelBinding(
            profileID: "deepseek-thinking",
            profileRevision: "1",
            model: model,
            provider: provider,
            deployment: .init(
                serviceInstanceID: "deepseek-primary",
                endpointScope: "https://api.deepseek.com/responses",
                apiDialect: "deepseek-responses",
                apiVersion: "v1"
            )
        )

        do {
            _ = try await session.run(
                "continue",
                using: binding,
                expectedConversationRevision: before.revision
            )
            Issue.record("Missing native reasoning history must fail local preflight")
        } catch let error as ModelProviderError {
            #expect(error.kind == .invalidRequest)
        }

        #expect(await network.requests.isEmpty)
        #expect(await session.history == before.messages)
    }
}

private struct SeedDeepSeekProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(
        id: "deepseek",
        capabilities: [.streaming, .multiTurn, .tools]
    )

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "seed", model: request.model)
            try emit(.responseStarted(info))
            if request.messages.last?.role == .tool {
                try emit(.textDelta("five"))
                try emit(.responseCompleted(.init(
                    info: info,
                    content: [.text("five")],
                    stopReason: .endTurn
                )))
            } else {
                let call = ToolCall(
                    id: .init(rawValue: "seed-call"),
                    name: ProviderCalculator.name,
                    argumentsJSON: #"{"a":2,"b":3}"#,
                    completeness: .complete
                )
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
                try emit(.responseCompleted(.init(
                    info: info,
                    toolCalls: [call],
                    stopReason: .toolCalls
                )))
            }
        }
    }
}
