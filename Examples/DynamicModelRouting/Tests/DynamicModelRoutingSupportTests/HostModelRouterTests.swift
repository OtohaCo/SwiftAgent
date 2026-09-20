import AgentCatalog
import AgentCore
import AgentDecisions
import AgentModels
import Foundation
import Testing
@testable import DynamicModelRoutingSupport

struct HostModelRouterTests {
    @Test func manualLockSkipsClassifierAndSelectsTheConfiguredCandidate() async throws {
        let decision = DecisionProbe(selected: "remote")
        let local = try candidate("local", remote: false, inputRate: 4, cachedRate: 1)
        let remote = try candidate("remote", remote: true, inputRate: 1, cachedRate: 1)

        let result = try await HostModelRouter().select(.init(
            conversation: .init(revision: 4, messages: []),
            catalogRevision: "catalog-1",
            taskSummary: "Summarize locally",
            latestInput: "Continue",
            candidates: [local, remote],
            currentCandidateID: "local",
            manualCandidateID: "local",
            requirements: .init(allowsRemoteExecution: false),
            decisionProvider: decision,
            revisionReader: { .init(conversation: 4, catalog: "catalog-1") }
        ))

        #expect(result.candidate.id == "local")
        #expect(result.source == .manual)
        #expect(await decision.requestCount == 0)
    }

    @Test func decisionProviderReceivesOnlyLegalCandidateIDsAndCannotInventOne() async throws {
        let decision = DecisionProbe(selected: "invented")
        let local = try candidate("local", remote: false, tools: true)
        let remote = try candidate("remote", remote: true, tools: true)
        let noTools = try candidate("no-tools", remote: false, tools: false)

        await #expect(throws: HostModelRoutingError.invalidDecisionCandidate("invented")) {
            try await HostModelRouter().select(.init(
                conversation: .init(revision: 1, messages: [.user([.text("private")])]),
                catalogRevision: "catalog-1",
                taskSummary: "Use a tool",
                latestInput: "Look it up",
                candidates: [local, remote, noTools],
                currentCandidateID: nil,
                requirements: .init(requiresTools: true, allowsRemoteExecution: false),
                decisionProvider: decision,
                revisionReader: { .init(conversation: 1, catalog: "catalog-1") }
            ))
        }

