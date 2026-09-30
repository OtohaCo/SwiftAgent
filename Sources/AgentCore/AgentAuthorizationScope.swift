import Foundation

/// Process-local policy generation and revocation. Remote policy changes require Host online checks.
/// Sharing this scope does not partition resources or alter mutation identities.
public final class AgentAuthorizationScope: @unchecked Sendable {
    public let id = UUID()
    private let lock = NSLock()
    private var generation: UInt64
    private var revoked = false
    private var runs: [UUID: @Sendable () async -> Void] = [:]
    private var admissions: Set<UUID> = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    public init(policyGeneration: UInt64 = 0) { generation = policyGeneration }
    public var policyGeneration: UInt64 { lock.withLock { generation } }

    public func revoke() async {
        let owners = lock.withLock { revoked = true; return Array(runs.values) }
        for cancel in owners { await cancel() }
    }

    public func advanceGeneration(to next: UInt64) async throws {
        let owners = try lock.withLock {
            guard next > generation, !revoked else { throw AgentAuthorizationError.policyGenerationMismatch }
            generation = next
            return Array(runs.values)
        }
        for cancel in owners { await cancel() }
    }

    package func check(expectedGeneration: UInt64? = nil) throws {
        try lock.withLock { try checkLocked(expectedGeneration) }
    }

    private func checkLocked(_ expected: UInt64?) throws {
        guard !revoked else { throw AgentAuthorizationError.revoked }
        if let expected, expected != generation { throw AgentAuthorizationError.policyGenerationMismatch }
    }

    package func register(runID: UUID, cancel: @escaping @Sendable () async -> Void) throws {
        try lock.withLock {
            try checkLocked(nil)
            guard runs.count < 32, runs[runID] == nil else { throw AgentAuthorizationError.tooManyInvocations }
            runs[runID] = cancel
        }
    }

    package func admit(generation: UInt64, expires: ContinuousClock.Instant) throws -> UUID {
        try lock.withLock {
            try Task.checkCancellation()
            try checkLocked(generation)
            guard ContinuousClock.now < expires else { throw AgentAuthorizationError.expired }
            let ticket = UUID(); admissions.insert(ticket); return ticket
        }
    }

    package func releaseAdmission(_ ticket: UUID) {
        lock.withLock { _ = admissions.remove(ticket) }
    }

    package func releaseRun(_ runID: UUID) {
        let ready: [CheckedContinuation<Void, Error>] = lock.withLock {
            runs.removeValue(forKey: runID)
            guard runs.isEmpty, admissions.isEmpty else { return [] }
            let ready = Array(waiters.values); waiters.removeAll(); return ready
        }
        ready.forEach { $0.resume() }
    }

    public func waitForDrain() async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let immediate = lock.withLock {
                    if Task.isCancelled { return 1 }
                    if runs.isEmpty, admissions.isEmpty { return 2 }
                    waiters[waiterID] = c; return 0
                }
                if immediate == 1 { c.resume(throwing: CancellationError()) }
                if immediate == 2 { c.resume() }
            }
        } onCancel: {
            self.lock.withLock { self.waiters.removeValue(forKey: waiterID) }?.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }
}
