/// A cancellable producer for one model response. This helper performs no retries or tool execution.
public enum ModelEventStream {
    public typealias Emit = @Sendable (ModelEvent) throws -> Void

    public static func make(
        _ produce: @escaping @Sendable (@escaping Emit) async throws -> Void
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !Task.isCancelled else {
                continuation.finish(throwing: CancellationError())
                return
            }
            let producer = Task {
                do {
                    try Task.checkCancellation()
                    try await produce { event in
                        try Task.checkCancellation()
                        if case .terminated = continuation.yield(event) {
                            throw CancellationError()
                        }
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }
}
