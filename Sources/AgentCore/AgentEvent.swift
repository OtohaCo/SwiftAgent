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
    case toolFailed(ToolCallID, AgentFailure)
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
        default: self = .unclassified
        }
    }
}
