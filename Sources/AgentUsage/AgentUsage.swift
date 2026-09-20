import AgentModels
import Foundation

/// The subsystem that produced an accounting observation.
public struct UsageSource: Hashable, Sendable, Codable {
    public let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let modelResponse = Self(rawValue: "model_response")
    public static let decision = Self(rawValue: "decision")
}

/// A stable identity for one provider or decision invocation.
public struct UsageRecordIdentity: Hashable, Sendable, Codable {
    public let source: UsageSource
    public let sessionID: UUID?
    public let runID: UUID?
    public let invocationID: String
    public let providerResponseID: String?
    public let model: ModelID
    public let bindingProfileID: String?
    public let bindingProfileRevision: String?
    public let deploymentScope: String?
    public let contextEpoch: UInt64?
    public let routeSource: String?

    /// Compatibility initializer for the pre-binding-dimensions API.
    public init(
        source: UsageSource,
        sessionID: UUID? = nil,
        runID: UUID? = nil,
        invocationID: String,
        providerResponseID: String? = nil,
        model: ModelID
    ) {
        self.init(
            source: source,
            sessionID: sessionID,
            runID: runID,
            invocationID: invocationID,
            providerResponseID: providerResponseID,
            model: model,
            bindingProfileID: nil
        )
    }

    public init(
        source: UsageSource,
        sessionID: UUID? = nil,
        runID: UUID? = nil,
        invocationID: String,
        providerResponseID: String? = nil,
        model: ModelID,
        bindingProfileID: String?,
        bindingProfileRevision: String? = nil,
        deploymentScope: String? = nil,
        contextEpoch: UInt64? = nil,
        routeSource: String? = nil
    ) {
        self.source = source
        self.sessionID = sessionID
        self.runID = runID
        self.invocationID = invocationID
        self.providerResponseID = providerResponseID
        self.model = model
        self.bindingProfileID = bindingProfileID
        self.bindingProfileRevision = bindingProfileRevision
        self.deploymentScope = deploymentScope
        self.contextEpoch = contextEpoch
        self.routeSource = routeSource
    }
}

public struct UsageObservationStatus: Hashable, Sendable, Codable {
    public let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let provisional = Self(rawValue: "provisional")
    public static let finalized = Self(rawValue: "finalized")
}

/// One cumulative usage snapshot or final confirmation for an invocation.
public struct UsageObservation: Hashable, Sendable, Codable {
    public let identity: UsageRecordIdentity
    public let usage: ModelUsage
    public let status: UsageObservationStatus

    public init(identity: UsageRecordIdentity, usage: ModelUsage, status: UsageObservationStatus) {
        self.identity = identity
        self.usage = usage
        self.status = status
    }
}

public struct UsageFieldSummary: Hashable, Sendable, Codable {
    public let reportedSubtotal: Int?
    public let reportedCount: Int
    public let missingCount: Int

    public var complete: Bool {
        reportedSubtotal != nil && reportedCount > 0 && missingCount == 0
    }

    init(reportedSubtotal: Int?, reportedCount: Int, missingCount: Int) {
        self.reportedSubtotal = reportedSubtotal
        self.reportedCount = reportedCount
        self.missingCount = missingCount
    }
}

/// Field-by-field token totals for a selected set of visible responses.
public struct UsageTokenSummary: Hashable, Sendable, Codable {
    public let sampleCount: Int
    public let inputTokens: UsageFieldSummary
    public let outputTokens: UsageFieldSummary
    public let cachedInputTokens: UsageFieldSummary
    public let cacheWriteInputTokens: UsageFieldSummary
    public let reasoningTokens: UsageFieldSummary
    public let totalTokens: Int?

    init(
        sampleCount: Int,
        inputTokens: UsageFieldSummary,
        outputTokens: UsageFieldSummary,
        cachedInputTokens: UsageFieldSummary,
        cacheWriteInputTokens: UsageFieldSummary,
        reasoningTokens: UsageFieldSummary,
        totalTokens: Int?
    ) {
        self.sampleCount = sampleCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
    }
}

public struct UsageCoverage: Hashable, Sendable, Codable {
    public let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let noSamples = Self(rawValue: "no_samples")
    public static let publicModelResponses = Self(rawValue: "public_model_responses")
    public static let decisionResponses = Self(rawValue: "decision_responses")
    public static let mixedVisibleResponses = Self(rawValue: "mixed_visible_responses")
}

