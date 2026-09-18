import AgentModels
import AgentTools
import Foundation

/// Identity of one Run. Events from different Runs must not be interleaved
/// on the same stream.
public struct AgentRunInfo: Equatable, Sendable {
    public let sessionID: UUID
    public let runID: UUID
    public let model: ModelID

    public init(sessionID: UUID, runID: UUID, model: ModelID) {
        self.sessionID = sessionID
        self.runID = runID
        self.model = model
    }
}

/// Session-facing lifecycle stream. Cases are frozen business semantics, not
/// scheduler internals. `toolStarted` means the runtime admitted a call; it is
/// not a lease-acquired or executor-started signal. Future telemetry may add
/// diagnostic events without redefining this case.
///
/// Ordering: `runStarted` exactly once, then zero or more turns, then exactly
/// one `runFinished`. Model deltas arrive only inside `model`. A tool that
/// starts also ends with `toolCompleted`, `toolFailed`, or a terminal
/// `runFinished` that synthesizes failure for still-active tools.
public enum AgentEvent: Equatable, Sendable {
    case runStarted(AgentRunInfo)
    case turnStarted(Int)
    case model(ModelEvent)
    /// Runtime admission, including authorization. Not proof of an external effect.
    case toolStarted(ToolCall)
    case toolCompleted(ToolResultMessage)
    case toolReceiptValidated(AgentToolReceipt)
    case toolFailed(ToolCallID, AgentFailure)
    case steeringApplied(id: UUID, text: String)
    case runFinished(AgentRunTermination)
}

public enum AgentRunTermination: Equatable, Sendable {
    case result(AgentLoopResult)
    case failed(AgentFailure)
    case cancelled
}

/// Settlement failed, and writing the quarantine record also failed.
/// Both sides stay typed; do not parse `localizedDescription`.
public struct AgentMutationPersistenceError: Error, Equatable, Sendable {
    public let settlement: AgentFailure
    public let quarantine: AgentFailure

    public init(settlement: AgentFailure, quarantine: AgentFailure) {
        self.settlement = settlement
        self.quarantine = quarantine
    }

    static func capturing(
        settlement: any Error,
        quarantine: @Sendable () async throws -> Void
    ) async -> any Error {
        do {
            try await quarantine()
            return settlement
        } catch {
            return AgentMutationPersistenceError(
                settlement: AgentFailure(settlement),
                quarantine: AgentFailure(error)
            )
        }
    }
}

/// Typed failure for events and host switches. Match the enum; do not parse
/// `localizedDescription`. Unknown host errors collapse to `unclassified`
/// without leaking payloads.
public enum AgentFailure: Error, Equatable, Sendable {
    case loop(AgentLoopError)
    case session(AgentSessionError)
    case provider(ModelProviderError)
    case modelStream(ModelStreamError)
    case toolRegistry(ToolRegistryError)
    case toolInvocation(ToolInvocationError)
    case evidence(EvidenceError)
    case receipt(ToolReceiptError)
    case resource(ToolResourceError)
    case scheduler(ToolSchedulerError)
    case journal(AgentJournalError)
    indirect case mutationPersistence(AgentMutationPersistenceError)
    case context(AgentContextError)
    case cancelled
    case unclassified

    init(_ error: any Error) {
        switch error {
        case is CancellationError: self = .cancelled
        case let error as AgentLoopError: self = .loop(error)
        case let error as AgentSessionError: self = .session(error)
        case let error as ModelProviderError: self = .provider(error)
        case let error as ModelStreamError: self = .modelStream(error)
        case let error as ToolRegistryError: self = .toolRegistry(error)
        case let error as ToolInvocationError: self = .toolInvocation(error)
        case let error as EvidenceError: self = .evidence(error)
        case let error as ToolReceiptError: self = .receipt(error)
        case let error as ToolResourceError: self = .resource(error)
        case let error as ToolSchedulerError: self = .scheduler(error)
        case let error as AgentJournalError: self = .journal(error)
        case let error as AgentMutationPersistenceError: self = .mutationPersistence(error)
        case let error as AgentContextError: self = .context(error)
        default: self = .unclassified
        }
    }
}

/// A receipt accepted by the runtime, with the declared effect of its tool.
public struct AgentToolReceipt: Codable, Equatable, Hashable, Sendable {
    public let callID: ToolCallID
    public let effect: ToolPolicy.Effect
    public let receipt: ToolReceipt

    public init(callID: ToolCallID, effect: ToolPolicy.Effect, receipt: ToolReceipt) {
        self.callID = callID
        self.effect = effect
        self.receipt = receipt
    }
}
