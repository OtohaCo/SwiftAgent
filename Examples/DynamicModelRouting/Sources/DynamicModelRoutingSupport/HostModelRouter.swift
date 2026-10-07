import AgentCatalog
import AgentCore
import AgentDecisions
import AgentModels
import Foundation

public struct HostRoutingRequirements: Hashable, Sendable {
    public let requiresTools: Bool
    public let requiresStructuredOutput: Bool
    public let requiresReasoning: Bool
    public let allowsRemoteExecution: Bool
    public let allowsRemoteClassifier: Bool

    public init(
        requiresTools: Bool = false,
        requiresStructuredOutput: Bool = false,
        requiresReasoning: Bool = false,
        allowsRemoteExecution: Bool = true,
        allowsRemoteClassifier: Bool = true
    ) {
        self.requiresTools = requiresTools
        self.requiresStructuredOutput = requiresStructuredOutput
        self.requiresReasoning = requiresReasoning
        self.allowsRemoteExecution = allowsRemoteExecution
        self.allowsRemoteClassifier = allowsRemoteClassifier
    }
}

public struct RoutingUsageForecast: Hashable, Sendable {
    public let inputTokens: Int
    public let cachedInputTokens: Int?
    /// Host prediction, not a measured response. Nil means unknown.
    public let cacheWriteInputTokens: Int?
    public let outputTokens: Int

    public init(inputTokens: Int, cachedInputTokens: Int?, cacheWriteInputTokens: Int? = nil, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
    }
}

/// The Host must verify this scope for the candidate's model, endpoint and tariff.
public enum CacheWritePricingScope: Hashable, Sendable {
    /// One disjoint write category with one rate; mixed TTL tariffs are not covered.
    case singleCategory
    /// Verified protocol/tariff bills writes as ordinary input, without a separate category.
    case noSeparateCharge
}

public struct HostPricingQuote: Hashable, Sendable {
    public let inputPerMillion: Decimal
    public let cachedInputPerMillion: Decimal?
    public let cacheWriteInputPerMillion: Decimal?
    public let cacheWriteScope: CacheWritePricingScope
    public let outputPerMillion: Decimal
    public let currency: String
    public let source: String
    public let asOf: Date

    public init(
        inputPerMillion: Decimal,
        cachedInputPerMillion: Decimal?,
        cacheWriteInputPerMillion: Decimal? = nil,
        cacheWriteScope: CacheWritePricingScope = .singleCategory,
        outputPerMillion: Decimal,
        currency: String,
        source: String,
        asOf: Date
    ) {
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.cacheWriteInputPerMillion = cacheWriteInputPerMillion
        self.cacheWriteScope = cacheWriteScope
        self.outputPerMillion = outputPerMillion
        self.currency = currency
        self.source = source
        self.asOf = asOf
    }
}

public struct HostModelCandidate: Sendable {
    public let id: String
    public let binding: AgentModelBinding
    public let catalogEntry: ModelCatalogEntry?
    public let isRemote: Bool
    public let adapterCanEncodeConfiguration: Bool
    public let automaticSelectionAllowed: Bool
    public let routingDescription: String?
    public let forecast: RoutingUsageForecast?
    public let pricing: HostPricingQuote?

    public init(
        id: String,
        binding: AgentModelBinding,
        catalogEntry: ModelCatalogEntry?,
        isRemote: Bool,
        adapterCanEncodeConfiguration: Bool,
        automaticSelectionAllowed: Bool,
        routingDescription: String? = nil,
        forecast: RoutingUsageForecast? = nil,
        pricing: HostPricingQuote? = nil
    ) {
        self.id = id
        self.binding = binding
        self.catalogEntry = catalogEntry
        self.isRemote = isRemote
        self.adapterCanEncodeConfiguration = adapterCanEncodeConfiguration
        self.automaticSelectionAllowed = automaticSelectionAllowed
        self.routingDescription = routingDescription
        self.forecast = forecast
        self.pricing = pricing
    }
}

public struct HostRoutingRevision: Hashable, Sendable {
    public let conversation: UInt64
    public let catalog: String

    public init(conversation: UInt64, catalog: String) {
        self.conversation = conversation
        self.catalog = catalog
    }
}

