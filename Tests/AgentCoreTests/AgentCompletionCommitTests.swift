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
            return messages
        }, beforeFinish: {})
        let response = ModelResponse(info: .init(id: "response", model: fixtureModel), toolCalls: [call], stopReason: .toolCalls)
        let progress = AgentToolBatchProgress(prefix: [], response: response, budget: budget, lifecycle: lifecycle, emitter: emitter)
        let recording = Task { try await progress.record(index: 0, call: prepared, result: result) }
        #expect(await XCTWaiter.fulfillment(of: [committed], timeout: 1) == .completed)
        recording.cancel()
        let finishing = await emitter.beginFinishing(.cancelled)
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

    @Test func simultaneousFinishersWaitForOneReservedCompletionAndKeepTheFirstOutcome() async throws {
        let channel = AsyncStream<AgentEvent>.makeStream()
        let emitter = AgentEventEmitter(channel.continuation, requiresConsumer: false)
        let call = addition("reserved")
        try await emitter.send(.toolStarted(call))
        try await emitter.reserveCompletion(call.id)
        let first = await emitter.beginFinishing(.cancelled)
        let second = await emitter.beginFinishing(.failed(.unclassified))
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
            return messages
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

    @Test func finishingWaitsForBlockedMutationCommitAndPreservesDurableSettlement() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-completion-reservation-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try makeTestJournal(at: url)
        let sessionID = UUID()
        let runID = UUID()
        let operationID = "completion-reservation-operation"
        let call = ToolCall(
            id: .init(rawValue: "completion-reservation-call"),
            name: CompletionMutationTool.name,
            argumentsJSON: "{}",
            completeness: .complete
        )
        let probe = CompletionMutationProbe()
        let registry = try ToolRegistry(tools: [AnyAgentTool(CompletionMutationTool(probe: probe))])
        let budget = try testBudget()
        let context = ToolContext(
            sessionID: sessionID,
            runID: runID,
            callID: call.id,
            deadline: budget.deadline,
            idempotencyKey: operationID,
            argumentsJSON: call.argumentsJSON,
            evidenceLedger: EvidenceLedger(),
            mutationAdmission: journal
        )
        let prepared = try registry.prepare(call, context: context)
        let result = try await prepared.invoke()
        #expect(await probe.count == 1)
        #expect(try await journal.pendingMutations(sessionID: sessionID).map(\.state) == [.intent])

        let channel = AsyncStream<AgentEvent>.makeStream()
        let emitter = AgentEventEmitter(channel.continuation, requiresConsumer: false)
        try await emitter.send(.toolStarted(call))
        let gate = CompletionCommitGate()
        let lifecycle = AgentLoopLifecycle(
            control: AgentRunControl(),
            evidenceLedger: EvidenceLedger(),
            mutationAdmission: journal,
            checkpoint: { messages, _ in messages },
            commitMutation: { callID, receipt, output, messages, steering in
                await gate.waitForRelease()
                try await journal.commitMutation(
                    sessionID: sessionID,
                    runID: runID,
                    callID: callID,
                    receipt: receipt,
                    output: output,
                    history: messages,
                    steeringIDs: steering.map(\.id)
                )
                return messages
            },
            markMutationNeedsReconciliation: { callID in
                try await journal.markMutationNeedsReconciliation(
                    sessionID: sessionID,
                    runID: runID,
                    callID: callID
                )
            }
        )
        let response = ModelResponse(info: .init(id: "response", model: fixtureModel),
                                     toolCalls: [call], stopReason: .toolCalls)
        let progress = AgentToolBatchProgress(prefix: [], response: response, budget: budget,
                                              lifecycle: lifecycle, emitter: emitter)
        let recording = Task { try await progress.record(index: 0, call: prepared, result: result) }
        await gate.waitUntilBlocked()

        let finishing = await emitter.beginFinishing(.cancelled)
        await gate.open()
        await gate.waitUntilResumed()
        try await recording.value
        await finishing.value

        #expect(await probe.count == 1)
        #expect(try await journal.pendingMutations(sessionID: sessionID).isEmpty)
        try await journal.close()
        let durable = try openTestJournal(at: url)
        #expect(try await durable.pendingMutations(sessionID: sessionID).isEmpty)
        let status = try #require(try await durable.mutationStatus(identity: operationID))
        #expect(status.state == .settled)
        #expect(status.receipt == result.receipt)
        #expect(status.replayOutput == result.output)
        let expectedHistory: [ModelMessage] = [
            .assistant(content: [], toolCalls: [call]),
            .tool(.init(callID: call.id, content: [.json(result.output)], isError: false)),
        ]
        #expect(try await durable.latestCheckpoint(sessionID: sessionID)?.history == expectedHistory)

        let events = await collectEvents(channel.stream)
        #expect(events == [
            .toolStarted(call),
            .toolReceiptValidated(.init(callID: call.id, effect: .mutation,
                                        receipt: try #require(result.receipt))),
            .toolCompleted(.init(callID: call.id, content: [.json(result.output)], isError: false)),
            .runFinished(.cancelled),
        ])
        try await durable.close()
    }
}

private extension AgentEventEmitter {
    func beginFinishing(_ outcome: AgentRunTermination) async -> Task<Void, Never> {
        let task = Task { await self.finish(outcome) }
        await waitUntilFinishing()
        return task
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

private actor CompletionCommitGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var blocked = false
    private var resumed = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumedWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        blocked = true
        let observers = blockedWaiters
        blockedWaiters.removeAll()
        for observer in observers { observer.resume() }
        await withCheckedContinuation { continuation = $0 }
        resumed = true
        let resumedObservers = resumedWaiters
        resumedWaiters.removeAll()
        for observer in resumedObservers { observer.resume() }
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilResumed() async {
        if resumed { return }
        await withCheckedContinuation { resumedWaiters.append($0) }
    }
}

private actor CompletionMutationProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct CompletionMutationTool: AgentTool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable, Equatable { let updated: Bool }

    static let name = "completion_mutation"
    static let description = "Apply one fixture mutation"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])

    let probe: CompletionMutationProbe
    let policy: ToolPolicy

    init(probe: CompletionMutationProbe) throws {
        self.probe = probe
        policy = try .mutation(authorization: .notRequired, evidence: .none)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "fixture.resource", id: "one"))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "fixture.resource", id: "one")], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.record()
        return ToolResult(
            output: .init(updated: true),
            receipt: .init(
                operationID: context.idempotencyKey ?? "missing",
                status: .succeeded,
                confirmedTargets: [.init(namespace: "fixture.resource", id: "one")],
                revision: "v1"
            )
        )
    }
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
