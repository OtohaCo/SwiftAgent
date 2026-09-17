import AgentModels
import AgentTools

struct AgentLoopLifecycle: Sendable {
    let control: AgentRunControl
    let evidenceLedger: EvidenceLedger
    let mutationAdmission: (any ToolMutationAdmission)?
    let checkpoint: @Sendable ([ModelMessage], [AgentSteeringInput]) async throws -> Void
    let recordMutationReceipt: @Sendable (ToolCallID, ToolReceipt) async throws -> Void
    let commitMutation: (@Sendable (ToolCallID, ToolReceipt, [ModelMessage], [AgentSteeringInput]) async throws -> Void)?
    let markMutationNeedsReconciliation: @Sendable (ToolCallID) async throws -> Void
    let beforeFinish: @Sendable () async -> Void

    init(
        control: AgentRunControl,
        evidenceLedger: EvidenceLedger,
        mutationAdmission: (any ToolMutationAdmission)? = nil,
        checkpoint: @escaping @Sendable ([ModelMessage], [AgentSteeringInput]) async throws -> Void,
        recordMutationReceipt: @escaping @Sendable (ToolCallID, ToolReceipt) async throws -> Void = { _, _ in },
        commitMutation: (@Sendable (ToolCallID, ToolReceipt, [ModelMessage], [AgentSteeringInput]) async throws -> Void)? = nil,
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
