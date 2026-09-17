import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct ToolInvocationTests {
    private let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "call-1"))
    private let arguments: JSONValue = .object(["value": .number(7)])

    @Test func defaultAuthorizationRejectsBeforeExecutor() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1))
        let tool = try AnyAgentTool(RecordingTool(policy: policy, log: log))
        await #expect(throws: ToolInvocationError.authorizationDenied) { try await tool.invoke(arguments: arguments, context: context) }
        #expect(await log.contexts.isEmpty)
    }

    @Test func mutationAndReceiptRequirementsCannotBeBypassedWithTypedOutput() async throws {
        for policy in [
            try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .safe,
                           timeout: .seconds(1), authorization: .notRequired),
            try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .requiresReceipt,
                           timeout: .seconds(1), authorization: .notRequired),
        ] {
            let log = InvocationLog()
            let tool = try AnyAgentTool(RecordingTool(policy: policy, log: log))
            await #expect(throws: (any Error).self) { try await tool.invoke(arguments: arguments, context: context) }
            #expect(await log.contexts.isEmpty)
        }
    }

    @Test func typedAuthorizationReceivesInputAndInvocationIdentity() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe, timeout: .seconds(1))
        let tool = try AnyAgentTool(AuthorizedTool(base: RecordingTool(policy: policy, log: log), runID: context.runID))
        let result = try await tool.invoke(arguments: arguments, context: context)
        #expect(result.output == .number(7))
        await #expect(throws: ToolInvocationError.authorizationDenied) {
            try await tool.invoke(arguments: .object(["value": .number(8)]), context: context)
        }
        #expect(await log.contexts == [context])
    }

    @Test func invalidTypedInputCannotReachExecutorAndInvalidOutputIsIdentified() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let tool = try AnyAgentTool(RecordingTool(policy: policy, log: log, output: .nan))
        for args: JSONValue in [.object([:]), .object(["value": .string("7")]), .object(["value": .number(1.5)])] {
            await #expect(throws: ToolInvocationError.invalidArguments) {
                try await tool.invoke(arguments: args, context: context)
            }
        }
        #expect(await log.contexts.isEmpty)
        await #expect(throws: ToolInvocationError.invalidOutput) {
            try await tool.invoke(arguments: arguments, context: context)
        }
        #expect(await log.contexts == [context])
    }

    @Test func keyedInvocationRequiresAndPreservesItsKey() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .keyed,
                                    timeout: .seconds(1), authorization: .notRequired)
        let tool = try AnyAgentTool(RecordingTool(policy: policy, log: log))
        for key in [nil, "", " "] as [String?] {
            let invalid = ToolContext(sessionID: context.sessionID, runID: context.runID, callID: context.callID, idempotencyKey: key)
            await #expect(throws: ToolInvocationError.missingIdempotencyKey) {
                try await tool.invoke(arguments: arguments, context: invalid)
            }
        }
        #expect(await log.contexts.isEmpty)
        let keyed = ToolContext(sessionID: context.sessionID, runID: context.runID, callID: context.callID, idempotencyKey: "op-1")
        _ = try await tool.invoke(arguments: arguments, context: keyed)
        #expect(await log.contexts == [keyed])
    }

    @Test func expiredDeadlineRejectsBeforeExecutor() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let tool = try AnyAgentTool(RecordingTool(policy: policy, log: log))
        let expired = ToolContext(sessionID: context.sessionID, runID: context.runID, callID: context.callID,
                                  deadline: .now.advanced(by: .seconds(-1)))
        await #expect(throws: ToolInvocationError.deadlineExceeded) {
            try await tool.invoke(arguments: arguments, context: expired)
        }
        #expect(await log.contexts.isEmpty)
    }

    @Test func cancellationDuringAuthorizationCannotStartExecutor() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1))
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let entered = XCTestExpectation(description: "Authorization entered")
        let tool = try AnyAgentTool(ControlledTool(base: RecordingTool(policy: policy, log: log)) { _, _ in
            entered.fulfill()
            for await _ in gate.stream {}
            return .allowed
        })
        let task = Task { try await tool.invoke(arguments: arguments, context: context) }
        defer { task.cancel() }
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await log.contexts.isEmpty)
    }

    @Test func alreadyCancelledInvocationDoesNotReachExecutor() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let tool = try AnyAgentTool(RecordingTool(policy: policy, log: log))
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let task = Task {
            for await _ in gate.stream {}
            return try await tool.invoke(arguments: arguments, context: context)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await log.contexts.isEmpty)
    }

    @Test func authorizationErrorsDoNotReachExecutor() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1))
        let tool = try AnyAgentTool(ControlledTool(base: RecordingTool(policy: policy, log: log)) { _, _ in
            throw AuthorizationFailure.unavailable
        })
        await #expect(throws: AuthorizationFailure.self) { try await tool.invoke(arguments: arguments, context: context) }
        #expect(await log.contexts.isEmpty)
    }

    @Test func authorizationFinishingPastDeadlineDoesNotReachExecutor() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe, timeout: .seconds(1))
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        let limited = ToolContext(sessionID: context.sessionID, runID: context.runID, callID: context.callID, deadline: deadline)
        let tool = try AnyAgentTool(ControlledTool(base: RecordingTool(policy: policy, log: log)) { _, _ in
            try await ContinuousClock().sleep(until: deadline)
            return .allowed
        })
        await #expect(throws: ToolInvocationError.deadlineExceeded) { try await tool.invoke(arguments: arguments, context: limited) }
        #expect(await log.contexts.isEmpty)
    }

    @Test func cancellationDuringExecutorCannotProduceOutput() async throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let entered = XCTestExpectation(description: "Executor entered")
        let tool = try AnyAgentTool(ExecutionTool(policy: policy) { _, _ in
            entered.fulfill()
            for await _ in gate.stream {}
            return ToolResult(output: 7)
        })
        let task = Task { try await tool.invoke(arguments: arguments, context: context) }
        defer { task.cancel() }
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func executorFinishingPastDeadlineCannotProduceOutput() async throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        let limited = ToolContext(sessionID: context.sessionID, runID: context.runID, callID: context.callID, deadline: deadline)
        let tool = try AnyAgentTool(ExecutionTool(policy: policy) { _, _ in
            try await ContinuousClock().sleep(until: deadline)
            return ToolResult(output: 7)
        })
        await #expect(throws: ToolInvocationError.deadlineExceeded) { try await tool.invoke(arguments: arguments, context: limited) }
    }
}

