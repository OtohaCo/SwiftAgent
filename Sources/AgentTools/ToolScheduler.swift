import AgentModels
import Foundation

/// Share one scheduler wherever agents operate on the same host resources.
/// Two Sessions that can mutate the same workspace, account, or other unique
/// object must use the same instance. Isolation is per scheduler, not per
/// Session.
public struct ToolScheduler: Sendable {
    private let coordinator = ToolResourceCoordinator()
    private let drain = ToolExecutionDrain()
    private let operationCancellationDidResolve: (@Sendable (UUID, UUID, ToolCallID) async -> Void)?
    private let authorization: ToolAuthorizationTiming
    private let authorizationWaitLimit: Duration?
    private let leaseWaitLimit: Duration?

    /// A call's time is spent in three parts, each with its own limit (OAI-1519):
    /// - its authorization before the lease (`beforeResourceLease`, or audited authorization) is bounded by
    ///   `authorizationWaitLimit`, or by the Run's deadline alone when nil. Past the limit the call is told to
    ///   the model as unanswered (`not_answered`) and never runs;
    /// - its wait for the resource lease is bounded by `leaseWaitLimit`, or by the Run's deadline alone. Past the
    ///   limit the model is told the resource is busy (`busy`) and the call never runs;
    /// - the tool's `ToolPolicy.timeout` starts once the lease is held, just before the invocation, and covers
    ///   the rest: the admission checks, the mutation intent and the executor. Under `whileHoldingResourceLease`
    ///   the tool's authorization is part of that invocation and of its timeout.
    /// Under audited authorization, a wait past either limit fails the call with `toolTimedOut`, as before.
    public init(authorization: ToolAuthorizationTiming = .beforeResourceLease,
                authorizationWaitLimit: Duration? = nil, leaseWaitLimit: Duration? = nil) {
        operationCancellationDidResolve = nil
        self.authorization = authorization
        self.authorizationWaitLimit = authorizationWaitLimit
        self.leaseWaitLimit = leaseWaitLimit
    }

    package init(
        authorization: ToolAuthorizationTiming = .beforeResourceLease,
        authorizationWaitLimit: Duration? = nil, leaseWaitLimit: Duration? = nil,
        operationCancellationDidResolve: @escaping @Sendable (UUID, UUID, ToolCallID) async -> Void
    ) {
        self.operationCancellationDidResolve = operationCancellationDidResolve
        self.authorization = authorization
        self.authorizationWaitLimit = authorizationWaitLimit
        self.leaseWaitLimit = leaseWaitLimit
    }

    /// Wait until all work belonging to one run has returned from its host
    /// executor, including work that outlived a timeout or cancellation.
    public func waitForRunToDrain(sessionID: UUID, runID: UUID) async {
        await drain.wait(.init(sessionID: sessionID, runID: runID))
    }

    package func waitForRunToDrain(
        sessionID: UUID,
        runID: UUID,
        waiterDidRegister: @escaping @Sendable (Bool) -> Void
    ) async {
        await drain.wait(.init(sessionID: sessionID, runID: runID), waiterDidRegister: waiterDidRegister)
    }

    package func pendingWaiterCount() async -> Int {
        await coordinator.pendingWaiterCount
    }

    package func waitUntilPendingWaiterCountEquals(_ expected: Int) async {
        await coordinator.waitUntilPendingWaiterCountEquals(expected)
    }

    package func execute(
        _ calls: [PreparedToolCall], deadline: ContinuousClock.Instant,
        onStarted: @escaping @Sendable (PreparedToolCall) async throws -> Void,
        onCompleted: @escaping @Sendable (Int, PreparedToolCall, ToolResult<JSONValue>) async throws -> Void,
        onFailed: @escaping @Sendable (PreparedToolCall, any Error) async throws -> Void
    ) async throws {
        guard let first = calls.first else { return }
        let drainKey = ToolExecutionDrain.Key(
            sessionID: first.contextSessionID,
            runID: first.contextRunID
        )
        await drain.begin(drainKey)
        do {
            try await executeRegistered(
                calls,
                deadline: deadline,
                onStarted: onStarted,
                onCompleted: onCompleted,
                onFailed: onFailed
            )
            await drain.end(drainKey)
        } catch {
            await drain.end(drainKey)
            throw error
        }
    }

