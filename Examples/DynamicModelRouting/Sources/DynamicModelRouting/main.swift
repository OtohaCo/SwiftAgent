import AgentCatalog
import AgentCore
import AgentDecisions
import AgentJevProvider
import AgentModels
import DynamicModelRoutingSupport
import Foundation

@main
struct DynamicModelRoutingExample {
    static func main() async throws {
        let provider = FixtureModelProvider()
        let model = ModelID(provider: "fixture", name: "balanced")
        let agent = try Agent(model: model, provider: provider)
        let session = try agent.makeSession()
        let snapshot = try await session.conversationSnapshot()
        let scope = try ModelServiceScope(
            provider: "fixture",
            serviceInstanceID: "example",
            endpointScope: "fixture://example",
            apiDialect: "fixture"
        )
        let candidate = HostModelCandidate(
            id: "balanced",
            binding: try AgentModelBinding(
                profileID: "balanced",
                profileRevision: "1",
                model: model,
                provider: provider,
                deployment: .init(
                    serviceInstanceID: "example",
                    endpointScope: scope.endpointScope,
                    apiDialect: scope.apiDialect
                ),
                configurationSummary: ["mode": .string("fixture")]
            ),
            catalogEntry: .init(
                model: model,
                deploymentID: "balanced",
                serviceScope: scope,
                capabilities: .init(multiTurn: .supported),
                sources: [.init(kind: .hostOverride)]
            ),
            isRemote: false,
            adapterCanEncodeConfiguration: true,
            automaticSelectionAllowed: true
        )
        let catalogRevision = "example-catalog-1"
        let decisionProvider = try makeDecisionProvider()
        let selected = try await HostModelRouter().select(.init(
            conversation: snapshot,
            catalogRevision: catalogRevision,
            taskSummary: "Select a legal model configuration for a short answer.",
            latestInput: "Explain the selected configuration.",
            candidates: [candidate],
            currentCandidateID: "balanced",
            requirements: .init(allowsRemoteExecution: false),
            decisionProvider: decisionProvider,
            revisionReader: {
                let current = try await session.conversationSnapshot()
                return .init(conversation: current.revision, catalog: catalogRevision)
            }
        ))

        let run = try await session.run(
            "Explain the selected configuration.",
            using: selected.candidate.binding,
            expectedConversationRevision: snapshot.revision
        )
        let result = try await run.wait()
        try await run.waitForDrain()
        print("selection=\(selected.candidate.id) source=\(selected.source.rawValue)")
        print(result.response.content.compactMap { part in
            if case .text(let value) = part { return value }
            return nil
        }.joined())
        print("Decision advice never authorizes or executes tools.")
    }

    private static func makeDecisionProvider() throws -> any DecisionProvider {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SWIFT_AGENT_JEV_LIVE"] == "1" else {
            return FixtureDecisionProvider()
        }
        guard let apiKey = environment["TYPESAFE_API_KEY"], !apiKey.isEmpty else {
            throw ExampleError.missingJevCredential
        }
        return try JevDecisionProvider(
            apiKey: apiKey,
            model: environment["TYPESAFE_MODEL"] ?? "jev-latest"
        )
    }
}

private enum ExampleError: Error { case missingJevCredential }

private struct FixtureDecisionProvider: DecisionProvider {
    let descriptor = DecisionProviderDescriptor(id: "fixture-decision")

    func decide(_ request: DecisionRequest) async throws -> DecisionResponse {
        .init(model: "fixture-decision", choices: [
            "model": .init(
                selected: "balanced",
                confidence: 1,
                probabilities: [.init(name: "balanced", probability: 1)]
            ),
        ])
    }
}

private struct FixtureModelProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.streaming, .multiTurn])

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "fixture-response", model: request.model)
            let text = "The Host froze profile \(request.model.name) for this Run."
            try emit(.responseStarted(info))
            try emit(.textDelta(text))
            try emit(.responseCompleted(.init(info: info, content: [.text(text)], stopReason: .endTurn)))
        }
    }
}
