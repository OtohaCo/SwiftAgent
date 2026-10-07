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
            forecast: .init(inputTokens: 100_000, cachedInputTokens: 90_000, cacheWriteInputTokens: 0, outputTokens: 1_000)
        )
        let uncached = try candidate(
            "uncached-cheap-rate", remote: true, inputRate: 3, cachedRate: 3,
            forecast: .init(inputTokens: 100_000, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 1_000)
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

    // Test-only tariff; these numbers are not a provider price list.
    @Test func disjointCacheWritePricingAndColdRequests() async throws {
        for (read, write, expected) in [(12_000, 3_000, "0.00515"), (0, 15_000, "0.01895"),
                                       (0, 3_000, "0.01595"), (0, 0, "0.0152"), (12_000, 0, "0.0044")] {
            let value = try candidate("priced", remote: false, inputRate: 1, cachedRate: Decimal(string: "0.1"),
                writeRate: Decimal(string: "1.25"), outputRate: 2,
                forecast: .init(inputTokens: 15_000, cachedInputTokens: read,
                    cacheWriteInputTokens: write, outputTokens: 100))
            #expect(try await cost(value) == Decimal(string: expected))
        }
    }

    @Test func explicitZeroNeedsNoWriteQuoteButUnknownDoes() async throws {
        let zero = try candidate("zero", remote: false, inputRate: 1, cachedRate: nil, outputRate: 2,
            forecast: .init(inputTokens: 15_000, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 100))
        #expect(try await cost(zero) == Decimal(string: "0.0152"))
        for (read, write) in [(Optional(0), Optional<Int>.none), (0, 3_000), (nil, 0)] {
            let unknown = try candidate("unknown", remote: false, inputRate: 1, outputRate: 2,
                forecast: .init(inputTokens: 15_000, cachedInputTokens: read,
                    cacheWriteInputTokens: write, outputTokens: 100))
            #expect(try await cost(unknown) == nil)
        }
        let notApplicable = try candidate("verified-tariff", remote: false, inputRate: 1, outputRate: 2,
            writeScope: .noSeparateCharge,
            forecast: .init(inputTokens: 15_000, cachedInputTokens: 0, outputTokens: 100))
        #expect(try await cost(notApplicable) == Decimal(string: "0.0152"))
    }

    @Test func invalidCountsClassificationAndDecimalOverflowRemainUnknown() async throws {
        for forecast in [
            RoutingUsageForecast(inputTokens: -1, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0),
            .init(inputTokens: 10, cachedInputTokens: -1, cacheWriteInputTokens: 0, outputTokens: 0),
            .init(inputTokens: 10, cachedInputTokens: 0, cacheWriteInputTokens: -1, outputTokens: 0),
            .init(inputTokens: 10, cachedInputTokens: 8, cacheWriteInputTokens: 3, outputTokens: 0),
            .init(inputTokens: Int.max, cachedInputTokens: Int.max, cacheWriteInputTokens: Int.max, outputTokens: 0),
            .init(inputTokens: 10, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: -1),
        ] {
            #expect(try await cost(candidate("invalid", remote: false, writeRate: 1, forecast: forecast)) == nil)
        }
        for rate in [Decimal(-1), Decimal.nan, Decimal.greatestFiniteMagnitude] {
            let value = try candidate("invalid-rate", remote: false, inputRate: rate,
                forecast: .init(inputTokens: Int.max, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0))
            #expect(try await cost(value) == nil)
        }
    }

    @Test func candidateWriteForecastsStayIndependentAndUnknownCannotJustifyASwitch() async throws {
        let current = try candidate("current", remote: false, inputRate: 1, cachedRate: Decimal(string: "0.1"),
            writeRate: Decimal(string: "1.25"), outputRate: 2,
            forecast: .init(inputTokens: 15_000, cachedInputTokens: 12_000, cacheWriteInputTokens: 3_000, outputTokens: 100))
        for (write, rate) in [(Optional(15_000), Decimal(string: "1.25")), (nil, Decimal(string: "1.25")), (15_000, nil)] {
            let other = try candidate("other", remote: false, inputRate: 1, cachedRate: Decimal(string: "0.1"),
                writeRate: rate, outputRate: 2,
                forecast: .init(inputTokens: 15_000, cachedInputTokens: 0, cacheWriteInputTokens: write, outputTokens: 100))
            let result = try await HostModelRouter().select(.init(
                conversation: .init(revision: 1, messages: []), catalogRevision: "1", taskSummary: "Route",
                latestInput: "Continue", candidates: [current, other], currentCandidateID: "current",
                requirements: .init(), decisionProvider: DecisionProbe(selected: "other"),
                revisionReader: { .init(conversation: 1, catalog: "1") }))
            #expect(result.candidate.id == "current")
            #expect(result.estimatedCurrentCost == Decimal(string: "0.00515"))
            #expect(result.estimatedSelectedCost == (write == nil || rate == nil ? nil : Decimal(string: "0.01895")))
        }
    }

    @Test func mixedTTLForecastUsesEachVerifiedRateAndReportsWhyCostIsUnknown() throws {
        // Test-only quote: 5m 1.25, 1h 2; not a provider's current prices.
        let mixed = try candidate("mixed", remote: false, inputRate: 1, cachedRate: Decimal(string: "0.1"),
            outputRate: 2, writeScope: .ttlBreakdown,
            ttlRates: .init(fiveMinutePerMillion: Decimal(string: "1.25"), oneHourPerMillion: 2),
            forecast: .init(inputTokens: 15_000, cachedInputTokens: 12_000, cacheWriteInputTokens: 3_000,
                outputTokens: 100, cacheWriteTTL: .init(fiveMinuteTokens: 2_000, oneHourTokens: 1_000)))
        let router = HostModelRouter()
        #expect(router.costEstimate(for: mixed).value == Decimal(string: "0.0059"))
        #expect(router.costEstimate(for: mixed).unknownReason == nil)
        for (detail, rates, reason) in [
            (CacheWriteTTLUsage(fiveMinuteTokens: 2_000), CacheWriteTTLPrices(fiveMinutePerMillion: Decimal(string: "1.25"), oneHourPerMillion: 2), HostCostUnknownReason.missingTTLUsage),
            (.init(fiveMinuteTokens: 2_000, oneHourTokens: 1_000), .init(fiveMinutePerMillion: Decimal(string: "1.25")), .missingWritePrice),
            (.init(fiveMinuteTokens: 2_000, oneHourTokens: 2_000), .init(fiveMinutePerMillion: Decimal(string: "1.25"), oneHourPerMillion: 2), .invalidClassification),
            (.init(fiveMinuteTokens: -1, oneHourTokens: 3_001), .init(), .invalidCount),
            (.init(fiveMinuteTokens: Int.max, oneHourTokens: 1), .init(), .arithmeticOverflow),
        ] {
            let value = try candidate("unknown", remote: false, inputRate: 1, cachedRate: Decimal(string: "0.1"),
                outputRate: 2, writeScope: .ttlBreakdown, ttlRates: rates,
                forecast: .init(inputTokens: reason == .arithmeticOverflow ? Int.max : 15_000,
                    cachedInputTokens: reason == .arithmeticOverflow ? 0 : 12_000,
                    cacheWriteInputTokens: reason == .arithmeticOverflow ? Int.max : 3_000,
                    outputTokens: 100, cacheWriteTTL: detail))
            #expect(router.costEstimate(for: value).value == nil)
            #expect(router.costEstimate(for: value).unknownReason == reason)
        }
        let zero = try candidate("zero-ttl", remote: false, inputRate: 1, cachedRate: nil,
            outputRate: 2, writeScope: .ttlBreakdown, ttlRates: .init(),
            forecast: .init(inputTokens: 15_000, cachedInputTokens: 0, cacheWriteInputTokens: 0,
                outputTokens: 100, cacheWriteTTL: .init(fiveMinuteTokens: 0, oneHourTokens: 0)))
        #expect(router.costEstimate(for: zero).value == Decimal(string: "0.0152"))
        let fiveOnly = try candidate("five-only", remote: false, inputRate: 1, cachedRate: nil,
            outputRate: 2, writeScope: .ttlBreakdown, ttlRates: .init(fiveMinutePerMillion: Decimal(string: "1.25")),
            forecast: .init(inputTokens: 15_000, cachedInputTokens: 0, cacheWriteInputTokens: 15_000,
                outputTokens: 100, cacheWriteTTL: .init(fiveMinuteTokens: 15_000, oneHourTokens: 0)))
        #expect(router.costEstimate(for: fiveOnly).value == Decimal(string: "0.01895"))
    }

    @Test func routingResultCarriesMissingCostReasonAndDifferentCurrenciesNeverProveSavings() async throws {
        let unknown = try candidate("unknown-result", remote: false,
            forecast: .init(inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 100))
        let result = try await HostModelRouter().select(.init(
            conversation: .init(revision: 1, messages: []), catalogRevision: "1", taskSummary: "Price",
            latestInput: "Continue", candidates: [unknown], manualCandidateID: unknown.id,
            requirements: .init(), revisionReader: { .init(conversation: 1, catalog: "1") }))
        #expect(result.estimatedSelectedCost == nil)
        #expect(result.estimatedSelectedCostUnknownReason == .missingWriteUsage)
        let current = try candidate("usd", remote: false, inputRate: 10, currency: "USD")
        let other = try candidate("eur", remote: false, inputRate: 1, currency: "EUR")
        let kept = try await HostModelRouter().select(.init(
            conversation: .init(revision: 1, messages: []), catalogRevision: "1", taskSummary: "Route",
            latestInput: "Continue", candidates: [current, other], currentCandidateID: current.id,
            requirements: .init(), decisionProvider: DecisionProbe(selected: other.id),
            revisionReader: { .init(conversation: 1, catalog: "1") }))
        #expect(kept.candidate.id == current.id)
    }

    @Test func ttlRatesQuoteScopeAndLegacyInitializerReferencesAreValidated() throws {
        let forecastInitializer: (Int, Int?, Int?, Int) -> RoutingUsageForecast = RoutingUsageForecast.init
        let quoteInitializer: (Decimal, Decimal?, Decimal?, CacheWritePricingScope, Decimal, String, String, Date) -> HostPricingQuote = HostPricingQuote.init
        #expect(forecastInitializer(1, 0, 0, 0).cacheWriteTTL == nil)
        #expect(quoteInitializer(1, nil, nil, .singleCategory, 2, "USD", "test-only", Date(timeIntervalSince1970: 0)).cacheWriteTTLPrices == nil)
        for rate in [Decimal(-1), Decimal.nan, Decimal.greatestFiniteMagnitude] {
            let value = try candidate("bad-ttl-rate", remote: false, inputRate: 1, cachedRate: nil,
                writeScope: .ttlBreakdown, ttlRates: .init(oneHourPerMillion: rate),
                forecast: .init(inputTokens: Int.max, cachedInputTokens: 0, cacheWriteInputTokens: Int.max,
                    outputTokens: 0, cacheWriteTTL: .init(fiveMinuteTokens: 0, oneHourTokens: Int.max)))
            #expect(HostModelRouter().costEstimate(for: value).value == nil)
        }
        let invalidVerifiedTariff = try candidate("invalid-no-write-fee", remote: false, writeScope: .noSeparateCharge,
            forecast: .init(inputTokens: 10, cachedInputTokens: 8, outputTokens: 0,
                cacheWriteTTL: .init(fiveMinuteTokens: 2, oneHourTokens: 1)))
        #expect(HostModelRouter().costEstimate(for: invalidVerifiedTariff).unknownReason == .invalidClassification)
        let mismatch = try candidate("quoted-model", remote: false, ttlRates: .init(),
            quoteModel: .init(provider: "fixture", name: "different-model"))
        #expect(HostModelRouter().costEstimate(for: mismatch).unknownReason == .invalidQuote)
    }

    private func cost(_ candidate: HostModelCandidate) async throws -> Decimal? {
        try await HostModelRouter().select(.init(
            conversation: .init(revision: 1, messages: []), catalogRevision: "1", taskSummary: "Price",
            latestInput: "Continue", candidates: [candidate], manualCandidateID: candidate.id,
            requirements: .init(), revisionReader: { .init(conversation: 1, catalog: "1") }
        )).estimatedSelectedCost
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
    writeRate: Decimal? = nil,
    outputRate: Decimal = 12,
    writeScope: CacheWritePricingScope = .singleCategory,
    ttlRates: CacheWriteTTLPrices? = nil,
    currency: String = "USD",
    quoteModel: ModelID? = nil,
    forecast: RoutingUsageForecast = .init(inputTokens: 1_000, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 100)
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
            if let ttlRates {
                return HostPricingQuote(inputPerMillion: input, cachedInputPerMillion: cachedRate,
                    cacheWriteInputPerMillion: writeRate, cacheWriteScope: writeScope,
                    outputPerMillion: outputRate, currency: currency, source: "fixture", asOf: Date(timeIntervalSince1970: 0),
                    cacheWriteTTLPrices: ttlRates, model: quoteModel)
            }
            return HostPricingQuote(inputPerMillion: input, cachedInputPerMillion: cachedRate,
                cacheWriteInputPerMillion: writeRate, cacheWriteScope: writeScope,
                outputPerMillion: outputRate, currency: currency, source: "fixture", asOf: Date(timeIntervalSince1970: 0))
        }
    )
}

private struct FixtureModelProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.multiTurn, .tools, .structuredOutput])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
