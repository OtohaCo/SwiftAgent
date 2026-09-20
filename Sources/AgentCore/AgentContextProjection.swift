import AgentModels
import Foundation

public struct AgentContextProjectionInput: Hashable, Sendable, Codable {
    public let canonicalMessages: [ModelMessage]
    public let model: ModelID
    public let sessionID: UUID
    public let runID: UUID
    public let conversationRevision: UInt64
    public let contextEpoch: UInt64
    public let modelTurn: Int

    public init(
        canonicalMessages: [ModelMessage],
        model: ModelID,
        sessionID: UUID,
        runID: UUID,
        conversationRevision: UInt64,
        contextEpoch: UInt64,
        modelTurn: Int
    ) {
        self.canonicalMessages = canonicalMessages
        self.model = model
        self.sessionID = sessionID
        self.runID = runID
        self.conversationRevision = conversationRevision
        self.contextEpoch = contextEpoch
        self.modelTurn = modelTurn
    }
}

public struct AgentContextProjectionPlan: Hashable, Sendable, Codable {
    public let projectionID: String
    public let version: String
    public let sourceRevision: UInt64
    public let sourceDigest: String
    public let contextEpoch: UInt64
    public let lossy: Bool
    public let reason: String?

    public init(
        projectionID: String,
        version: String,
        sourceRevision: UInt64,
        sourceDigest: String,
        contextEpoch: UInt64,
        lossy: Bool,
        reason: String? = nil
    ) {
        self.projectionID = projectionID
        self.version = version
        self.sourceRevision = sourceRevision
        self.sourceDigest = sourceDigest
        self.contextEpoch = contextEpoch
        self.lossy = lossy
        self.reason = reason
    }
}

public enum AgentContextProjectionSource {
    /// Stable, non-secret digest for correlating a projection with its exact
    /// canonical input. It is an integrity/version marker, not a credential.
    public static func digest(messages: [ModelMessage]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(messages)
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            value ^= UInt64(byte)
            value = value &* 1_099_511_628_211
        }
        return String(format: "%016llx", value)
    }
}

public struct AgentContextProjection: Hashable, Sendable, Codable {
    public let messages: [ModelMessage]
    public let plan: AgentContextProjectionPlan

    public init(messages: [ModelMessage], plan: AgentContextProjectionPlan) {
        self.messages = messages
        self.plan = plan
    }
}

public protocol AgentContextProjector: Sendable {
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection
}

public enum AgentContextProjectionError: Error, Equatable, Sendable {
    case unresolvedReadOnlySpan(ToolCallID)
}

public struct AgentIdentityContextProjector: AgentContextProjector {
    public init() {}

    public func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        .init(
            messages: input.canonicalMessages,
            plan: .init(
                projectionID: "identity",
                version: "1",
                sourceRevision: input.conversationRevision,
                sourceDigest: try AgentContextProjectionSource.digest(messages: input.canonicalMessages),
                contextEpoch: input.contextEpoch,
                lossy: false
            )
        )
    }
}

/// Explicit cross-provider handoff. It strips only opaque provider state and
/// model-private reasoning; canonical tool calls and results stay paired.
public struct AgentSemanticHandoffProjector: AgentContextProjector {
    public init() {}

    public func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        let messages = input.canonicalMessages.map { message -> ModelMessage in
            guard case .assistant(let content, let calls) = message else { return message }
            let visible = content.filter { part in
                switch part {
                case .providerContinuation, .reasoning: false
                default: true
                }
            }
            return .assistant(content: visible, toolCalls: calls)
        }
        return .init(
            messages: messages,
            plan: .init(
                projectionID: "semantic-handoff",
                version: "1",
                sourceRevision: input.conversationRevision,
                sourceDigest: try AgentContextProjectionSource.digest(messages: input.canonicalMessages),
                contextEpoch: input.contextEpoch,
                lossy: true,
                reason: "Provider-private continuation and reasoning were excluded."
            )
        )
    }
}

/// Host-approved replacement of a resolved read-only failure group. The whole
/// assistant/tool group is replaced so tool-call correlation cannot be split.
public struct AgentResolvedReadOnlyToolSpan: Hashable, Sendable, Codable {
    public let failedCallID: ToolCallID
    public let resolvedByCallID: ToolCallID
    public let summary: String

    public init(failedCallID: ToolCallID, resolvedByCallID: ToolCallID, summary: String) {
        self.failedCallID = failedCallID
        self.resolvedByCallID = resolvedByCallID
        self.summary = summary
    }
}

public struct AgentResolvedReadOnlyToolProjector: AgentContextProjector {
    public let spans: [AgentResolvedReadOnlyToolSpan]

    public init(spans: [AgentResolvedReadOnlyToolSpan]) {
        self.spans = spans
    }

