import AgentModels
import Foundation

/// Durable request-authority retirement. Canonical messages and execution facts
/// remain unchanged. This is neither a model answer nor a mutation receipt.
public struct AgentContextHandoff: Codable, Equatable, Sendable {
    public let id: UUID
    public let generation: UInt64
    public let previousHandoffID: UUID?
    public let canonicalMessageCount: Int
    public let lastMessageID: UUID?
    public let retiredNativeCheckpointID: UUID?
    public let retiredControlsDigest: String
    public let completedRunID: UUID?
    public let targetOrigin: ModelProviderContinuationOrigin
    public let targetRootDigest: String
    public let targetControls: ModelConversationControlState?

    init(id: UUID = UUID(), generation: UInt64, previousHandoffID: UUID?, canonicalMessageCount: Int,
         lastMessageID: UUID?, retiredNativeCheckpointID: UUID?, retiredControlsDigest: String,
         completedRunID: UUID?, targetOrigin: ModelProviderContinuationOrigin, targetRootDigest: String,
         targetControls: ModelConversationControlState?) throws {
        guard generation > 0, canonicalMessageCount > 0, !retiredControlsDigest.isEmpty, !targetRootDigest.isEmpty,
              targetControls.map({ $0.generation == 1 && $0.origin == targetOrigin && $0.rootConfigurationDigest == targetRootDigest
                  && $0.entries.isEmpty && $0.lastBoundaryMessageCount == canonicalMessageCount }) ?? true else {
            throw AgentJournalError.invalidRecord
        }
        self.id = id; self.generation = generation; self.previousHandoffID = previousHandoffID
        self.canonicalMessageCount = canonicalMessageCount; self.lastMessageID = lastMessageID
        self.retiredNativeCheckpointID = retiredNativeCheckpointID; self.retiredControlsDigest = retiredControlsDigest
        self.completedRunID = completedRunID; self.targetOrigin = targetOrigin
        self.targetRootDigest = targetRootDigest; self.targetControls = targetControls
    }
    private enum CodingKeys: String, CodingKey {
        case id, generation, previousHandoffID, canonicalMessageCount, lastMessageID, retiredNativeCheckpointID
        case retiredControlsDigest, completedRunID, targetOrigin, targetRootDigest, targetControls
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), generation: c.decode(UInt64.self, forKey: .generation),
            previousHandoffID: c.decodeIfPresent(UUID.self, forKey: .previousHandoffID), canonicalMessageCount: c.decode(Int.self, forKey: .canonicalMessageCount),
            lastMessageID: c.decodeIfPresent(UUID.self, forKey: .lastMessageID), retiredNativeCheckpointID: c.decodeIfPresent(UUID.self, forKey: .retiredNativeCheckpointID),
            retiredControlsDigest: c.decode(String.self, forKey: .retiredControlsDigest), completedRunID: c.decodeIfPresent(UUID.self, forKey: .completedRunID),
            targetOrigin: c.decode(ModelProviderContinuationOrigin.self, forKey: .targetOrigin), targetRootDigest: c.decode(String.self, forKey: .targetRootDigest),
            targetControls: c.decodeIfPresent(ModelConversationControlState.self, forKey: .targetControls))
    }

    func ordinaryView(_ canonical: [ModelMessage]) throws -> [ModelMessage] {
        let leading = canonical.prefix { $0.role == .system || $0.role == .developer }.count
        guard canonicalMessageCount <= canonical.count - leading else { throw AgentJournalError.concurrentWriter }
        return canonical.enumerated().map { index, message in
            guard index >= leading, index < leading + canonicalMessageCount,
                  case .assistant(let content, let calls) = message else { return message }
            return .assistant(content: content.filter { if case .providerContinuation = $0 { false } else { true } }, toolCalls: calls)
        }
    }

    /// A custom projector cannot restore retired wire payloads, even for the same deployment.
    func rejectReinjection(_ projected: [ModelMessage], canonical: [ModelMessage]) throws {
        let leading = canonical.prefix { $0.role == .system || $0.role == .developer }.count
        var allowed: [ModelProviderContinuation: Int] = [:]
        for message in canonical.dropFirst(leading + canonicalMessageCount) {
            if case .assistant(let content, _) = message {
                for part in content { if case .providerContinuation(let value) = part { allowed[value, default: 0] += 1 } }
            }
        }
        for message in projected {
            guard case .assistant(let content, _) = message else { continue }
            for part in content {
                if case .providerContinuation(let value) = part {
                    guard allowed[value, default: 0] > 0 else { throw AgentModelBindingError.invalidProjection }
                    allowed[value, default: 0] -= 1
                }
            }
        }
    }
}

/// `wait` observes logical publication; `waitForDrain` also observes projection
/// completion and ownership release. Cancelling a wait does not cancel the operation.
public struct AgentContextHandoffOperation: Sendable {
    public let id: UUID
    public let sessionID: UUID
    private let control: AgentContextHandoffControl
    private let drain: AgentRunDrain
    init(id: UUID, sessionID: UUID, control: AgentContextHandoffControl, drain: AgentRunDrain) {
        self.id = id; self.sessionID = sessionID; self.control = control; self.drain = drain
    }
    public func wait() async throws -> AgentContextHandoff { try await control.wait() }
    public func cancel() async { await control.cancel() }
    public func waitForDrain() async throws { try await drain.wait() }
}

actor AgentContextHandoffControl {
    private var worker: Task<Void, Never>?
    private var result: Result<AgentContextHandoff, Error>?
    private var waiters: [UUID: CheckedContinuation<AgentContextHandoff, Error>] = [:]
    private var sealed = false
    func start(_ operation: @escaping @Sendable () async -> Result<AgentContextHandoff, Error>) {
        worker = Task { complete(await operation()) }
    }
    func seal() throws { try Task.checkCancellation(); sealed = true }
    func cancel() { if !sealed, result == nil { worker?.cancel() } }
    func wait() async throws -> AgentContextHandoff {
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
    private func complete(_ value: Result<AgentContextHandoff, Error>) {
        result = value; worker = nil
        let pending = waiters; waiters.removeAll()
        pending.values.forEach { $0.resume(with: value) }
    }
}