        let request = try #require(await decision.requests.first)
        let names = try #require(request.choices["model"]?.criteria.map(\.name))
        #expect(names == ["local"])
        guard case .object(let state) = request.state else { Issue.record("Missing routing state"); return }
        #expect(state["latest_input"] == .string("Look it up"))
        #expect(state["conversation"] == nil)
    }

    @Test func remoteClassifierIsNotCalledWhenDataPolicyForbidsIt() async throws {
        let decision = DecisionProbe(selected: "remote")
        let local = try candidate("local", remote: false)

        let result = try await HostModelRouter().select(.init(
            conversation: .init(revision: 2, messages: []),
            catalogRevision: "catalog-1",
            taskSummary: "Private task",
            latestInput: "Sensitive text",
            candidates: [local],
            currentCandidateID: "local",
            requirements: .init(allowsRemoteClassifier: false),
            decisionProvider: decision,
            revisionReader: { .init(conversation: 2, catalog: "catalog-1") }
        ))

        #expect(result.candidate.id == "local")
        #expect(result.source == .current)
        #expect(await decision.requestCount == 0)
    }

    @Test func staleConversationOrCatalogRevisionRejectsTheDecision() async throws {
        let decision = DecisionProbe(selected: "local")
        let local = try candidate("local", remote: false)

        await #expect(throws: HostModelRoutingError.staleInput) {
            try await HostModelRouter().select(.init(
                conversation: .init(revision: 7, messages: []),
                catalogRevision: "catalog-1",
                taskSummary: "Route",
                latestInput: "Continue",
                candidates: [local],
                requirements: .init(),
                decisionProvider: decision,
                revisionReader: { .init(conversation: 8, catalog: "catalog-2") }
            ))
        }
    }

    @Test func classifierFailureFallsBackToTheCurrentLegalCandidate() async throws {
        let decision = DecisionProbe(error: FixtureDecisionError.offline)
        let current = try candidate("current", remote: false)
        let other = try candidate("other", remote: false)

        let result = try await HostModelRouter().select(.init(
            conversation: .init(revision: 3, messages: []),
            catalogRevision: "catalog-1",
            taskSummary: "Route",
            latestInput: "Continue",
            candidates: [current, other],
            currentCandidateID: "current",
            requirements: .init(),
            decisionProvider: decision,
            revisionReader: { .init(conversation: 3, catalog: "catalog-1") }
        ))

        #expect(result.candidate.id == "current")
        #expect(result.source == .current)
    }

    @Test func cachedCurrentModelCanBeCheaperThanALowerUncachedInputRate() async throws {
        let decision = DecisionProbe(selected: "uncached-cheap-rate")
        let cached = try candidate(
            "cached-current", remote: true, inputRate: 10, cachedRate: 0.5,
            forecast: .init(inputTokens: 100_000, cachedInputTokens: 90_000, outputTokens: 1_000)
        )
        let uncached = try candidate(
            "uncached-cheap-rate", remote: true, inputRate: 3, cachedRate: 3,
            forecast: .init(inputTokens: 100_000, cachedInputTokens: 0, outputTokens: 1_000)
        )

        let result = try await HostModelRouter(minimumSwitchSavings: 0.01).select(.init(
            conversation: .init(revision: 4, messages: []),
            catalogRevision: "catalog-1",
            taskSummary: "Route",
            latestInput: "Continue",
            candidates: [cached, uncached],
            currentCandidateID: "cached-current",
            requirements: .init(),
            decisionProvider: decision,
            revisionReader: { .init(conversation: 4, catalog: "catalog-1") }
        ))

        #expect(result.candidate.id == "cached-current")
        #expect(result.source == .current)
        #expect(result.estimatedCurrentCost != nil)
        #expect(result.estimatedSelectedCost != nil)
    }

    @Test func unknownCostDoesNotBecomeZeroOrClaimSavings() async throws {
        let decision = DecisionProbe(selected: "unknown")
        let current = try candidate("current", remote: false, inputRate: 4, cachedRate: 1)
        let unknown = try candidate("unknown", remote: false, inputRate: nil, cachedRate: nil)

        let result = try await HostModelRouter().select(.init(
            conversation: .init(revision: 5, messages: []),
            catalogRevision: "catalog-1",
            taskSummary: "Route",
            latestInput: "Continue",
            candidates: [current, unknown],
            currentCandidateID: "current",
            requirements: .init(),
            decisionProvider: decision,
            revisionReader: { .init(conversation: 5, catalog: "catalog-1") }
        ))

        #expect(result.candidate.id == "current")
        #expect(result.estimatedSelectedCost == nil)
    }

    @Test func cooldownKeepsTheCurrentLegalCandidate() async throws {
        let decision = DecisionProbe(selected: "other")
        let current = try candidate("current", remote: false, inputRate: 10, cachedRate: 10)
        let other = try candidate("other", remote: false, inputRate: 1, cachedRate: 1)

        let result = try await HostModelRouter(
            minimumTurnsBetweenSwitches: 3
        ).select(.init(
            conversation: .init(revision: 6, messages: []),
            catalogRevision: "catalog-1",
            taskSummary: "Route",
            latestInput: "Continue",
            candidates: [current, other],
            currentCandidateID: "current",
            requirements: .init(),
            turnsSinceLastSwitch: 1,
            decisionProvider: decision,
            revisionReader: { .init(conversation: 6, catalog: "catalog-1") }
        ))

        #expect(result.candidate.id == "current")
        #expect(result.source == .current)
    }

    @Test func invalidCandidateIDFailsBeforeRemoteDecision() async throws {
        let decision = DecisionProbe(selected: "bad\nid")
        let valid = try candidate("valid", remote: false)
        let malformed = HostModelCandidate(
            id: "bad\nid",
            binding: valid.binding,
            catalogEntry: valid.catalogEntry,
            isRemote: valid.isRemote,
            adapterCanEncodeConfiguration: valid.adapterCanEncodeConfiguration,
            automaticSelectionAllowed: valid.automaticSelectionAllowed,
            routingDescription: valid.routingDescription,
            forecast: valid.forecast,
            pricing: valid.pricing
        )

        await #expect(throws: HostModelRoutingError.invalidCandidateID("bad\nid")) {
            try await HostModelRouter().select(.init(
                conversation: .init(revision: 1, messages: []),
                catalogRevision: "catalog-1",
                taskSummary: "Route",
                latestInput: "Continue",
                candidates: [valid, malformed],
                requirements: .init(),
                decisionProvider: decision,
                revisionReader: { .init(conversation: 1, catalog: "catalog-1") }
            ))
        }
        #expect(await decision.requestCount == 0)
    }

    @Test func catalogEntryMustMatchBindingIdentity() async throws {
        let local = try candidate("local", remote: false)
        let other = try candidate("other", remote: false)
        let mismatched = HostModelCandidate(
            id: "local",
            binding: local.binding,
            catalogEntry: other.catalogEntry,
            isRemote: local.isRemote,
            adapterCanEncodeConfiguration: true,
            automaticSelectionAllowed: true,
            forecast: local.forecast,
            pricing: local.pricing
        )

        await #expect(throws: HostModelRoutingError.invalidManualCandidate("local")) {
            try await HostModelRouter().select(.init(
                conversation: .init(revision: 1, messages: []),
                catalogRevision: "catalog-1",
                taskSummary: "Route",
                latestInput: "Continue",
                candidates: [mismatched],
                manualCandidateID: "local",
                requirements: .init(),
                revisionReader: { .init(conversation: 1, catalog: "catalog-1") }
            ))
        }
    }
}