    private func executeRegistered(
        _ calls: [PreparedToolCall], deadline: ContinuousClock.Instant,
        onStarted: @escaping @Sendable (PreparedToolCall) async throws -> Void,
        onCompleted: @escaping @Sendable (Int, PreparedToolCall, ToolResult<JSONValue>) async throws -> Void,
        onFailed: @escaping @Sendable (PreparedToolCall, any Error) async throws -> Void
    ) async throws {
        var cursor = 0
        while cursor < calls.count {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ToolSchedulerError.deadlineExceeded }
            var end = cursor + 1
            if isParallel(calls[cursor]) {
                while end < calls.count, isParallel(calls[end]) { end += 1 }
            }
            try await executeGroup(calls, range: cursor..<end, deadline: deadline,
                                   onStarted: onStarted, onCompleted: onCompleted, onFailed: onFailed)
            cursor = end
        }
    }

    private struct Completion: Sendable {
        let index: Int
        let call: PreparedToolCall
        let result: Result<ToolResult<JSONValue>, Error>
    }

    private func executeGroup(
        _ calls: [PreparedToolCall], range: Range<Int>, deadline: ContinuousClock.Instant,
        onStarted: @escaping @Sendable (PreparedToolCall) async throws -> Void,
        onCompleted: @escaping @Sendable (Int, PreparedToolCall, ToolResult<JSONValue>) async throws -> Void,
        onFailed: @escaping @Sendable (PreparedToolCall, any Error) async throws -> Void
    ) async throws {
        var firstFailure: (any Error)?
        try await withThrowingTaskGroup(of: Completion.self) { group in
            for index in range {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ToolSchedulerError.deadlineExceeded }
                let call = calls[index]
                try await onStarted(call)
                group.addTask {
                    do {
                        let result = try await run(call, deadline: deadline)
                        return Completion(index: index, call: call, result: .success(result))
                    } catch {
                        if error is CancellationError {
                            await operationCancellationDidResolve?(
                                call.contextSessionID,
                                call.contextRunID,
                                call.call.id
                            )
                        }
                        return Completion(index: index, call: call, result: .failure(error))
                    }
                }
            }
            for try await completion in group {
                do {
                    switch completion.result {
                    case .success(let value): try await onCompleted(completion.index, completion.call, value)
                    case .failure(let error):
                        if firstFailure == nil { firstFailure = error }
                        // Independent reads settle under their own deadlines; failure stops subsequent groups.
                        do {
                            try await onFailed(completion.call, error)
                        } catch {
                            firstFailure = error
                        }
                    }
                } catch {
                    if firstFailure == nil { firstFailure = error }
                    group.cancelAll()
                }
            }
        }
        try Task.checkCancellation()
        if let firstFailure { throw firstFailure }
    }

    /// One call: authorization, lease wait and invocation, each under its own deadline (see `init`).
    private func run(_ call: PreparedToolCall, deadline: ContinuousClock.Instant) async throws -> ToolResult<JSONValue> {
        let drainKey = ToolExecutionDrain.Key(sessionID: call.contextSessionID, runID: call.contextRunID)
        let audited = call.auditAuthorization != nil
        func limited(_ limit: Duration?) -> ContinuousClock.Instant {
            limit.map { min(deadline, ContinuousClock.now.advanced(by: $0)) } ?? deadline
        }
        // Human/network authorization holds no scheduler resource lease.
        var admitted = call
        if audited || authorization == .beforeResourceLease {
            let authorizationDeadline = limited(authorizationWaitLimit)
            await drain.begin(drainKey)
            do {
                admitted = try await withOperationDeadline(authorizationDeadline,
                    timeoutError: authorizationDeadline == deadline ? ToolSchedulerError.deadlineExceeded : WaitExpired()) {
                    if audited {
                        try await call.preauthorizeAudit(deadline: authorizationDeadline)
                        return call
                    }
                    return try await call.authorizedBeforeLease(deadline: authorizationDeadline)
                } onOperationFinished: {
                    await drain.end(drainKey)
                }
            } catch let refusal as ToolPreAdmissionRefusal {
                // Refused before the lease: nothing ran and no intent exists (ADR 0016).
                return refusal.result
            } catch is WaitExpired {
                if audited { throw ToolSchedulerError.toolTimedOut(call.call.id) }
                return ToolPreAdmissionRefusal.notAnswered.result
            }
        }
        try Task.checkCancellation()
        let leaseDeadline = limited(leaseWaitLimit)
        let lease: UUID
        do {
            lease = try await coordinator.acquire(resources: call.resources, effect: call.policy.effect,
                                                  execution: call.policy.execution, until: leaseDeadline)
        } catch is ToolResourceCoordinator.WaitExpired {
            if leaseDeadline == deadline { throw ToolSchedulerError.deadlineExceeded }
            if audited { throw ToolSchedulerError.toolTimedOut(call.call.id) }
            return ToolPreAdmissionRefusal.busy.result
        }
        // The tool's own timeout starts here, with the lease held.
        let toolDeadline = min(deadline, ContinuousClock.now.advanced(by: call.policy.timeout))
        let timeoutError: ToolSchedulerError = toolDeadline == deadline ? .deadlineExceeded : .toolTimedOut(call.call.id)
        let leased = admitted
        await drain.begin(drainKey)
        return try await withOperationDeadline(toolDeadline, timeoutError: timeoutError) {
            try Task.checkCancellation()
            return try await leased.invoke(deadline: toolDeadline)
        } onOperationFinished: {
            // An executor that outlives its timeout keeps the lease until it physically returns.
            await coordinator.release(lease)
            await drain.end(drainKey)
        }
    }

    private struct WaitExpired: Error {}

    private func isParallel(_ call: PreparedToolCall) -> Bool {
        call.policy.effect == .readOnly && call.policy.execution == .parallel
    }
}

