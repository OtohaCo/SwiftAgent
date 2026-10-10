import AgentModels

public struct AgentBudget: Sendable {
    public let maxModelTurns: Int
    public let maxToolCalls: Int
    public let deadline: ContinuousClock.Instant
    /// Whether this Run's final answer was settled in time, so that the deadline no longer applies to it.
    /// Every Run gets its own (`renewed()`), so one budget value can start several Runs.
    let gate: OperationDeadlineGate

    /// Finite per-run limits. Model turns must be positive; tool calls may be zero.

    public init(maxModelTurns: Int, maxToolCalls: Int, deadline: ContinuousClock.Instant) throws {
        guard maxModelTurns > 0, maxToolCalls >= 0 else { throw AgentLoopError.invalidBudget }
        self.maxModelTurns = maxModelTurns
        self.maxToolCalls = maxToolCalls
        self.deadline = deadline
        self.gate = OperationDeadlineGate(deadline: deadline)
    }

    private init(copying budget: AgentBudget) {
        maxModelTurns = budget.maxModelTurns
        maxToolCalls = budget.maxToolCalls
        deadline = budget.deadline
        gate = budget.gate.renewed()
    }

    /// The same limits for a new Run.
    func renewed() -> AgentBudget { AgentBudget(copying: self) }

    func checkActive() throws {
        try gate.checkActive(timeoutError: AgentLoopError.deadlineExceeded)
    }
}