public struct UsageSummary: Hashable, Sendable, Codable {
    public let observedResponseCount: Int
    public let finalizedResponseCount: Int
    public let provisionalResponseCount: Int
    public let observedUsage: UsageTokenSummary
    public let finalizedUsage: UsageTokenSummary
    public let provisionalUsage: UsageTokenSummary
    public let sources: Set<UsageSource>
    public let coverage: UsageCoverage

    public var inputTokens: UsageFieldSummary { observedUsage.inputTokens }
    public var outputTokens: UsageFieldSummary { observedUsage.outputTokens }
    public var cachedInputTokens: UsageFieldSummary { observedUsage.cachedInputTokens }
    public var cacheWriteInputTokens: UsageFieldSummary { observedUsage.cacheWriteInputTokens }
    public var reasoningTokens: UsageFieldSummary { observedUsage.reasoningTokens }
    public var totalTokens: Int? { observedUsage.totalTokens }

    public var allResponsesFinalized: Bool {
        observedResponseCount > 0 && provisionalResponseCount == 0
    }

    /// Reported subtotals only. Inspect each field summary before treating a value as complete.
    public var reportedUsage: ModelUsage {
        ModelUsage(
            inputTokens: inputTokens.reportedSubtotal,
            outputTokens: outputTokens.reportedSubtotal,
            cachedInputTokens: cachedInputTokens.reportedSubtotal,
            cacheWriteInputTokens: cacheWriteInputTokens.reportedSubtotal,
            reasoningTokens: reasoningTokens.reportedSubtotal
        )
    }

    public static var empty: Self {
        let field = UsageFieldSummary(reportedSubtotal: nil, reportedCount: 0, missingCount: 0)
        let usage = UsageTokenSummary(
            sampleCount: 0,
            inputTokens: field,
            outputTokens: field,
            cachedInputTokens: field,
            cacheWriteInputTokens: field,
            reasoningTokens: field,
            totalTokens: nil
        )
        return Self(
            observedResponseCount: 0,
            finalizedResponseCount: 0,
            provisionalResponseCount: 0,
            observedUsage: usage,
            finalizedUsage: usage,
            provisionalUsage: usage,
            sources: [],
            coverage: .noSamples
        )
    }

    init(
        observedResponseCount: Int,
        finalizedResponseCount: Int,
        provisionalResponseCount: Int,
        observedUsage: UsageTokenSummary,
        finalizedUsage: UsageTokenSummary,
        provisionalUsage: UsageTokenSummary,
        sources: Set<UsageSource>,
        coverage: UsageCoverage
    ) {
        self.observedResponseCount = observedResponseCount
        self.finalizedResponseCount = finalizedResponseCount
        self.provisionalResponseCount = provisionalResponseCount
        self.observedUsage = observedUsage
        self.finalizedUsage = finalizedUsage
        self.provisionalUsage = provisionalUsage
        self.sources = sources
        self.coverage = coverage
    }
}

public struct UsageMetric: Hashable, Sendable, Codable {
    public let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let inputTokens = Self(rawValue: "input_tokens")
    public static let outputTokens = Self(rawValue: "output_tokens")
    public static let cachedInputTokens = Self(rawValue: "cached_input_tokens")
    public static let cacheWriteInputTokens = Self(rawValue: "cache_write_input_tokens")
    public static let reasoningTokens = Self(rawValue: "reasoning_tokens")
    public static let totalTokens = Self(rawValue: "total_tokens")
}

public struct UsageDiagnosticKind: Hashable, Sendable, Codable {
    public let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let invalidIdentity = Self(rawValue: "invalid_identity")
    public static let invalidStatus = Self(rawValue: "invalid_status")
    public static let negativeValue = Self(rawValue: "negative_value")
    public static let decreasedValue = Self(rawValue: "decreased_value")
    public static let subsetExceedsTotal = Self(rawValue: "subset_exceeds_total")
    public static let finalizedConflict = Self(rawValue: "finalized_conflict")
    public static let arithmeticOverflow = Self(rawValue: "arithmetic_overflow")
}

public struct UsageDiagnostic: Error, Hashable, Sendable, Codable {
    public let kind: UsageDiagnosticKind
    public let identity: UsageRecordIdentity
    public let metric: UsageMetric?