public struct HostModelRoutingInput: Sendable {
    public let conversation: AgentConversationSnapshot
    public let catalogRevision: String
    public let taskSummary: String
    public let latestInput: String
    public let candidates: [HostModelCandidate]
    public let currentCandidateID: String?
    public let manualCandidateID: String?
    public let requirements: HostRoutingRequirements
    public let turnsSinceLastSwitch: Int?
    public let decisionDeadline: ContinuousClock.Instant?
    public let decisionProvider: (any DecisionProvider)?
    public let revisionReader: @Sendable () async throws -> HostRoutingRevision

    public init(
        conversation: AgentConversationSnapshot,
        catalogRevision: String,
        taskSummary: String,
        latestInput: String,
        candidates: [HostModelCandidate],
        currentCandidateID: String? = nil,
        manualCandidateID: String? = nil,
        requirements: HostRoutingRequirements,
        turnsSinceLastSwitch: Int? = nil,
        decisionDeadline: ContinuousClock.Instant? = nil,
        decisionProvider: (any DecisionProvider)? = nil,
        revisionReader: @escaping @Sendable () async throws -> HostRoutingRevision
    ) {
        self.conversation = conversation
        self.catalogRevision = catalogRevision
        self.taskSummary = taskSummary
        self.latestInput = latestInput
        self.candidates = candidates
        self.currentCandidateID = currentCandidateID
        self.manualCandidateID = manualCandidateID
        self.requirements = requirements
        self.turnsSinceLastSwitch = turnsSinceLastSwitch
        self.decisionDeadline = decisionDeadline
        self.decisionProvider = decisionProvider
        self.revisionReader = revisionReader
    }
}

public struct HostRoutingSelectionSource: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let manual = Self(rawValue: "manual")
    public static let decision = Self(rawValue: "decision")
    public static let current = Self(rawValue: "current")
    public static let fallback = Self(rawValue: "fallback")
}

public struct HostModelRoutingResult: Sendable {
    public let candidate: HostModelCandidate
    public let source: HostRoutingSelectionSource
    public let estimatedCurrentCost: Decimal?
    public let estimatedSelectedCost: Decimal?

    public init(
        candidate: HostModelCandidate,
        source: HostRoutingSelectionSource,
        estimatedCurrentCost: Decimal?,
        estimatedSelectedCost: Decimal?
    ) {
        self.candidate = candidate
        self.source = source
        self.estimatedCurrentCost = estimatedCurrentCost
        self.estimatedSelectedCost = estimatedSelectedCost
    }
}

public enum HostModelRoutingError: Error, Equatable, Sendable {
    case noLegalCandidate
    case invalidCandidateID(String)
    case invalidManualCandidate(String)
    case invalidDecisionCandidate(String)
    case staleInput
}

/// Example-only Host coordinator. It never owns AgentLoop or tool execution.
public struct HostModelRouter: Sendable {
    public let minimumSwitchSavings: Decimal
    public let minimumTurnsBetweenSwitches: Int

    public init(minimumSwitchSavings: Decimal = 0, minimumTurnsBetweenSwitches: Int = 0) {
        self.minimumSwitchSavings = minimumSwitchSavings
        self.minimumTurnsBetweenSwitches = max(0, minimumTurnsBetweenSwitches)
    }

