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
    public let cacheWriteTTL: CacheWriteTTLUsage?

    public init(inputTokens: Int, cachedInputTokens: Int?, cacheWriteInputTokens: Int? = nil, outputTokens: Int) {
        self.init(inputTokens: inputTokens, cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens, outputTokens: outputTokens, cacheWriteTTL: nil)
    }

    public init(inputTokens: Int, cachedInputTokens: Int?, cacheWriteInputTokens: Int? = nil,
                outputTokens: Int, cacheWriteTTL: CacheWriteTTLUsage?) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTTL = cacheWriteTTL
    }
}

/// The Host must verify this scope for the candidate's model, endpoint and tariff.
public enum CacheWritePricingScope: Hashable, Sendable {
    /// One disjoint write category with one rate.
    case singleCategory
    /// Complete mutually exclusive 5m and 1h categories with their own rates.
    case ttlBreakdown
    /// Verified protocol/tariff bills writes as ordinary input, without a separate category.
    case noSeparateCharge
}

public struct CacheWriteTTLPrices: Hashable, Sendable {
    public let fiveMinutePerMillion: Decimal?
    public let oneHourPerMillion: Decimal?

    public init(fiveMinutePerMillion: Decimal? = nil, oneHourPerMillion: Decimal? = nil) {
        self.fiveMinutePerMillion = fiveMinutePerMillion
        self.oneHourPerMillion = oneHourPerMillion
    }
}

public enum HostCostUnknownReason: String, Hashable, Sendable {
    case missingForecast, missingQuote, missingReadUsage, missingWriteUsage, missingTTLUsage
    case missingReadPrice, missingWritePrice, invalidCount, invalidClassification, invalidPrice, invalidQuote, arithmeticOverflow
}