    init(kind: UsageDiagnosticKind, identity: UsageRecordIdentity, metric: UsageMetric? = nil) {
        self.kind = kind
        self.identity = identity
        self.metric = metric
    }
}

public struct UsageRecordingDisposition: Hashable, Sendable, Codable {
    public let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let inserted = Self(rawValue: "inserted")
    public static let updated = Self(rawValue: "updated")
    public static let duplicate = Self(rawValue: "duplicate")
    public static let rejected = Self(rawValue: "rejected")
}

public struct UsageRecordingResult: Hashable, Sendable, Codable {
    public let disposition: UsageRecordingDisposition
    public let diagnostic: UsageDiagnostic?

    public var accepted: Bool {
        disposition != .rejected
    }

    init(disposition: UsageRecordingDisposition, diagnostic: UsageDiagnostic? = nil) {
        self.disposition = disposition
        self.diagnostic = diagnostic
    }
}

/// A value-semantic accounting window for a Host that already owns synchronization.
public struct UsageAccumulator: Sendable {
    private var observations: [UsageRecordIdentity: UsageObservation] = [:]

    public init() {}

    @discardableResult
    public mutating func record(_ observation: UsageObservation) -> UsageRecordingResult {
        if let diagnostic = Self.validateIdentityAndStatus(observation) {
            return .init(disposition: .rejected, diagnostic: diagnostic)
        }

        if let existing = observations[observation.identity], existing.status == .finalized {
            if existing.usage == observation.usage {
                return .init(disposition: .duplicate)
            }
            return .init(
                disposition: .rejected,
                diagnostic: .init(kind: .finalizedConflict, identity: observation.identity)
            )
        }

        let mergedUsage: ModelUsage
        if let existing = observations[observation.identity] {
            switch Self.merge(existing.usage, observation.usage, identity: observation.identity) {
            case .success(let usage): mergedUsage = usage
            case .failure(let diagnostic):
                return .init(disposition: .rejected, diagnostic: diagnostic)
            }
        } else {
            mergedUsage = observation.usage
        }

        if let diagnostic = Self.validate(mergedUsage, identity: observation.identity) {
            return .init(disposition: .rejected, diagnostic: diagnostic)
        }

        let proposed = UsageObservation(
            identity: observation.identity,
            usage: mergedUsage,
            status: observation.status
        )
        if observations[observation.identity] == proposed {
            return .init(disposition: .duplicate)
        }

        var candidate = observations
        let inserted = candidate.updateValue(proposed, forKey: observation.identity) == nil
        if let metric = Self.firstOverflow(in: candidate.values) {
            return .init(
                disposition: .rejected,
                diagnostic: .init(kind: .arithmeticOverflow, identity: observation.identity, metric: metric)
            )
        }

        observations = candidate
        return .init(disposition: inserted ? .inserted : .updated)
    }

    public func summary() -> UsageSummary {
        Self.makeSummary(Array(observations.values))
    }

    public func summary(identity: UsageRecordIdentity) -> UsageSummary {
        Self.makeSummary(observations[identity].map { [$0] } ?? [])
    }

    public func summary(sessionID: UUID, runID: UUID) -> UsageSummary {
        Self.makeSummary(observations.values.filter {
            $0.identity.sessionID == sessionID && $0.identity.runID == runID
        })
    }

    public func summary(sessionID: UUID) -> UsageSummary {
        Self.makeSummary(observations.values.filter { $0.identity.sessionID == sessionID })
    }

    public func summary(model: ModelID) -> UsageSummary {
        Self.makeSummary(observations.values.filter { $0.identity.model == model })
    }

    public mutating func removeAll() {
        observations.removeAll(keepingCapacity: false)
    }

    private static func makeSummary<S: Sequence>(_ observations: S) -> UsageSummary where S.Element == UsageObservation {
        let observations = Array(observations)
        let finalized = observations.filter { $0.status == .finalized }
        let provisional = observations.filter { $0.status == .provisional }

        return UsageSummary(
            observedResponseCount: observations.count,
            finalizedResponseCount: finalized.count,
            provisionalResponseCount: provisional.count,
            observedUsage: summarizeTokens(observations),
            finalizedUsage: summarizeTokens(finalized),
            provisionalUsage: summarizeTokens(provisional),
            sources: Set(observations.map(\.identity.source)),
            coverage: coverage(for: observations)
        )
    }