    public func select(_ input: HostModelRoutingInput) async throws -> HostModelRoutingResult {
        try validateCandidateIDs(input.candidates)
        let current = input.currentCandidateID.flatMap { id in input.candidates.first { $0.id == id } }

        if let manualID = input.manualCandidateID {
            guard let manual = input.candidates.first(where: { $0.id == manualID }),
                  manuallyLegal(manual, requirements: input.requirements) else {
                throw HostModelRoutingError.invalidManualCandidate(manualID)
            }
            try await validateRevision(input)
            return result(manual, source: .manual, current: current)
        }

        let legal = input.candidates.filter { automaticallyLegal($0, requirements: input.requirements) }
        guard !legal.isEmpty else { throw HostModelRoutingError.noLegalCandidate }
        let legalCurrent = current.flatMap { candidate in legal.first { $0.id == candidate.id } }

        guard input.requirements.allowsRemoteClassifier, let decisionProvider = input.decisionProvider else {
            try await validateRevision(input)
            return result(legalCurrent ?? legal[0], source: legalCurrent == nil ? .fallback : .current, current: current)
        }

        let selectedID: String
        do {
            let response = try await decisionProvider.decide(try decisionRequest(input: input, candidates: legal))
            guard let selected = response.choices["model"]?.selected else {
                throw HostModelRoutingError.invalidDecisionCandidate("<missing>")
            }
            selectedID = selected
        } catch let error as HostModelRoutingError {
            throw error
        } catch {
            try await validateRevision(input)
            return result(legalCurrent ?? legal[0], source: legalCurrent == nil ? .fallback : .current, current: current)
        }

        guard let selected = legal.first(where: { $0.id == selectedID }) else {
            throw HostModelRoutingError.invalidDecisionCandidate(selectedID)
        }
        try await validateRevision(input)

        guard let legalCurrent, legalCurrent.id != selected.id else {
            return result(selected, source: .decision, current: current)
        }
        if let turns = input.turnsSinceLastSwitch, turns < minimumTurnsBetweenSwitches {
            return result(legalCurrent, source: .current, current: current)
        }
        let currentCost = estimatedCost(legalCurrent)
        let selectedCost = estimatedCost(selected)
        guard let currentCost, let selectedCost,
              legalCurrent.pricing?.currency == selected.pricing?.currency,
              let switchCost = add(selectedCost, minimumSwitchSavings),
              switchCost < currentCost else {
            return .init(
                candidate: legalCurrent,
                source: .current,
                estimatedCurrentCost: currentCost,
                estimatedSelectedCost: selectedCost
            )
        }
        return .init(
            candidate: selected,
            source: .decision,
            estimatedCurrentCost: currentCost,
            estimatedSelectedCost: selectedCost
        )
    }

    private func manuallyLegal(_ candidate: HostModelCandidate, requirements: HostRoutingRequirements) -> Bool {
        guard candidateIdentityMatchesCatalog(candidate),
              candidate.adapterCanEncodeConfiguration,
              requirements.allowsRemoteExecution || !candidate.isRemote else { return false }
        guard let catalog = candidate.catalogEntry else { return true }
        return supports(catalog, requirements: requirements, unknownIsAllowed: true)
    }

    private func automaticallyLegal(_ candidate: HostModelCandidate, requirements: HostRoutingRequirements) -> Bool {
        guard candidateIdentityMatchesCatalog(candidate),
              candidate.adapterCanEncodeConfiguration,
              candidate.automaticSelectionAllowed,
              requirements.allowsRemoteExecution || !candidate.isRemote,
              let catalog = candidate.catalogEntry else { return false }
        return supports(catalog, requirements: requirements, unknownIsAllowed: false)
    }

    private func validateCandidateIDs(_ candidates: [HostModelCandidate]) throws {
        var seen = Set<String>()
        for candidate in candidates {
            guard !candidate.id.isEmpty,
                  candidate.id == candidate.id.trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(candidate.id).inserted else {
                throw HostModelRoutingError.invalidCandidateID(candidate.id)
            }
        }
    }

    private func candidateIdentityMatchesCatalog(_ candidate: HostModelCandidate) -> Bool {
        guard let catalog = candidate.catalogEntry else { return true }
        let deployment = candidate.binding.deployment
        let scope = catalog.serviceScope
        return catalog.model == candidate.binding.model
            && scope.provider == candidate.binding.model.provider
            && scope.serviceInstanceID == deployment.serviceInstanceID
            && scope.endpointScope == deployment.endpointScope
            && scope.apiDialect == deployment.apiDialect
            && scope.apiVersion == deployment.apiVersion
    }

    private func supports(
        _ catalog: ModelCatalogEntry,
        requirements: HostRoutingRequirements,
        unknownIsAllowed: Bool
    ) -> Bool {
        func accepted(_ support: ModelCatalogSupport) -> Bool {
            support == .supported || (unknownIsAllowed && support == .unknown)
        }
        if requirements.requiresTools, !accepted(catalog.capabilities.tools) { return false }
        if requirements.requiresStructuredOutput, !accepted(catalog.capabilities.structuredOutput) { return false }
        if requirements.requiresReasoning, !accepted(catalog.capabilities.reasoning) { return false }
        return true
    }

