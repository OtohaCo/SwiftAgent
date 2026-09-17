import AgentModels

struct AgentLoopLifecycle: Sendable {
    let control: AgentRunControl
    let checkpoint: @Sendable ([ModelMessage], [AgentSteeringInput]) async throws -> Void
    let beforeFinish: @Sendable () async -> Void
}
