import AgentModels
import Foundation

public struct ToolContext: Sendable, Equatable {
    public let sessionID: UUID
    public let runID: UUID
    public let callID: ToolCallID
    public let deadline: ContinuousClock.Instant?
    public let idempotencyKey: String?

    public init(
        sessionID: UUID,
        runID: UUID,
        callID: ToolCallID,
        deadline: ContinuousClock.Instant? = nil,
        idempotencyKey: String? = nil
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.callID = callID
        self.deadline = deadline
        self.idempotencyKey = idempotencyKey
    }

    package func checkActive() throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline {
            throw ToolInvocationError.deadlineExceeded
        }
    }
}