    private func decisionRequest(
        input: HostModelRoutingInput,
        candidates: [HostModelCandidate]
    ) throws -> DecisionRequest {
        try .init(
            state: .object([
                "task_summary": .string(input.taskSummary),
                "latest_input": .string(input.latestInput),
                "candidate_ids": .array(candidates.map { .string($0.id) }),
            ]),
            choices: [
                "model": try .init(
                    instructions: .string("Recommend one candidate ID. This is advice, not authorization."),
                    criteria: candidates.map { candidate in
                        .init(
                            name: candidate.id,
                            description: candidate.routingDescription.map(JSONValue.string)
                        )
                    }
                ),
            ],
            deadline: input.decisionDeadline
        )
    }

    private func validateRevision(_ input: HostModelRoutingInput) async throws {
        let current = try await input.revisionReader()
        guard current.conversation == input.conversation.revision,
              current.catalog == input.catalogRevision else {
            throw HostModelRoutingError.staleInput
        }
    }

    private func result(
        _ selected: HostModelCandidate,
        source: HostRoutingSelectionSource,
        current: HostModelCandidate?
    ) -> HostModelRoutingResult {
        .init(
            candidate: selected,
            source: source,
            estimatedCurrentCost: current.flatMap(estimatedCost),
            estimatedSelectedCost: estimatedCost(selected)
        )
    }

    private func estimatedCost(_ candidate: HostModelCandidate) -> Decimal? {
        guard let usage = candidate.forecast, let pricing = candidate.pricing,
              usage.inputTokens >= 0, usage.outputTokens >= 0,
              let cached = usage.cachedInputTokens, cached >= 0, cached <= usage.inputTokens,
              pricing.inputPerMillion >= 0, pricing.outputPerMillion >= 0 else { return nil }
        let remaining = usage.inputTokens - cached
        if let written = usage.cacheWriteInputTokens, written < 0 || written > remaining { return nil }
        let written: Int
        let writeRate: Decimal
        switch pricing.cacheWriteScope {
        case .noSeparateCharge:
            // This explicit Host assertion permits unknown write counts because all
            // non-read input uses the ordinary rate under this verified tariff.
            written = 0
            writeRate = 0
        case .singleCategory:
            guard let count = usage.cacheWriteInputTokens else { return nil }
            written = count
            if count == 0 { writeRate = 0 }
            else if let rate = pricing.cacheWriteInputPerMillion, rate >= 0 { writeRate = rate }
            else { return nil }
        }
        let cachedRate: Decimal
        if cached == 0 { cachedRate = 0 }
        else if let rate = pricing.cachedInputPerMillion, rate >= 0 { cachedRate = rate }
        else { return nil }
        guard let ordinaryCost = multiply(Decimal(remaining - written), pricing.inputPerMillion),
              let cachedCost = multiply(Decimal(cached), cachedRate),
              let writeCost = multiply(Decimal(written), writeRate),
              let outputCost = multiply(Decimal(usage.outputTokens), pricing.outputPerMillion),
              let readAndOrdinaryCost = add(ordinaryCost, cachedCost),
              let inputCost = add(readAndOrdinaryCost, writeCost),
              var tokenCost = add(inputCost, outputCost) else { return nil }
        var million = Decimal(1_000_000)
        var result = Decimal()
        return NSDecimalDivide(&result, &tokenCost, &million, .plain) == .noError ? result : nil
    }

    private func multiply(_ lhs: Decimal, _ rhs: Decimal) -> Decimal? {
        var lhs = lhs
        var rhs = rhs
        var result = Decimal()
        return NSDecimalMultiply(&result, &lhs, &rhs, .plain) == .noError ? result : nil
    }

    private func add(_ lhs: Decimal, _ rhs: Decimal) -> Decimal? {
        var lhs = lhs
        var rhs = rhs
        var result = Decimal()
        return NSDecimalAdd(&result, &lhs, &rhs, .plain) == .noError ? result : nil
    }
}
