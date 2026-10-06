@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

struct AgentRejectedArgumentsCommitTests {
    @Test(arguments: [false, true])
    func loopWithoutLifecycleStillPublishesRejectedResults(mixed: Bool) async throws {
        let bad = rejectedCall(), good = addition("good")
        let log = EffectLog()
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, mixed ? [bad, good] : [bad]) : textResponse(request, "done")
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider,
            tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log))]))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        #expect(events.filter { $0 == .toolAdmissionRejected(bad.id) }.count == 1)
        guard case .runFinished(.result(let result)) = events.last else {
            Issue.record("Expected a completed Run"); return
        }
        #expect(result.outcome == .completed && result.modelTurns == 2 && result.toolCalls == (mixed ? 2 : 1))
        #expect(await log.contexts.map(\.callID) == (mixed ? [good.id] : []))
    }

    @Test(arguments: [false, true])
    func uncertainJournalCommitPublishesNoConfirmedRejectionButCanExistAfterReopen(mixed: Bool) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = RejectionPublicationFault()
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "rejection-unknown",
            fault: { try fault.check($0) })
        let bad = rejectedCall(), good = addition("good")
        let provider = ScriptedProvider { request, _ in fault.arm(); return toolResponse(request, mixed ? [bad, good] : [bad]) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: EffectLog())]).makeSession(journal: journal)
        let run = try await session.run("Add")
        let observation = Task { await collectEvents(run.events) }
        await #expect(throws: AgentJournalError.commitUnknown) { try await run.wait() }
        try await run.waitForDrain()
        let events = await observation.value
        #expect(!events.contains(.toolAdmissionRejected(bad.id)))
        #expect(events.last == .runFinished(.failed(.journal(.commitUnknown))))
        #expect(await provider.log.requests.count == 1)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let committed = try #require(try await reopened.latestCheckpoint(sessionID: session.id)).history
        let results = committed.compactMap { message -> ToolResultMessage? in
            if case .tool(let result) = message { return result }; return nil
        }
        #expect(results.map(\.callID) == (mixed ? [bad.id, good.id] : [bad.id]))
        #expect(results.first?.isError == true)
        try await reopened.close()
    }

    @Test func successiveCheckpointsPublishEachRejectionOnceAndKeepProposalOrder() async throws {
        let good = [addition("first"), addition("last")]
        let bad = rejectedCall()
        let calls = [good[0], bad, good[1]]
        let rejected = rejection(for: bad)
        let channel = AsyncStream<AgentEvent>.makeStream()
        let emitter = AgentEventEmitter(channel.continuation, requiresConsumer: false)
        let history = RejectionCheckpointHistory()
        let lifecycle = AgentLoopLifecycle(control: AgentRunControl(), evidenceLedger: EvidenceLedger(),
            checkpoint: { messages, _ in await history.record(messages); return messages })
        let progress = AgentToolBatchProgress(prefix: [], response: response(calls), rejected: [1: rejected],
            budget: try testBudget(), lifecycle: lifecycle, emitter: emitter)
        let registry = try ToolRegistry(tools: [AnyAgentTool(AddTool(log: EffectLog(), execution: .sequential))])
        for (index, call) in [(0, good[0]), (2, good[1])] {
            let prepared = try registry.prepare(call, context: .init(sessionID: UUID(), runID: UUID(), callID: call.id))
            try await emitter.send(.toolStarted(call))
            try await progress.record(index: index, call: prepared, result: prepared.invoke())
        }
        await emitter.finish(.cancelled)
        let events = await collectEvents(channel.stream)
        #expect(events.filter { $0 == .toolAdmissionRejected(bad.id) }.count == 1)
        #expect(events.last == .runFinished(.cancelled))
        let checkpoints = await history.checkpoints
        #expect(checkpoints.count == 2)
        #expect(checkpoints[0] == [.assistant(content: [], toolCalls: [good[0], bad]), .tool(success(for: good[0])), .tool(rejected)])
        #expect(checkpoints[1] == [.assistant(content: [], toolCalls: calls), .tool(success(for: good[0])), .tool(rejected), .tool(success(for: good[1]))])
    }

    enum CheckpointOutcome: Sendable { case confirmed, failed, cancelled, unknown }

    /// Stop at the checkpoint return boundary, with finish already pending. Confirmed commits
    /// must publish despite cancellation; definite failures and unknown commits must only abort.
    @Test(arguments: [CheckpointOutcome.confirmed, .failed, .cancelled, .unknown], [false, true])
    func publicationWaitsForConfirmedCommitAndAlwaysReleasesFinish(_ outcome: CheckpointOutcome, mixed: Bool) async throws {
        let bad = rejectedCall(), good = addition("good")
        let calls = mixed ? [bad, good] : [bad]
        let rejected = rejection(for: bad)
        let channel = AsyncStream<AgentEvent>.makeStream()
        let emitter = AgentEventEmitter(channel.continuation, requiresConsumer: false)
        let gate = ManualGate(), history = RejectionCheckpointHistory()
        let lifecycle = AgentLoopLifecycle(control: AgentRunControl(), evidenceLedger: EvidenceLedger(),
            checkpoint: { messages, _ in
                if outcome == .confirmed { await history.record(messages) }
                await gate.wait()
                switch outcome {
                case .confirmed: return messages
                case .failed: throw FixtureError.invalidOperation
                case .cancelled: try Task.checkCancellation(); throw FixtureError.invalidOperation
                case .unknown: throw AgentJournalError.commitUnknown
                }
            })
        let progress = AgentToolBatchProgress(prefix: [], response: response(calls), rejected: [0: rejected],
            budget: try testBudget(), lifecycle: lifecycle, emitter: emitter)
        let prepared = try ToolRegistry(tools: [AnyAgentTool(AddTool(log: EffectLog()))])
            .prepare(good, context: .init(sessionID: UUID(), runID: UUID(), callID: good.id))
        if mixed { try await emitter.send(.toolStarted(good)) }
        let recording = Task {
            if mixed { try await progress.record(index: 1, call: prepared, result: prepared.invoke()) }
            else { try await progress.commitUnexecuted() }
        }
        await gate.waitUntilBlocked()
        if outcome == .confirmed || outcome == .cancelled { recording.cancel() }
        let finishing = Task { await emitter.finish(.cancelled) }
        await emitter.waitUntilFinishing()
        await gate.open()
        switch outcome {
        case .confirmed: try await recording.value
        case .failed: await #expect(throws: FixtureError.invalidOperation) { try await recording.value }
        case .cancelled: await #expect(throws: CancellationError.self) { try await recording.value }
        case .unknown: await #expect(throws: AgentJournalError.commitUnknown) { try await recording.value }
        }
        await finishing.value
        let events = await collectEvents(channel.stream)
        #expect(events.filter { $0 == .toolAdmissionRejected(bad.id) }.count == (outcome == .confirmed ? 1 : 0))
        #expect(events.last == .runFinished(.cancelled))
        #expect(await history.checkpoints.isEmpty == (outcome != .confirmed))
        #expect(!events.contains(.toolStarted(bad)))
        #expect(!events.contains { if case .toolCompleted(let result) = $0 { result.callID == bad.id } else { false } })
        #expect(!events.contains { if case .toolReceiptValidated(let receipt) = $0 { receipt.callID == bad.id } else { false } })
        if mixed {
            #expect(events.contains(.toolCompleted(success(for: good))) == (outcome == .confirmed))
        }
    }

    @Test(arguments: [AgentCompletionCommitTests.CheckpointEnding.deadline, .cancellation], [false, true])
    func committedJournalRejectionsSurviveRunTermination(_ ending: AgentCompletionCommitTests.CheckpointEnding, mixed: Bool) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hold = PublishedCheckpointHold()
        defer { hold.release() }
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "rejection-ending",
            fault: { hold.check($0) })
        let bad = rejectedCall(), good = addition("good"), later = addition("later")
        // The second valid sibling must not start after cancellation/deadline.
        let calls = mixed ? [bad, good, later] : [bad]
        let log = EffectLog()
        let provider = ScriptedProvider { request, _ in hold.arm(); return toolResponse(request, calls) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: log, execution: .sequential)])
            .makeSession(journal: journal)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let run = try await session.run("Add", budget: .init(maxModelTurns: 3, maxToolCalls: 3, deadline: deadline))
        let observation = Task { await collectEvents(run.events) }
        #expect(await hold.waitUntilHeld())
        switch ending {
        case .deadline: try await ContinuousClock().sleep(until: deadline)
        case .cancellation: await run.cancel()
        }
        hold.release()
        switch ending {
        case .deadline: await #expect(throws: AgentLoopError.deadlineExceeded) { try await run.wait() }
        case .cancellation: await #expect(throws: CancellationError.self) { try await run.wait() }
        }
        try await run.waitForDrain()
        let events = await observation.value
        #expect(events.filter { $0 == .toolAdmissionRejected(bad.id) }.count == 1)
        let terminal: AgentRunTermination = ending == .deadline ? .failed(.loop(.deadlineExceeded)) : .cancelled
        #expect(events.last == .runFinished(terminal))
        #expect(!events.contains(.toolStarted(bad)) && !events.contains(.toolStarted(later)))
        #expect(await log.contexts.map(\.callID) == (mixed ? [good.id] : []))
        #expect(await provider.log.requests.count == 1)
        let committed = try #require(try await journal.latestCheckpoint(sessionID: session.id)).history
        let results = committed.compactMap { message -> ToolResultMessage? in
            if case .tool(let result) = message { return result }; return nil
        }
        #expect(results.map(\.callID) == (mixed ? [bad.id, good.id] : [bad.id]))
        #expect(results.first?.isError == true)
        #expect(await session.history == committed)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.history == committed)
        try await reopened.close()
    }
}

