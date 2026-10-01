import AgentModels
import AgentTools

struct AgentLoopLifecycle: Sendable {
    let control: AgentRunControl
    let evidenceLedger: EvidenceLedger
    let mutationAdmission: (any ToolMutationAdmission)?
    let checkpoint: @Sendable ([ModelMessage], [AgentSteeringInput]) async throws -> [ModelMessage]
    /// The live Session revision of this exact committed canonical source.
    let sourceRevision: (@Sendable ([ModelMessage]) async throws -> UInt64)?
    let checkReplanningSafety: @Sendable (String?) async throws -> Bool
    let recordAdmissionRejection: @Sendable (ToolPreAdmissionRejection, [ModelMessage]) async throws -> [ModelMessage]
    let recordMutationReceipt: @Sendable (ToolCallID, ToolReceipt, JSONValue) async throws -> Void
    let commitMutation: (@Sendable (ToolCallID, ToolReceipt, JSONValue, [ModelMessage], [AgentSteeringInput]) async throws -> [ModelMessage])?
    let commitNoEffectResult: (@Sendable (PreparedToolCall, ToolResult<JSONValue>, [ModelMessage]) async throws -> [ModelMessage])?
    let commitAuditedResult: (@Sendable (PreparedToolCall, ToolResult<JSONValue>, [ModelMessage]) async throws -> [ModelMessage])?
    let markMutationNeedsReconciliation: @Sendable (ToolCallID) async throws -> Void
    let recordReadOnlyResult: @Sendable (ToolCall, ToolResultMessage) async -> Void
    /// Ends the Run's ownership of the Session. A returned error is a persistence outcome the Run
    /// must report instead of its own, such as an unknown commit of retained steering.
    let beforeFinish: @Sendable () async -> (any Error)?

    init(
        control: AgentRunControl,
        evidenceLedger: EvidenceLedger,
        mutationAdmission: (any ToolMutationAdmission)? = nil,
        checkpoint: @escaping @Sendable ([ModelMessage], [AgentSteeringInput]) async throws -> [ModelMessage],
        sourceRevision: (@Sendable ([ModelMessage]) async throws -> UInt64)? = nil,
        checkReplanningSafety: @escaping @Sendable (String?) async throws -> Bool = { _ in false },
        recordAdmissionRejection: @escaping @Sendable (ToolPreAdmissionRejection, [ModelMessage]) async throws -> [ModelMessage] = { _, _ in throw AgentJournalError.persistenceUnavailable("rejection commit unavailable") },
        recordMutationReceipt: @escaping @Sendable (ToolCallID, ToolReceipt, JSONValue) async throws -> Void = { _, _, _ in },
        commitMutation: (@Sendable (ToolCallID, ToolReceipt, JSONValue, [ModelMessage], [AgentSteeringInput]) async throws -> [ModelMessage])? = nil,
        commitNoEffectResult: (@Sendable (PreparedToolCall, ToolResult<JSONValue>, [ModelMessage]) async throws -> [ModelMessage])? = nil,
        commitAuditedResult: (@Sendable (PreparedToolCall, ToolResult<JSONValue>, [ModelMessage]) async throws -> [ModelMessage])? = nil,
        markMutationNeedsReconciliation: @escaping @Sendable (ToolCallID) async throws -> Void = { _ in },
        recordReadOnlyResult: @escaping @Sendable (ToolCall, ToolResultMessage) async -> Void = { _, _ in },
        beforeFinish: @escaping @Sendable () async -> (any Error)? = { nil }
    ) {
        self.control = control
        self.evidenceLedger = evidenceLedger
        self.mutationAdmission = mutationAdmission
        self.checkpoint = checkpoint
        self.sourceRevision = sourceRevision
        self.checkReplanningSafety = checkReplanningSafety
        self.recordAdmissionRejection = recordAdmissionRejection
        self.recordMutationReceipt = recordMutationReceipt
        self.commitMutation = commitMutation
        self.commitNoEffectResult = commitNoEffectResult
        self.commitAuditedResult = commitAuditedResult
        self.markMutationNeedsReconciliation = markMutationNeedsReconciliation
        self.recordReadOnlyResult = recordReadOnlyResult
        self.beforeFinish = beforeFinish
    }
}
