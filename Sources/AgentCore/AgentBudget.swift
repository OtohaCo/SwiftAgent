public struct AgentBudget: Sendable {
    public let maxModelTurns: Int
    public let maxToolCalls: Int
    public let deadline: ContinuousClock.Instant

    public init(maxModelTurns: Int, maxToolCalls: Int, deadline: ContinuousClock.Instant) throws {
        guard maxModelTurns > 0, maxToolCalls >= 0 else { throw AgentLoopError.invalidBudget }
        self.maxModelTurns = maxModelTurns
        self.maxToolCalls = maxToolCalls
        self.deadline = deadline
    }

    func checkActive() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw AgentLoopError.deadlineExceeded }
    }
}
