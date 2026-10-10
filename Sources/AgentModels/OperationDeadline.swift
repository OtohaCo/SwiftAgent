import Foundation

/// Decides, for one operation, whether its deadline can still take the result away.
///
/// A deadline answers one question: did the work finish in time? Once the operation's result is
/// settled before the deadline (a model's whole final answer has been received), the time that is
/// left over only covers recording that result; the deadline then no longer turns it into a timeout.
/// Cancellation still ends the operation.
package final class OperationDeadlineGate: @unchecked Sendable {
    private enum State { case running, settled, expired }

    package let deadline: ContinuousClock.Instant
    private let lock = NSLock()
    private var state = State.running

    package init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

    /// A gate for the same deadline that no earlier operation has settled or expired.
    package func renewed() -> OperationDeadlineGate { OperationDeadlineGate(deadline: deadline) }

    package var isSettled: Bool { lock.withLock { state == .settled } }

    /// Marks the result as in time. False if the deadline already passed or took the operation.
    package func settle(now: ContinuousClock.Instant = .now) -> Bool {
        lock.withLock {
            switch state {
            case .settled: return true
            case .expired: return false
            case .running:
                guard now < deadline else {
                    state = .expired
                    return false
                }
                state = .settled
                return true
            }
        }
    }

    /// The operation needs more work after all (for example, input arrived that asks for another model turn):
    /// the deadline applies to it again.
    package func reopen() {
        lock.withLock { if state == .settled { state = .running } }
    }

    /// The deadline timer fired. False if the result was settled first and must stay.
    package func expire() -> Bool {
        lock.withLock {
            if state == .settled { return false }
            state = .expired
            return true
        }
    }

    package func checkActive(timeoutError: any Error) throws {
        try Task.checkCancellation()
        guard isSettled || ContinuousClock.now < deadline else { throw timeoutError }
    }
}

/// Settles once without joining a host operation that ignores cancellation.
/// The cancelled operation can finish later, but its result cannot settle the caller again.
/// With a `gate`, a result settled in time is returned even if the deadline passes while it is recorded.
package func withOperationDeadline<Value: Sendable>(
    _ deadline: ContinuousClock.Instant,
    timeoutError: any Error,
    gate: OperationDeadlineGate? = nil,
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
            if let gate, !gate.expire() { return }
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
        guard gate?.isSettled == true || ContinuousClock.now < deadline else { throw timeoutError }
        return value
    } catch {
        try Task.checkCancellation()
        guard gate?.isSettled == true || ContinuousClock.now < deadline else { throw timeoutError }
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
