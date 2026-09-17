@testable import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentCompletionCommitTests {
    @Test(arguments: [true, false])
    func cancellationAroundCheckpointKeepsHistoryAndEventsConsistent(checkpointCommitted: Bool) async throws {
        let channel = AsyncStream<AgentEvent>.makeStream()
        let emitter = AgentEventEmitter(channel.continuation, requiresConsumer: false)
        let call = ToolCall(id: .init(rawValue: "commit"), name: CommitProbe.name, argumentsJSON: "{}", completeness: .complete)
        let budget = try testBudget()
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: call.id, deadline: budget.deadline, idempotencyKey: "operation")
        let prepared = try ToolRegistry(tools: [AnyAgentTool(CommitProbe())]).prepare(call, context: context)
        try await emitter.send(.toolStarted(call))
        let result = try await prepared.invoke()
        let committed = XCTestExpectation(description: "History committed")
        let gate = ManualGate(), history = CompletionHistory()
        let lifecycle = AgentLoopLifecycle(control: AgentRunControl(), evidenceLedger: EvidenceLedger(), checkpoint: { messages, _ in
            if checkpointCommitted { await history.record(messages) }
            committed.fulfill()
            await gate.wait()
            if !checkpointCommitted {
                try Task.checkCancellation()
                await history.record(messages)
            }
        }, beforeFinish: {})
        let response = ModelResponse(info: .init(id: "response", model: fixtureModel), toolCalls: [call], stopReason: .toolCalls)
        let progress = AgentToolBatchProgress(prefix: [], response: response, budget: budget, lifecycle: lifecycle, emitter: emitter)
        let recording = Task { try await progress.record(index: 0, call: prepared, result: result) }
        #expect(await XCTWaiter.fulfillment(of: [committed], timeout: 1) == .completed)
        recording.cancel()
        let finishing: Task<Void, Never>
        if #available(macOS 26, iOS 26, *) { finishing = await emitter.beginFinishingImmediately(.cancelled) }
        else { finishing = Task { await emitter.finish(.cancelled) } }
        await gate.open()
        _ = try? await recording.value
        await finishing.value
        let events = await collectEvents(channel.stream)
        #expect(await history.messages.contains(.tool(.init(callID: call.id, content: [.json(.number(1))], isError: false))) == checkpointCommitted)
        #expect(events.contains(.toolCompleted(.init(callID: call.id, content: [.json(.number(1))], isError: false))) == checkpointCommitted)
        #expect(events.contains { if case .toolReceiptValidated = $0 { true } else { false } } == checkpointCommitted)
        #expect(events.contains { if case .toolFailed = $0 { true } else { false } } == !checkpointCommitted)
        #expect(events.last == .runFinished(.cancelled))
    }

    @available(macOS 26, iOS 26, *)
    @Test func simultaneousFinishersWaitForOneReservedCompletionAndKeepTheFirstOutcome() async throws {
        let channel = AsyncStream<AgentEvent>.makeStream()
        let emitter = AgentEventEmitter(channel.continuation, requiresConsumer: false)
        let call = addition("reserved")
        try await emitter.send(.toolStarted(call))
        try await emitter.reserveCompletion(call.id)
        let first = await emitter.beginFinishingImmediately(.cancelled)
        let second = await emitter.beginFinishingImmediately(.failed(.unclassified))
        let result = ToolResultMessage(callID: call.id, content: [.json(.number(5))], isError: false)
        try await emitter.commitCompletion(result, receipt: nil)
        await first.value
        await second.value
        #expect(await collectEvents(channel.stream) == [.toolStarted(call), .toolCompleted(result), .runFinished(.cancelled)])
    }

    @Test func failedCheckpointIsNotPromotedByALaterSuccessfulCheckpoint() async throws {
        let channel = AsyncStream<AgentEvent>.makeStream()
        let emitter = AgentEventEmitter(channel.continuation, requiresConsumer: false)
        let calls = [addition("a"), addition("b")]
        let budget = try testBudget()
        let registry = try ToolRegistry(tools: [AnyAgentTool(AddTool(log: EffectLog()))])
        let prepared = try calls.map { try registry.prepare($0, context: .init(sessionID: UUID(), runID: UUID(), callID: $0.id)) }
        let history = FailingCompletionHistory()
        let lifecycle = AgentLoopLifecycle(control: AgentRunControl(), evidenceLedger: EvidenceLedger(), checkpoint: { messages, _ in
            try await history.record(messages)
        }, beforeFinish: {})
        let response = ModelResponse(info: .init(id: "response", model: fixtureModel), toolCalls: calls, stopReason: .toolCalls)
        let progress = AgentToolBatchProgress(prefix: [], response: response, budget: budget, lifecycle: lifecycle, emitter: emitter)
        for call in calls { try await emitter.send(.toolStarted(call)) }
        let first = try await prepared[0].invoke()
        await #expect(throws: FixtureError.invalidOperation) { try await progress.record(index: 0, call: prepared[0], result: first) }
        try await progress.record(index: 1, call: prepared[1], result: prepared[1].invoke())
        await emitter.finish(.failed(.unclassified))
        #expect(await history.messages == [.assistant(content: [], toolCalls: [calls[1]]),
                                          .tool(.init(callID: calls[1].id, content: [.json(.object(["sum": .number(5)]))], isError: false))])
        let events = await collectEvents(channel.stream)
        #expect(events.contains(.toolFailed(calls[0].id, .unclassified)))
        #expect(!events.contains { if case .toolCompleted(let result) = $0 { result.callID == calls[0].id } else { false } })
    }
}

private extension AgentEventEmitter {
    @available(macOS 26, iOS 26, *)
    func beginFinishingImmediately(_ outcome: AgentRunTermination) -> Task<Void, Never> {
        Task.immediate { await self.finish(outcome) }
    }
}

private actor FailingCompletionHistory {
    private var attempts = 0
    private(set) var messages: [ModelMessage] = []
    func record(_ messages: [ModelMessage]) throws {
        attempts += 1
        if attempts == 1 { throw FixtureError.invalidOperation }
        self.messages = messages
    }
}

private actor CompletionHistory {
    private(set) var messages: [ModelMessage] = []
    func record(_ messages: [ModelMessage]) { self.messages = messages }
}

private struct CommitProbe: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = Int
    static let name = "commit_probe"
    static let description = "Read a confirmed resource"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.integer
    let policy: ToolPolicy
    init() throws { policy = try .init(effect: .readOnly, execution: .sequential, idempotency: .requiresReceipt, timeout: .seconds(1), authorization: .notRequired) }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "resource", id: "one")])
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Int> {
        .init(output: 1, receipt: .init(operationID: "operation", status: .succeeded, confirmedTargets: [.init(namespace: "resource", id: "one")]))
    }
}
