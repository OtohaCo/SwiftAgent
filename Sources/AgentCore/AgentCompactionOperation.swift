import AgentModels
import Foundation

/// Native context maintenance has its own HTTP identity, not a mutation receipt.
/// `wait` is logical completion; `waitForDrain` also waits for transport and ownership release.
public struct AgentCompactionOperation: Sendable {
    public let id: UUID
    public let invocationID: UUID
    public let sessionID: UUID
    public let events: AsyncStream<ModelCompactionEvent>
    private let control: AgentCompactionControl
    private let drain: AgentRunDrain
    init(id: UUID, invocationID: UUID, sessionID: UUID, events: AsyncStream<ModelCompactionEvent>,
         control: AgentCompactionControl, drain: AgentRunDrain) {
        self.id = id; self.invocationID = invocationID; self.sessionID = sessionID
        self.events = events; self.control = control; self.drain = drain
    }
    public func wait() async throws -> AgentCompactionResult { try await control.wait() }
    public func cancel() async { await control.cancel() }
    public func waitForDrain() async throws { try await drain.wait() }
}

public struct AgentCompactionResult: Hashable, Sendable {
    /// Nil means a complete HTTP response did not produce a usable native summary.
    public let checkpoint: ModelNativeContextCheckpoint?
    public let response: ModelCompactionResponse
    public init(checkpoint: ModelNativeContextCheckpoint?, response: ModelCompactionResponse) {
        self.checkpoint = checkpoint; self.response = response
    }
}

actor AgentCompactionControl {
    private var worker: Task<Void, Never>?
    private var result: Result<AgentCompactionResult, Error>?
    private var waiters: [UUID: CheckedContinuation<AgentCompactionResult, Error>] = [:]
    private var sealed = false
    func start(_ operation: @escaping @Sendable () async -> Result<AgentCompactionResult, Error>) {
        worker = Task { complete(await operation()) }
    }
    func seal() throws { try Task.checkCancellation(); sealed = true }
    func cancel() { if !sealed, result == nil { worker?.cancel() } }
    func wait() async throws -> AgentCompactionResult {
        try Task.checkCancellation()
        if let result { return try result.get() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                if Task.isCancelled { c.resume(throwing: CancellationError()) }
                else { waiters[id] = c }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    private func cancelWaiter(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    private func complete(_ value: Result<AgentCompactionResult, Error>) {
        result = value; worker = nil
        let pending = waiters; waiters.removeAll()
        pending.values.forEach { $0.resume(with: value) }
    }
}

/// The same executor is used by idle maintenance and an admitted Run.
struct AgentNativeCompactionExecutor: Sendable {
    let provider: any ModelProviderCompaction
    func execute(_ request: ModelCompactionRequest,
                 emit: @Sendable (ModelCompactionEvent) async throws -> Void) async throws -> ModelCompactionResponse {
        guard provider.compactionModes.contains(request.mode) else {
            throw ModelProviderError(kind: .unsupportedCapability, message: "Native compaction is not qualified for this deployment/mode.")
        }
        try provider.validateCompaction(request: request)
        var completed: ModelCompactionResponse?
        for try await event in provider.compact(request: request) {
            try Task.checkCancellation()
            guard completed == nil else { throw ModelProviderError(kind: .invalidResponse, message: "Compaction events followed the terminal response.") }
            switch event {
            case .usage, .inputTransformations, .progress: try await emit(event)
            case .completed(let response): completed = response
            }
        }
        try Task.checkCancellation()
        guard let completed, completed.info.model == request.request.model else {
            throw ModelProviderError(kind: .invalidResponse, message: "Compaction did not complete for the configured model.")
        }
        return completed
    }
}