actor InvocationLog {
    private(set) var contexts: [ToolContext] = []
    func record(_ context: ToolContext) { contexts.append(context) }
}

struct RecordingTool: AgentTool {
    struct Input: Codable, Sendable { let value: Int }
    typealias Output = Double
    static let name = "recording"
    static let description = "Read a resource value"
    static let inputSchema = ToolSchema.object(properties: ["value": .integer], required: ["value"])
    static let outputSchema = ToolSchema.number
    let policy: ToolPolicy
    let log: InvocationLog
    var output = 7.0

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record(context)
        return ToolResult(output: output)
    }
}

struct AuthorizedTool: AgentTool {
    typealias Input = RecordingTool.Input
    typealias Output = RecordingTool.Output
    static let name = "authorized"
    static let description = RecordingTool.description
    static let inputSchema = RecordingTool.inputSchema
    static let outputSchema = RecordingTool.outputSchema
    let base: RecordingTool
    let runID: UUID
    var policy: ToolPolicy { base.policy }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        input.value == 7 && context.runID == runID ? .allowed : .denied
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        try await base.execute(input, context: context)
    }
}

struct ControlledTool: AgentTool {
    typealias Input = RecordingTool.Input
    typealias Output = RecordingTool.Output
    static let name = "controlled"
    static let description = RecordingTool.description
    static let inputSchema = RecordingTool.inputSchema
    static let outputSchema = RecordingTool.outputSchema
    let base: RecordingTool
    let authorization: @Sendable (Input, ToolContext) async throws -> ToolAuthorization
    var policy: ToolPolicy { base.policy }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        try await authorization(input, context)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        try await base.execute(input, context: context)
    }
}

enum AuthorizationFailure: Error { case unavailable }

struct ExecutionTool: AgentTool {
    typealias Input = RecordingTool.Input
    typealias Output = RecordingTool.Output
    static let name = "execution"
    static let description = RecordingTool.description
    static let inputSchema = RecordingTool.inputSchema
    static let outputSchema = RecordingTool.outputSchema
    let policy: ToolPolicy
    let operation: @Sendable (Input, ToolContext) async throws -> ToolResult<Output>

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        try await operation(input, context)
    }
}