    private static func summarizeTokens(_ observations: [UsageObservation]) -> UsageTokenSummary {
        let input = summarizeUsageField(observations.map(\.usage.inputTokens))
        let output = summarizeUsageField(observations.map(\.usage.outputTokens))
        let cached = summarizeUsageField(observations.map(\.usage.cachedInputTokens))
        let cacheWrite = summarizeUsageField(observations.map(\.usage.cacheWriteInputTokens))
        let reasoning = summarizeUsageField(observations.map(\.usage.reasoningTokens))

        let totalTokens: Int?
        if input.complete, output.complete,
           let inputSubtotal = input.reportedSubtotal,
           let outputSubtotal = output.reportedSubtotal {
            let (sum, overflow) = inputSubtotal.addingReportingOverflow(outputSubtotal)
            totalTokens = overflow ? nil : sum
        } else {
            totalTokens = nil
        }

        return UsageTokenSummary(
            sampleCount: observations.count,
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
            reasoningTokens: reasoning,
            totalTokens: totalTokens
        )
    }

    private static func validateIdentityAndStatus(_ observation: UsageObservation) -> UsageDiagnostic? {
        let identity = observation.identity
        let required = [identity.source.rawValue, identity.invocationID, identity.model.provider, identity.model.name]
        let optional = [
            identity.providerResponseID,
            identity.bindingProfileID,
            identity.bindingProfileRevision,
            identity.deploymentScope,
            identity.routeSource,
        ]
        guard identity.source == .modelResponse || identity.source == .decision,
              required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              optional.allSatisfy({ value in
                  value.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
              })
        else {
            return .init(kind: .invalidIdentity, identity: identity)
        }
        guard observation.status == .provisional || observation.status == .finalized else {
            return .init(kind: .invalidStatus, identity: identity)
        }
        return validate(observation.usage, identity: identity)
    }

    private static func merge(
        _ existing: ModelUsage,
        _ incoming: ModelUsage,
        identity: UsageRecordIdentity
    ) -> Result<ModelUsage, UsageDiagnostic> {
        func field(_ old: Int?, _ new: Int?, metric: UsageMetric) -> Result<Int?, UsageDiagnostic> {
            guard let new else { return .success(old) }
            if new < 0 {
                return .failure(.init(kind: .negativeValue, identity: identity, metric: metric))
            }
            if let old, new < old {
                return .failure(.init(kind: .decreasedValue, identity: identity, metric: metric))
            }
            return .success(new)
        }

        let input: Int?
        let output: Int?
        let cached: Int?
        let cacheWrite: Int?
        let reasoning: Int?
        switch field(existing.inputTokens, incoming.inputTokens, metric: .inputTokens) {
        case .success(let value): input = value
        case .failure(let diagnostic): return .failure(diagnostic)
        }
        switch field(existing.outputTokens, incoming.outputTokens, metric: .outputTokens) {
        case .success(let value): output = value
        case .failure(let diagnostic): return .failure(diagnostic)
        }
        switch field(existing.cachedInputTokens, incoming.cachedInputTokens, metric: .cachedInputTokens) {
        case .success(let value): cached = value
        case .failure(let diagnostic): return .failure(diagnostic)
        }
        switch field(existing.cacheWriteInputTokens, incoming.cacheWriteInputTokens, metric: .cacheWriteInputTokens) {
        case .success(let value): cacheWrite = value
        case .failure(let diagnostic): return .failure(diagnostic)
        }
        switch field(existing.reasoningTokens, incoming.reasoningTokens, metric: .reasoningTokens) {
        case .success(let value): reasoning = value
        case .failure(let diagnostic): return .failure(diagnostic)
        }
        return .success(.init(
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
            reasoningTokens: reasoning
        ))
    }

    private static func validate(_ usage: ModelUsage, identity: UsageRecordIdentity) -> UsageDiagnostic? {
        for (metric, value) in fields(of: usage) where (value ?? 0) < 0 {
            return .init(kind: .negativeValue, identity: identity, metric: metric)
        }
        if let input = usage.inputTokens, let cached = usage.cachedInputTokens, cached > input {
            return .init(kind: .subsetExceedsTotal, identity: identity, metric: .cachedInputTokens)
        }
        if let input = usage.inputTokens, let written = usage.cacheWriteInputTokens, written > input {
            return .init(kind: .subsetExceedsTotal, identity: identity, metric: .cacheWriteInputTokens)
        }
        if let output = usage.outputTokens, let reasoning = usage.reasoningTokens, reasoning > output {
            return .init(kind: .subsetExceedsTotal, identity: identity, metric: .reasoningTokens)
        }
        if let input = usage.inputTokens, let output = usage.outputTokens,
           input.addingReportingOverflow(output).overflow {
            return .init(kind: .arithmeticOverflow, identity: identity, metric: .totalTokens)
        }
        return nil
    }

