import AgentModels
import Foundation

public struct ToolContext: Sendable, Equatable {
    public let sessionID: UUID
    public let runID: UUID
    public let callID: ToolCallID
    public let deadline: ContinuousClock.Instant?
    public let idempotencyKey: String?
    /// The exact model arguments retained for durable mutation intent.
    public let argumentsJSON: String?
    package var noEffectBinding: ToolNoEffectBinding? = nil
    package let evidenceLedger: EvidenceLedger?
    package let mutationAdmission: (any ToolMutationAdmission)?
    package let executionAdmission: (any ToolExecutionAdmission)?
    package let auditAuthorization: (any ToolAuditAuthorization)?

    public init(
        sessionID: UUID,
        runID: UUID,
        callID: ToolCallID,
        deadline: ContinuousClock.Instant? = nil,
        idempotencyKey: String? = nil,
        argumentsJSON: String? = nil,
        evidenceLedger: EvidenceLedger? = nil
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.callID = callID
        self.deadline = deadline
        self.idempotencyKey = idempotencyKey
        self.argumentsJSON = argumentsJSON
        self.evidenceLedger = evidenceLedger
        mutationAdmission = nil
        executionAdmission = nil
        auditAuthorization = nil
    }

    package init(
        sessionID: UUID,
        runID: UUID,
        callID: ToolCallID,
        deadline: ContinuousClock.Instant? = nil,
        idempotencyKey: String? = nil,
        argumentsJSON: String? = nil,
        evidenceLedger: EvidenceLedger? = nil,
        mutationAdmission: (any ToolMutationAdmission)?,
        executionAdmission: (any ToolExecutionAdmission)? = nil,
        auditAuthorization: (any ToolAuditAuthorization)? = nil
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.callID = callID
        self.deadline = deadline
        self.idempotencyKey = idempotencyKey
        self.argumentsJSON = argumentsJSON
        self.evidenceLedger = evidenceLedger
        self.mutationAdmission = mutationAdmission
        self.executionAdmission = executionAdmission
        self.auditAuthorization = auditAuthorization
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.runID == rhs.runID
            && lhs.callID == rhs.callID
            && lhs.deadline == rhs.deadline
            && lhs.idempotencyKey == rhs.idempotencyKey
            && lhs.argumentsJSON == rhs.argumentsJSON
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