    public func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        var messages = input.canonicalMessages
        for span in spans {
            guard let failed = closedGroup(containing: span.failedCallID, in: messages),
                  let failedResult = failed.results[span.failedCallID],
                  failedResult.isError,
                  let resolved = closedGroup(containing: span.resolvedByCallID, in: messages),
                  resolved.range.lowerBound >= failed.range.upperBound,
                  resolved.results[span.resolvedByCallID]?.isError == false,
                  failed.names[span.failedCallID] == resolved.names[span.resolvedByCallID],
                  !span.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentContextProjectionError.unresolvedReadOnlySpan(span.failedCallID)
            }
            messages.replaceSubrange(
                failed.range,
                with: [.user([.text("Host context summary for a resolved read-only tool: \(span.summary)")])]
            )
        }
        return .init(
            messages: messages,
            plan: .init(
                projectionID: "resolved-read-only-tools",
                version: "1",
                sourceRevision: input.conversationRevision,
                sourceDigest: try AgentContextProjectionSource.digest(messages: input.canonicalMessages),
                contextEpoch: input.contextEpoch,
                lossy: !spans.isEmpty,
                reason: spans.isEmpty ? nil : "Host-approved resolved read-only tool groups were summarized."
            )
        )
    }

    private func closedGroup(
        containing callID: ToolCallID,
        in messages: [ModelMessage]
    ) -> (range: Range<Int>, names: [ToolCallID: String], results: [ToolCallID: ToolResultMessage])? {
        for index in messages.indices {
            guard case .assistant(_, let calls) = messages[index], calls.contains(where: { $0.id == callID }) else {
                continue
            }
            var names: [ToolCallID: String] = [:]
            for call in calls {
                guard names.updateValue(call.name, forKey: call.id) == nil else { return nil }
            }
            var results: [ToolCallID: ToolResultMessage] = [:]
            var cursor = index + 1
            while cursor < messages.count, case .tool(let result) = messages[cursor] {
                guard names[result.callID] != nil, results[result.callID] == nil else { return nil }
                results[result.callID] = result
                cursor += 1
            }
            guard results.count == calls.count else { return nil }
            return (index..<cursor, names, results)
        }
        return nil
    }
}

public struct AgentTokenEstimateAccuracy: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let exact = Self(rawValue: "exact")
    public static let estimated = Self(rawValue: "estimated")
}

public struct AgentContextTokenEstimate: Hashable, Sendable, Codable {
    public let inputTokens: Int
    public let accuracy: AgentTokenEstimateAccuracy

    public init(inputTokens: Int, accuracy: AgentTokenEstimateAccuracy) {
        self.inputTokens = inputTokens
        self.accuracy = accuracy
    }
}

public struct AgentContextTokenEstimationInput: Hashable, Sendable, Codable {
    public let model: ModelID
    public let messages: [ModelMessage]
    public let tools: [ModelToolDefinition]
    public let structuredOutput: StructuredOutputSchema?

    public init(
        model: ModelID,
        messages: [ModelMessage],
        tools: [ModelToolDefinition],
        structuredOutput: StructuredOutputSchema?
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.structuredOutput = structuredOutput
    }
}

public protocol AgentContextTokenEstimator: Sendable {
    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate
}

public struct AgentContextTokenBudget: Sendable {
    public let maximumContextTokens: Int
    public let reservedOutputTokens: Int
    public let reservedReasoningTokens: Int
    public let reservedProtocolTokens: Int
    public let estimator: any AgentContextTokenEstimator
    public let availableInputTokens: Int

    public init(
        maximumContextTokens: Int,
        reservedOutputTokens: Int,
        reservedReasoningTokens: Int = 0,
        reservedProtocolTokens: Int = 0,
        estimator: any AgentContextTokenEstimator
    ) throws {
        guard maximumContextTokens > 0,
              reservedOutputTokens >= 0,
              reservedReasoningTokens >= 0,
              reservedProtocolTokens >= 0 else {
            throw AgentModelBindingError.invalidTokenBudget
        }
        let (outputAndReasoning, firstOverflow) = reservedOutputTokens.addingReportingOverflow(
            reservedReasoningTokens
        )
        let (reserved, secondOverflow) = outputAndReasoning.addingReportingOverflow(reservedProtocolTokens)
        guard !firstOverflow, !secondOverflow, reserved <= maximumContextTokens else {
            throw AgentModelBindingError.invalidTokenBudget
        }
        self.maximumContextTokens = maximumContextTokens
        self.reservedOutputTokens = reservedOutputTokens
        self.reservedReasoningTokens = reservedReasoningTokens
        self.reservedProtocolTokens = reservedProtocolTokens
        self.estimator = estimator
        availableInputTokens = maximumContextTokens - reserved
    }
}
