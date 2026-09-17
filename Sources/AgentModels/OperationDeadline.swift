/// Settles once without joining a host operation that ignores cancellation.
/// The cancelled operation can finish later, but its result cannot settle the caller again.
package func withOperationDeadline<Value: Sendable>(
    _ deadline: ContinuousClock.Instant,
    timeoutError: any Error,
    operation: @escaping @Sendable () async throws -> Value,
    onOperationFinished: @escaping @Sendable () async -> Void = {}
) async throws -> Value {
    do {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw timeoutError }
    } catch {
        // The caller may have registered the operation before this preflight.
        await onOperationFinished()
        throw error
    }
    let race = OperationDeadlineResult<Value>()
    let worker = Task {
        do {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw timeoutError }
            let value = try await operation()
            await onOperationFinished()
            await race.resolve(.success(value))
        } catch {
            await onOperationFinished()
            await race.resolve(.failure(error))
        }
    }
    let timer = Task {
        do {
            try await ContinuousClock().sleep(until: deadline)
            worker.cancel()
            await race.resolve(.failure(timeoutError))
        } catch { /* Timer cancellation means another outcome won. */ }
    }
    defer { worker.cancel(); timer.cancel() }
    do {
        let value = try await withTaskCancellationHandler {
            try await race.wait()
        } onCancel: {
            worker.cancel()
            timer.cancel()
            Task { await race.resolve(.failure(CancellationError())) }
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw timeoutError }
        return value
    } catch {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw timeoutError }
        throw error
    }
}

private actor OperationDeadlineResult<Value: Sendable> {
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            if let result { continuation.resume(with: result) }
            else { self.continuation = continuation }
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
