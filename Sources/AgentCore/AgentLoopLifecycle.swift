import AgentModels
import AgentTools

struct AgentLoopLifecycle: Sendable {
    let control: AgentRunControl
    let evidenceLedger: EvidenceLedger
    let checkpoint: @Sendable ([ModelMessage], [AgentSteeringInput]) async throws -> Void
    let beforeFinish: @Sendable () async -> Void
}