private func rejectedCall() -> ToolCall {
    // Canonical replay has already replaced malformed JSON with an object.
    .init(id: .init(rawValue: "bad"), name: "add", argumentsJSON: "{}", completeness: .complete)
}

private func rejection(for call: ToolCall) -> ToolResultMessage {
    .init(callID: call.id, content: [.json(.object(["code": .string("invalid_arguments")]))], isError: true)
}

private func success(for call: ToolCall) -> ToolResultMessage {
    .init(callID: call.id, content: [.json(.object(["sum": .number(5)]))], isError: false)
}

private func response(_ calls: [ToolCall]) -> ModelResponse {
    .init(info: .init(id: "response", model: fixtureModel), toolCalls: calls, stopReason: .toolCalls)
}

private actor RejectionCheckpointHistory {
    private(set) var checkpoints: [[ModelMessage]] = []
    func record(_ messages: [ModelMessage]) { checkpoints.append(messages) }
}

/// Throw after CURRENT changed: the caller sees an uncertain commit, even though reopen
/// will find the checkpoint. It must not be reported as either definitely absent or confirmed.
private final class RejectionPublicationFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func check(_ stage: JournalFileFaultStage) throws {
        guard stage == .afterCurrentReplace else { return }
        let fail = lock.withLock { let fail = armed; armed = false; return fail }
        if fail { throw AgentJournalError.persistenceUnavailable("rejection publication fixture") }
    }
}
