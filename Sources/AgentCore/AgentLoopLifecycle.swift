import AgentModels
import AgentTools

struct AgentLoopLifecycle: Sendable {
    let control: AgentRunControl
    let evidenceLedger: EvidenceLedger
    let mutationAdmission: (any ToolMutationAdmission)?
    let checkpoint: @Sendable ([ModelMessage], [AgentSteeringInput]) async throws -> [ModelMessage]
    let recordMutationReceipt: @Sendable (ToolCallID, ToolReceipt, JSONValue) async throws -> Void
    let commitMutation: (@Sendable (ToolCallID, ToolReceipt, JSONValue, [ModelMessage], [AgentSteeringInput]) async throws -> [ModelMessage])?
    let markMutationNeedsReconciliation: @Sendable (ToolCallID) async throws -> Void
    let beforeFinish: @Sendable () async -> Void

    init(
        control: AgentRunControl,
        evidenceLedger: EvidenceLedger,
        mutationAdmission: (any ToolMutationAdmission)? = nil,
        checkpoint: @escaping @Sendable ([ModelMessage], [AgentSteeringInput]) async throws -> [ModelMessage],
        recordMutationReceipt: @escaping @Sendable (ToolCallID, ToolReceipt, JSONValue) async throws -> Void = { _, _, _ in },
        commitMutation: (@Sendable (ToolCallID, ToolReceipt, JSONValue, [ModelMessage], [AgentSteeringInput]) async throws -> [ModelMessage])? = nil,
        markMutationNeedsReconciliation: @escaping @Sendable (ToolCallID) async throws -> Void = { _ in },
        beforeFinish: @escaping @Sendable () async -> Void = {}
    ) {
        self.control = control
        self.evidenceLedger = evidenceLedger
        self.mutationAdmission = mutationAdmission
        self.checkpoint = checkpoint
        self.recordMutationReceipt = recordMutationReceipt
        self.commitMutation = commitMutation
        self.markMutationNeedsReconciliation = markMutationNeedsReconciliation
        self.beforeFinish = beforeFinish
    }
}
