import AgentModels

func withAgentDeadline<Value: Sendable>(
    _ deadline: ContinuousClock.Instant,
    timeoutError: AgentLoopError = .deadlineExceeded,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withOperationDeadline(deadline, timeoutError: timeoutError, operation: operation)
}