    private static func firstOverflow<S: Sequence>(in observations: S) -> UsageMetric? where S.Element == UsageObservation {
        let values = Array(observations)
        for metric in [UsageMetric.inputTokens, .outputTokens, .cachedInputTokens,
                       .cacheWriteInputTokens, .reasoningTokens] {
            var subtotal = 0
            for observation in values {
                guard let value = value(for: metric, in: observation.usage) else { continue }
                let result = subtotal.addingReportingOverflow(value)
                if result.overflow { return metric }
                subtotal = result.partialValue
            }
        }

        let input = checkedSubtotal(values.compactMap(\.usage.inputTokens))
        let output = checkedSubtotal(values.compactMap(\.usage.outputTokens))
        if values.allSatisfy({ $0.usage.inputTokens != nil && $0.usage.outputTokens != nil }),
           let input, let output, input.addingReportingOverflow(output).overflow {
            return .totalTokens
        }
        return nil
    }

    private static func checkedSubtotal(_ values: [Int]) -> Int? {
        var subtotal = 0
        for value in values {
            let result = subtotal.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            subtotal = result.partialValue
        }
        return subtotal
    }

    private static func fields(of usage: ModelUsage) -> [(UsageMetric, Int?)] {
        [
            (.inputTokens, usage.inputTokens),
            (.outputTokens, usage.outputTokens),
            (.cachedInputTokens, usage.cachedInputTokens),
            (.cacheWriteInputTokens, usage.cacheWriteInputTokens),
            (.reasoningTokens, usage.reasoningTokens),
        ]
    }

    private static func value(for metric: UsageMetric, in usage: ModelUsage) -> Int? {
        switch metric {
        case .inputTokens: usage.inputTokens
        case .outputTokens: usage.outputTokens
        case .cachedInputTokens: usage.cachedInputTokens
        case .cacheWriteInputTokens: usage.cacheWriteInputTokens
        case .reasoningTokens: usage.reasoningTokens
        default: nil
        }
    }

    private static func coverage(for observations: [UsageObservation]) -> UsageCoverage {
        let sources = Set(observations.map(\.identity.source))
        if sources.isEmpty { return .noSamples }
        if sources == [.modelResponse] { return .publicModelResponses }
        if sources == [.decision] { return .decisionResponses }
        return .mixedVisibleResponses
    }
}

func summarizeUsageField(_ values: [Int?]) -> UsageFieldSummary {
    var subtotal: Int?
    var reportedCount = 0
    var overflowed = false

    for value in values {
        guard let value else { continue }
        reportedCount += 1
        guard !overflowed else { continue }
        if let existing = subtotal {
            let (sum, overflow) = existing.addingReportingOverflow(value)
            if overflow {
                subtotal = nil
                overflowed = true
            } else {
                subtotal = sum
            }
        } else {
            subtotal = value
        }
    }

    return UsageFieldSummary(
        reportedSubtotal: subtotal,
        reportedCount: reportedCount,
        missingCount: values.count - reportedCount
    )
}

/// An actor-isolated accounting window for consumers that do not already own synchronization.
public actor UsageLedger {
    private var accumulator = UsageAccumulator()

    public init() {}

    @discardableResult
    public func record(_ observation: UsageObservation) -> UsageRecordingResult {
        accumulator.record(observation)
    }

    public func summary() -> UsageSummary {
        accumulator.summary()
    }

    public func summary(identity: UsageRecordIdentity) -> UsageSummary {
        accumulator.summary(identity: identity)
    }

    public func summary(sessionID: UUID, runID: UUID) -> UsageSummary {
        accumulator.summary(sessionID: sessionID, runID: runID)
    }

    public func summary(sessionID: UUID) -> UsageSummary {
        accumulator.summary(sessionID: sessionID)
    }

    public func summary(model: ModelID) -> UsageSummary {
        accumulator.summary(model: model)
    }

    public func removeAll() {
        accumulator.removeAll()
    }
}
