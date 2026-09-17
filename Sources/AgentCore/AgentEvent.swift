import AgentModels
import AgentTools
import Foundation

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

public enum AgentEvent: Equatable, Sendable {
    case runStarted(AgentRunInfo)
    case turnStarted(Int)
    case model(ModelEvent)
    /// Begins a runtime attempt, including authorization; not proof of an external effect.
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

/// Typed event diagnostics. Unknown host errors do not expose raw payloads or descriptions.
public enum AgentFailure: Error, Equatable, Sendable {
    case loop(AgentLoopError)
    case provider(ModelProviderError)
    case modelStream(ModelStreamError)
    case toolRegistry(ToolRegistryError)
    case toolInvocation(ToolInvocationError)
    case evidence(EvidenceError)
    case receipt(ToolReceiptError)
    case resource(ToolResourceError)
    case journal(AgentJournalError)
    case cancelled
    case unclassified

    init(_ error: any Error) {
        switch error {
        case is CancellationError: self = .cancelled
        case let error as AgentLoopError: self = .loop(error)
        case let error as ModelProviderError: self = .provider(error)
        case let error as ModelStreamError: self = .modelStream(error)
        case let error as ToolRegistryError: self = .toolRegistry(error)
        case let error as ToolInvocationError: self = .toolInvocation(error)
        case let error as EvidenceError: self = .evidence(error)
        case let error as ToolReceiptError: self = .receipt(error)
        case let error as ToolResourceError: self = .resource(error)
        case let error as AgentJournalError: self = .journal(error)
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