private actor ToolExecutionDrain {
    struct Key: Hashable, Sendable {
        let sessionID: UUID
        let runID: UUID
    }

    private var active: [Key: Int] = [:]
    private var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]

    func begin(_ key: Key) {
        active[key, default: 0] += 1
    }

    func end(_ key: Key) {
        guard let count = active[key] else { return }
        guard count == 1 else {
            active[key] = count - 1
            return
        }
        active.removeValue(forKey: key)
        let continuations = waiters.removeValue(forKey: key) ?? []
        continuations.forEach { $0.resume() }
    }

    func wait(_ key: Key, waiterDidRegister: (@Sendable (Bool) -> Void)? = nil) async {
        guard active[key] != nil else {
            waiterDidRegister?(false)
            return
        }
        await withCheckedContinuation { continuation in
            if active[key] != nil {
                waiters[key, default: []].append(continuation)
                waiterDidRegister?(true)
            } else {
                waiterDidRegister?(false)
                continuation.resume()
            }
        }
    }
}

/// When a tool's own `authorize` runs relative to the scheduler's resource lease. Audited
/// authorization (`AgentConfiguration.authorization`) always runs before the lease.
public enum ToolAuthorizationTiming: Sendable, Equatable {
    /// `authorize`, which may wait for a person, runs before the call waits for its lease, so an
    /// unanswered call holds nothing another call needs. The executor runs later under the lease,
    /// after Evidence and scope are checked again; it must recheck any state the decision relied on
    /// (versioned reads or conditional writes), because other calls may have changed it meanwhile.
    case beforeResourceLease
    /// `authorize` runs after the lease is acquired, immediately before the executor: decision and
    /// effect see the same state, but every conflicting call waits for the answer.
    case whileHoldingResourceLease
}

public enum ToolSchedulerError: Error, Equatable, Sendable {
    case deadlineExceeded
    case toolTimedOut(ToolCallID)
}
