import Foundation

/// One execution owned by a Session. The public surface is events, cancel,
/// steer, wait and waitForDrain. The backing Task and scheduler handles are
/// not exposed.
///
/// `wait()` returns when the Agent has produced a logical terminal outcome.
/// That does not mean provider or tool work has exited, or that Session
/// identity is free. `waitForDrain()` waits for that physical release.
/// Both methods share the Session's drain owner; they do not start a second
/// drain.
///
/// `events` is a single-consumer stream. Cancelling the observer does not
/// cancel the Run; call `cancel()` to stop execution. `wait()` may be used
/// by several callers and returns the same terminal result.
public struct AgentRun: Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let binding: AgentModelBindingInfo
    public let events: AsyncStream<AgentEvent>
    private let control: AgentRunControl
    private let drain: AgentRunDrain

    init(
        id: UUID,
        sessionID: UUID,
        binding: AgentModelBindingInfo,
        events: AsyncStream<AgentEvent>,
        control: AgentRunControl,
        drain: AgentRunDrain
    ) {
        self.id = id
        self.sessionID = sessionID
        self.binding = binding
        self.events = events
        self.control = control
        self.drain = drain
    }

    public func wait() async throws -> AgentLoopResult { try await control.wait() }
    public func waitForDrain() async throws { try await drain.wait() }
    public func cancel() async { await control.cancel() }
    @discardableResult
    public func steer(_ text: String) async throws -> UUID { try await control.enqueue(text) }

    func waitForDrain(waiterDidRegister: @escaping @Sendable (Bool) -> Void) async throws {
        try await drain.wait(waiterDidRegister: waiterDidRegister)
    }

    func isDrainComplete() async -> Bool { await drain.isComplete }
}

public enum AgentRunError: Error, Equatable, Sendable {
    case emptySteering
    case finished
}

struct AgentSteeringInput: Sendable {
    let id: UUID
    let text: String
}

actor AgentRunControl {
    private var worker: Task<Void, Never>?
    private var result: Result<AgentLoopResult, Error>?
    private var cancelled = false
    private var finishing = false
    private var steering: [AgentSteeringInput] = []
    private var delivering: [AgentSteeringInput] = []
    private var waiters: [UUID: CheckedContinuation<AgentLoopResult, Error>] = [:]
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    func start(_ operation: @escaping @Sendable () async -> Result<AgentLoopResult, Error>) {
        worker = Task {
            let result = await operation()
            complete(result)
        }
        if cancelled { worker?.cancel() }
    }

    func cancel() {
        guard result == nil, !finishing else { return }
        cancelled = true
        worker?.cancel()
    }

    func beginFinish() -> [AgentSteeringInput] {
        finishing = true
        let pending = delivering + steering
        delivering.removeAll()
        steering.removeAll()
        return pending
    }

    func takeSteering(atTermination: Bool) throws -> [AgentSteeringInput] {
        try Task.checkCancellation()
        guard !cancelled, !finishing else { throw CancellationError() }
        let inputs = steering
        steering.removeAll()
        delivering.append(contentsOf: inputs)
        if inputs.isEmpty && atTermination { finishing = true }
        return inputs
    }

    func acknowledge(_ inputs: [AgentSteeringInput]) {
        let ids = Set(inputs.map(\.id))
        delivering.removeAll { ids.contains($0.id) }
    }

    func enqueue(_ text: String) throws -> UUID {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentRunError.emptySteering }
        guard !finishing, !cancelled, result == nil else { throw AgentRunError.finished }
        let input = AgentSteeringInput(id: UUID(), text: text)
        steering.append(input)
        return input.id
    }

    func wait() async throws -> AgentLoopResult {
        try Task.checkCancellation()
        if let result { return try result.get() }
        let waiterID = UUID()
        let value: AgentLoopResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AgentLoopResult, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[waiterID] = continuation }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        try Task.checkCancellation()
        return value
    }

    func waitUntilCompleted() async {
        if result != nil { return }
        await withCheckedContinuation { continuation in
            if result != nil {
                continuation.resume()
            } else {
                completionWaiters.append(continuation)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func complete(_ result: Result<AgentLoopResult, Error>) {
        guard self.result == nil else { return }
        self.result = result
        worker = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values { waiter.resume(with: result) }
        let completions = completionWaiters
        completionWaiters.removeAll()
        for waiter in completions { waiter.resume() }
    }
}

actor AgentRunDrain {
    private var completed = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    var isComplete: Bool { completed }

    func wait(waiterDidRegister: (@Sendable (Bool) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        if completed {
            waiterDidRegister?(false)
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    waiterDidRegister?(false)
                    continuation.resume(throwing: CancellationError())
                } else if completed {
                    waiterDidRegister?(false)
                    continuation.resume()
                } else {
                    waiters[waiterID] = continuation
                    waiterDidRegister?(true)
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        })
        try Task.checkCancellation()
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func complete() {
        guard !completed else { return }
        completed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values { waiter.resume() }
    }
}
