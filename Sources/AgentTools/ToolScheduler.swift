import AgentModels
import Foundation

/// Share one scheduler wherever agents operate on the same host resources.
public struct ToolScheduler: Sendable {
    private let coordinator = ToolResourceCoordinator()

    public init() {}

    package func execute(
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
                        try await onFailed(completion.call, error)
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

public enum ToolSchedulerError: Error, Equatable, Sendable {
    case deadlineExceeded
    case toolTimedOut(ToolCallID)
}
