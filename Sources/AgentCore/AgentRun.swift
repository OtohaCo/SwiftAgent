import Foundation

public struct AgentRun: Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let events: AsyncStream<AgentEvent>
    private let control: AgentRunControl

    init(id: UUID, sessionID: UUID, events: AsyncStream<AgentEvent>, control: AgentRunControl) {
        self.id = id
        self.sessionID = sessionID
        self.events = events
        self.control = control
    }

    public func wait() async throws -> AgentLoopResult { try await control.wait() }
    public func cancel() async { await control.cancel() }
    @discardableResult
    public func steer(_ text: String) async throws -> UUID { try await control.enqueue(text) }
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
    }
}
