import AgentModels

func withAgentDeadline<Value: Sendable>(
    _ deadline: ContinuousClock.Instant,
    timeoutError: AgentLoopError = .deadlineExceeded,
    gate: OperationDeadlineGate? = nil,
    operation: @escaping @Sendable () async throws -> Value,
    onOperationFinished: @escaping @Sendable () async -> Void = {}
) async throws -> Value {
    try await withOperationDeadline(
        deadline,
        timeoutError: timeoutError,
        gate: gate,
        operation: operation,
        onOperationFinished: onOperationFinished
    )
}
