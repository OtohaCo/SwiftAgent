import AgentModels
import Foundation

public struct ToolContext: Sendable, Equatable {
    public let sessionID: UUID
    public let runID: UUID
    public let callID: ToolCallID
    public let deadline: ContinuousClock.Instant?
    public let idempotencyKey: String?
    package let evidenceLedger: EvidenceLedger?

    public init(
        sessionID: UUID,
        runID: UUID,
        callID: ToolCallID,
        deadline: ContinuousClock.Instant? = nil,
        idempotencyKey: String? = nil,
        evidenceLedger: EvidenceLedger? = nil
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.callID = callID
        self.deadline = deadline
        self.idempotencyKey = idempotencyKey
        self.evidenceLedger = evidenceLedger
    }

    package func checkActive() throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline {
            throw ToolInvocationError.deadlineExceeded
        }
    }

    /// Read-only validation bound to this invocation's identity and deadline.
    public func requireEvidence(_ requirements: [EvidenceRequirement]) async throws {
        _ = try await resolveEvidence(requirements)
    }

    /// Reads trusted observations using this invocation's scope, metadata constraints and deadline.
    public func resolveEvidence(_ requirements: [EvidenceRequirement]) async throws -> [Evidence] {
        try checkActive()
        guard let evidenceLedger else { throw ToolInvocationError.evidenceUnavailable }
        let resolved = try await evidenceLedger.resolve(requirements, sessionID: sessionID, runID: runID, deadline: deadline)
        try checkActive()
        return resolved
    }
}
