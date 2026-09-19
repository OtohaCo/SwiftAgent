import AgentModels
import Foundation

/// Share one scheduler wherever agents operate on the same host resources.
/// Two Sessions that can mutate the same workspace, account, or other unique
/// object must use the same instance. Isolation is per scheduler, not per
/// Session.
public struct ToolScheduler: Sendable {
    private let coordinator = ToolResourceCoordinator()
    private let drain = ToolExecutionDrain()

    public init() {}

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
                let toolDeadline = min(deadline, ContinuousClock.now.advanced(by: call.policy.timeout))
                try await onStarted(call)
                group.addTask {
                    let drainKey = ToolExecutionDrain.Key(
                        sessionID: call.contextSessionID,
                        runID: call.contextRunID
                    )
                    await drain.begin(drainKey)
                    do {
                        let timeoutError: ToolSchedulerError = toolDeadline == deadline ? .deadlineExceeded : .toolTimedOut(call.call.id)
                        let result = try await withOperationDeadline(toolDeadline, timeoutError: timeoutError) {
                            let lease = try await coordinator.acquire(resources: call.resources, effect: call.policy.effect,
                                                                      execution: call.policy.execution)
                            do {
                                try Task.checkCancellation()
                                let result = try await call.invoke(deadline: toolDeadline)
                                await coordinator.release(lease)
                                return result
                            } catch {
                                await coordinator.release(lease)
                                throw error
                            }
                        } onOperationFinished: {
                            await drain.end(drainKey)
                        }
                        return Completion(index: index, call: call, result: .success(result))
                    } catch { return Completion(index: index, call: call, result: .failure(error)) }
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

public enum ToolSchedulerError: Error, Equatable, Sendable {
    case deadlineExceeded
    case toolTimedOut(ToolCallID)
}