private actor DecisionProbe: DecisionProvider {
    nonisolated let descriptor = DecisionProviderDescriptor(id: "fixture-decision")
    private let selected: String?
    private let error: (any Error)?
    private(set) var requests: [DecisionRequest] = []
    var requestCount: Int { requests.count }

    init(selected: String? = nil, error: (any Error)? = nil) {
        self.selected = selected
        self.error = error
    }

    func decide(_ request: DecisionRequest) async throws -> DecisionResponse {
        requests.append(request)
        if let error { throw error }
        let selected = try #require(selected)
        return .init(model: "fixture", choices: [
            "model": .init(selected: selected, confidence: 0.9, probabilities: []),
        ])
    }
}

private enum FixtureDecisionError: Error { case offline }

private func candidate(
    _ id: String,
    remote: Bool,
    tools: Bool = true,
    inputRate: Decimal? = 4,
    cachedRate: Decimal? = 1,
    forecast: RoutingUsageForecast = .init(inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 100)
) throws -> HostModelCandidate {
    let scope = try ModelServiceScope(
        provider: "fixture",
        serviceInstanceID: id,
        endpointScope: "https://\(id).example.test/v1",
        apiDialect: "fixture"
    )
    return .init(
        id: id,
        binding: try .init(
            profileID: id,
            profileRevision: "1",
            model: .init(provider: "fixture", name: id),
            provider: FixtureModelProvider(),
            deployment: .init(
                serviceInstanceID: id,
                endpointScope: scope.endpointScope,
                apiDialect: scope.apiDialect
            )
        ),
        catalogEntry: .init(
            model: .init(provider: "fixture", name: id),
            deploymentID: id,
            serviceScope: scope,
            capabilities: .init(
                multiTurn: .supported,
                tools: tools ? .supported : .unsupported,
                structuredOutput: .supported,
                reasoning: .supported,
                configurableReasoning: .supported
            ),
            sources: [.init(kind: .hostOverride)]
        ),
        isRemote: remote,
        adapterCanEncodeConfiguration: true,
        automaticSelectionAllowed: true,
        forecast: forecast,
        pricing: inputRate.map { input in
            .init(
                inputPerMillion: input,
                cachedInputPerMillion: cachedRate,
                outputPerMillion: 12,
                currency: "USD",
                source: "fixture",
                asOf: Date(timeIntervalSince1970: 0)
            )
        }
    )
}

private struct FixtureModelProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.multiTurn, .tools, .structuredOutput])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