public struct HostCostEstimate: Hashable, Sendable {
    public let value: Decimal?
    public let unknownReason: HostCostUnknownReason?
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
    public let cacheWriteTTLPrices: CacheWriteTTLPrices?
    public let model: ModelID?

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
        self.init(inputPerMillion: inputPerMillion, cachedInputPerMillion: cachedInputPerMillion,
            cacheWriteInputPerMillion: cacheWriteInputPerMillion, cacheWriteScope: cacheWriteScope,
            outputPerMillion: outputPerMillion, currency: currency, source: source, asOf: asOf,
            cacheWriteTTLPrices: nil)
    }

    public init(
        inputPerMillion: Decimal,
        cachedInputPerMillion: Decimal?,
        cacheWriteInputPerMillion: Decimal? = nil,
        cacheWriteScope: CacheWritePricingScope = .singleCategory,
        outputPerMillion: Decimal,
        currency: String,
        source: String,
        asOf: Date,
        cacheWriteTTLPrices: CacheWriteTTLPrices?,
        model: ModelID? = nil
    ) {
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.cacheWriteInputPerMillion = cacheWriteInputPerMillion
        self.cacheWriteScope = cacheWriteScope
        self.outputPerMillion = outputPerMillion
        self.currency = currency
        self.source = source
        self.asOf = asOf
        self.cacheWriteTTLPrices = cacheWriteTTLPrices
        self.model = model
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
    public let estimatedCurrentCostUnknownReason: HostCostUnknownReason?
    public let estimatedSelectedCostUnknownReason: HostCostUnknownReason?

    public init(
        candidate: HostModelCandidate,
        source: HostRoutingSelectionSource,
        estimatedCurrentCost: Decimal?,
        estimatedSelectedCost: Decimal?
    ) {
        self.init(candidate: candidate, source: source, estimatedCurrentCost: estimatedCurrentCost,
            estimatedSelectedCost: estimatedSelectedCost, estimatedCurrentCostUnknownReason: nil,
            estimatedSelectedCostUnknownReason: nil)
    }

    public init(
        candidate: HostModelCandidate,
        source: HostRoutingSelectionSource,
        estimatedCurrentCost: Decimal?,
        estimatedSelectedCost: Decimal?,
        estimatedCurrentCostUnknownReason: HostCostUnknownReason?,
        estimatedSelectedCostUnknownReason: HostCostUnknownReason?
    ) {
        self.candidate = candidate
        self.source = source
        self.estimatedCurrentCost = estimatedCurrentCost
        self.estimatedSelectedCost = estimatedSelectedCost
        self.estimatedCurrentCostUnknownReason = estimatedCurrentCostUnknownReason
        self.estimatedSelectedCostUnknownReason = estimatedSelectedCostUnknownReason
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
        let currentEstimate = costEstimate(for: legalCurrent)
        let selectedEstimate = costEstimate(for: selected)
        let currentCost = currentEstimate.value
        let selectedCost = selectedEstimate.value
        guard let currentCost, let selectedCost,
              legalCurrent.pricing?.currency == selected.pricing?.currency,
              let switchCost = add(selectedCost, minimumSwitchSavings),
              switchCost < currentCost else {
            return .init(
                candidate: legalCurrent,
                source: .current,
                estimatedCurrentCost: currentCost,
                estimatedSelectedCost: selectedCost,
                estimatedCurrentCostUnknownReason: currentEstimate.unknownReason,
                estimatedSelectedCostUnknownReason: selectedEstimate.unknownReason
            )
        }
        return .init(
            candidate: selected,
            source: .decision,
            estimatedCurrentCost: currentCost,
            estimatedSelectedCost: selectedCost,
            estimatedCurrentCostUnknownReason: currentEstimate.unknownReason,
            estimatedSelectedCostUnknownReason: selectedEstimate.unknownReason
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
        let currentEstimate = current.map { costEstimate(for: $0) }
        let selectedEstimate = costEstimate(for: selected)
        return .init(
            candidate: selected,
            source: source,
            estimatedCurrentCost: currentEstimate?.value,
            estimatedSelectedCost: selectedEstimate.value,
            estimatedCurrentCostUnknownReason: currentEstimate?.unknownReason,
            estimatedSelectedCostUnknownReason: selectedEstimate.unknownReason
        )
    }

    /// Forecast only: the Host supplies this candidate's own usage assumptions and tariff.
    public func costEstimate(for candidate: HostModelCandidate) -> HostCostEstimate {
        guard let usage = candidate.forecast else { return .init(value: nil, unknownReason: .missingForecast) }
        guard let pricing = candidate.pricing else { return .init(value: nil, unknownReason: .missingQuote) }
        func unknown(_ reason: HostCostUnknownReason) -> HostCostEstimate { .init(value: nil, unknownReason: reason) }
        let counts = [usage.inputTokens, usage.outputTokens, usage.cachedInputTokens,
            usage.cacheWriteInputTokens, usage.cacheWriteTTL?.fiveMinuteTokens, usage.cacheWriteTTL?.oneHourTokens]
        guard counts.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { return unknown(.invalidCount) }
        guard let cached = usage.cachedInputTokens else { return unknown(.missingReadUsage) }
        guard cached <= usage.inputTokens else { return unknown(.invalidClassification) }
        guard pricing.model == nil || pricing.model == candidate.binding.model,
              !pricing.currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pricing.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pricing.asOf.timeIntervalSince1970.isFinite else { return unknown(.invalidQuote) }
        guard pricing.inputPerMillion >= 0, pricing.outputPerMillion >= 0 else { return unknown(.invalidPrice) }
        let remaining = usage.inputTokens - cached
        if let aggregate = usage.cacheWriteInputTokens, aggregate > remaining { return unknown(.invalidClassification) }
        if let five = usage.cacheWriteTTL?.fiveMinuteTokens, five > remaining { return unknown(.invalidClassification) }
        if let hour = usage.cacheWriteTTL?.oneHourTokens, hour > remaining { return unknown(.invalidClassification) }
        if let detail = usage.cacheWriteTTL, let aggregate = usage.cacheWriteInputTokens {
            if let five = detail.fiveMinuteTokens, five > aggregate { return unknown(.invalidClassification) }
            if let hour = detail.oneHourTokens, hour > aggregate { return unknown(.invalidClassification) }
        }
        if let five = usage.cacheWriteTTL?.fiveMinuteTokens, let hour = usage.cacheWriteTTL?.oneHourTokens {
            let sum = five.addingReportingOverflow(hour)
            guard !sum.overflow else { return unknown(.arithmeticOverflow) }
            guard sum.partialValue <= remaining else { return unknown(.invalidClassification) }
            if let aggregate = usage.cacheWriteInputTokens, sum.partialValue != aggregate { return unknown(.invalidClassification) }
        }
        let written: Int
        let writeCost: Decimal
        switch pricing.cacheWriteScope {
        case .noSeparateCharge:
            // Explicit verified tariff: non-read input uses the ordinary rate.
            written = 0
            writeCost = 0
        case .singleCategory:
            guard let count = usage.cacheWriteInputTokens else { return unknown(.missingWriteUsage) }
            written = count
            let rate: Decimal
            if count == 0 { rate = 0 }
            else if let quoted = pricing.cacheWriteInputPerMillion {
                guard quoted >= 0 else { return unknown(.invalidPrice) }
                rate = quoted
            } else { return unknown(.missingWritePrice) }
            guard let product = multiply(Decimal(count), rate) else { return unknown(.arithmeticOverflow) }
            writeCost = product
        case .ttlBreakdown:
            if usage.cacheWriteInputTokens == 0 {
                // An explicitly reported aggregate zero needs no write tariff.
                written = 0
                writeCost = 0
            } else {
                guard let five = usage.cacheWriteTTL?.fiveMinuteTokens,
                      let hour = usage.cacheWriteTTL?.oneHourTokens else { return unknown(.missingTTLUsage) }
                let sum = five.addingReportingOverflow(hour)
                guard !sum.overflow else { return unknown(.arithmeticOverflow) }
                written = sum.partialValue
                guard written <= remaining else { return unknown(.invalidClassification) }
                let fiveRate: Decimal
                let hourRate: Decimal
                if five == 0 { fiveRate = 0 }
                else if let rate = pricing.cacheWriteTTLPrices?.fiveMinutePerMillion {
                    guard rate >= 0 else { return unknown(.invalidPrice) }
                    fiveRate = rate
                } else { return unknown(.missingWritePrice) }
                if hour == 0 { hourRate = 0 }
                else if let rate = pricing.cacheWriteTTLPrices?.oneHourPerMillion {
                    guard rate >= 0 else { return unknown(.invalidPrice) }
                    hourRate = rate
                } else { return unknown(.missingWritePrice) }
                guard let fiveCost = multiply(Decimal(five), fiveRate),
                      let hourCost = multiply(Decimal(hour), hourRate),
                      let total = add(fiveCost, hourCost) else { return unknown(.arithmeticOverflow) }
                writeCost = total
            }
        }
        let cachedRate: Decimal
        if cached == 0 { cachedRate = 0 }
        else if let rate = pricing.cachedInputPerMillion {
            guard rate >= 0 else { return unknown(.invalidPrice) }
            cachedRate = rate
        } else { return unknown(.missingReadPrice) }
        guard let ordinaryCost = multiply(Decimal(remaining - written), pricing.inputPerMillion),
              let cachedCost = multiply(Decimal(cached), cachedRate),
              let outputCost = multiply(Decimal(usage.outputTokens), pricing.outputPerMillion),
              let readAndOrdinaryCost = add(ordinaryCost, cachedCost),
              let inputCost = add(readAndOrdinaryCost, writeCost),
              var tokenCost = add(inputCost, outputCost) else { return unknown(.arithmeticOverflow) }
        var million = Decimal(1_000_000)
        var result = Decimal()
        guard NSDecimalDivide(&result, &tokenCost, &million, .plain) == .noError else { return unknown(.arithmeticOverflow) }
        return .init(value: result, unknownReason: nil)
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
