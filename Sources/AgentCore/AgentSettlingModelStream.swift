import AgentModels

/// Hands a model source's events to the Run as they arrive, and notes the moment a final answer is whole.
///
/// The Run reads events one at a time, between other work, so it can be behind the model source when
/// the deadline passes. A final answer the source had already sent whole before the deadline is then settled on
/// the gate, so the Run still finishes it instead of ending as out of time. Only a response that ends
/// the Run (no tool calls to run, not cancelled) settles; anything else is still work the deadline limits.
func settlingModelEvents(
    _ upstream: AsyncThrowingStream<ModelEvent, Error>,
    gate: OperationDeadlineGate
) -> AsyncThrowingStream<ModelEvent, Error> {
    AsyncThrowingStream { continuation in
        let pump = Task {
            let closer = LateCloser(gate: gate, continuation: continuation)
            do {
                for try await event in upstream {
                    if case .responseCompleted(let response) = event,
                       response.stopReason != .toolCalls, response.stopReason != .cancelled,
                       gate.settle() {
                        // The answer is in. A source that then keeps its stream open past the deadline
                        // cannot keep the Run waiting for a close that adds nothing to the answer.
                        closer.start()
                    }
                    if case .terminated = continuation.yield(event) { break }
                }
                closer.cancel()
                continuation.finish()
            } catch {
                closer.cancel()
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in pump.cancel() }
    }
}

private final class LateCloser: @unchecked Sendable {
    private let gate: OperationDeadlineGate
    private let continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation
    private var task: Task<Void, Never>?

    init(gate: OperationDeadlineGate, continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation) {
        self.gate = gate
        self.continuation = continuation
    }

    func start() {
        let gate = gate, continuation = continuation
        task = Task {
            do { try await ContinuousClock().sleep(until: gate.deadline) } catch { return }
            continuation.finish()
        }
    }

    func cancel() { task?.cancel() }
}
