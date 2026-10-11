@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

/// An answer the model source handed over whole before the Run's deadline is complete. The deadline
/// only decides whether a Run that has no such answer yet ran out of time.
struct AgentSettledAnswerDeadlineTests {
    /// The answer arrives well before the deadline, but the stream is only closed after it.
    private func providerClosingLate(after delay: Duration, text: String = "the whole answer") -> any ModelProvider {
        ScriptedProvider { request, _ in
            let info = ResponseInfo(id: "response", model: request.model)
            return [.responseStarted(info), .textDelta(text),
                    .responseCompleted(.init(info: info, content: [.text(text)], stopReason: .endTurn))]
        }.delayingStreamEnd(by: delay)
    }

    /// Hold before actual CURRENT replacement, so the answer is not durably published
    /// until after the deadline. The published root remains the user-only startup checkpoint.
    @Test(arguments: [false, true], [false, true])
    func finalCheckpointPublicationCrossesDeadlineAndReopensExactlyOnce(records: Bool, cancelDuringPublication: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("final-deadline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hold = PublishedCheckpointHold(stage: .beforeCurrentReplace)
        let sessionID = UUID()
        let currentURL = directory.appendingPathComponent("CURRENT")
        let journal = try AgentIncrementalJournal.createForTesting(
            at: directory, operationDomain: "final-deadline", supportsRunRecords: records,
            fault: { hold.check($0) })
        let provider = ScriptedProvider { request, _ in
            #expect(try await journal.latestCheckpoint(sessionID: sessionID)?.history == [.user([.text("Answer")])])
            hold.arm(current: try Data(contentsOf: currentURL))
            return textResponse(request, "persisted final answer")
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(id: sessionID, journal: journal)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        let run = try await session.run("Answer", budget: AgentBudget(
            maxModelTurns: 2, maxToolCalls: 0, deadline: deadline))
        let held = await hold.waitUntilHeld()
        #expect(held)
        if !held { hold.release(); return }
        #expect(ContinuousClock.now < deadline, "final response reached publication before deadline")
        // Journal reads share the held writer's lock, so inspect the actual published root:
        // it still points to the independently checked user-only checkpoint, not the final candidate.
        #expect(try Data(contentsOf: currentURL) == hold.currentBeforePublication)
        if cancelDuringPublication { await run.cancel() }
        try await Task.sleep(until: deadline.advanced(by: .milliseconds(50)), clock: .continuous)
        #expect(try Data(contentsOf: currentURL) == hold.currentBeforePublication,
                "final checkpoint must still be unpublished after deadline")
        hold.release()
        let result = try await run.wait()
        try await run.waitForDrain()
        #expect(result.outcome == .completed)
        let expected: [ModelMessage] = [.user([.text("Answer")]),
            .assistant(content: [.text("persisted final answer")], toolCalls: [])]
        #expect(await session.history == expected)
        #expect(try await journal.latestCheckpoint(sessionID: session.id)?.history == expected)
        if records {
            guard case .terminal(_, .completed) = try await session.runRecord(runID: run.id) else {
                Issue.record("final checkpoint and logical terminal disagree"); return
            }
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.history == expected)
        if records {
            guard case .terminal(_, .completed) = try await reopened.runRecord(sessionID: session.id, runID: run.id) else {
                Issue.record("reopened final terminal disagrees"); return
            }
        }
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func finalAnswerDoesNotHideCheckpointFailure(unknown: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("final-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = FinalCheckpointFault(unknown: unknown)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "final-failure", fault: { try fault.check($0) })
        let provider = ScriptedProvider { request, _ in
            fault.arm()
            return textResponse(request, "answer before failed persistence")
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        let run = try await session.run("Answer")
        await #expect(throws: unknown ? AgentJournalError.commitUnknown : .persistenceUnavailable("final checkpoint fixture")) {
            _ = try await run.wait()
        }
        try await run.waitForDrain()
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let history = try #require(try await reopened.latestCheckpoint(sessionID: session.id)).history
        #expect(history.count == (unknown ? 2 : 1))
        #expect(history.first == .user([.text("Answer")]))
        try await reopened.close()
    }

    @Test func answerReceivedBeforeTheDeadlineCompletesWhenTheStreamClosesAfterIt() async throws {
        let provider = providerClosingLate(after: .milliseconds(600))
        let session = try Agent(model: fixtureModel, provider: provider,
                                configuration: .init(runTimeout: .milliseconds(300))).makeSession()
        let run = try await session.run("Answer")
        let result = try await run.wait()
        #expect(result.outcome == .completed)
        #expect(result.response.content == [.text("the whole answer")])
        let history = await session.history
        #expect(history.last == .assistant(content: [.text("the whole answer")], toolCalls: []))
    }

    @Test func answerTheModelSourceHandedOverBeforeTheDeadlineCompletesWhenTheRunReadsItLate() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "the whole answer") }
        // The model source has sent everything at once; the Run gets to the first event after the deadline.
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []),
                             beforeHandlingModelEvent: { event in
            if case .responseStarted = event { try? await Task.sleep(for: .milliseconds(600)) }
        })
        let budget = try AgentBudget(maxModelTurns: 2, maxToolCalls: 0, deadline: .now.advanced(by: .milliseconds(300)))
        let result = try await loop.run(messages: [ModelMessage.user([.text("Answer")])], sessionID: UUID(), budget: budget)
        #expect(result.outcome == .completed)
        #expect(result.history.last == .assistant(content: [.text("the whole answer")], toolCalls: []))
    }

    @Test func steeringAfterAnAnswerReopensTheDeadlineBeforeAnotherModelRequest() async throws {
        let source = ScriptedProvider { request, _ in textResponse(request, "first answer") }
        let session = try Agent(model: fixtureModel, provider: source.delayingStreamEnd(by: .milliseconds(600)),
                                configuration: .init(runTimeout: .milliseconds(300))).makeSession()
        let run = try await session.run("Answer")
        // Observe the emitted response start rather than guessing when dispatch occurred.
        for await event in run.events {
            if case .model(.responseStarted) = event { break }
        }
        _ = try await run.steer("Need another answer")
        await #expect(throws: AgentLoopError.deadlineExceeded) { _ = try await run.wait() }
        try await run.waitForDrain()
        #expect(await source.log.requests.count == 1)
    }

    @Test func aRunWithoutAnAnswerByTheDeadlineStillTimesOut() async throws {
        let provider = ScriptedProvider { request, _ in
            let info = ResponseInfo(id: "response", model: request.model)
            try await Task.sleep(for: .seconds(5))
            return [.responseStarted(info), .responseCompleted(.init(info: info, content: [.text("late")], stopReason: .endTurn))]
        }
        let session = try Agent(model: fixtureModel, provider: provider,
                                configuration: .init(runTimeout: .milliseconds(300))).makeSession()
        let run = try await session.run("Answer")
        await #expect(throws: AgentLoopError.deadlineExceeded) { _ = try await run.wait() }
        let history = await session.history
        #expect(!history.contains { if case .assistant = $0 { true } else { false } })
    }
}

extension ScriptedProvider {
    /// Same events, but the stream only finishes `delay` after the last of them.
    func delayingStreamEnd(by delay: Duration) -> any ModelProvider {
        DelayedEndProvider(inner: self, delay: delay)
    }
}

private struct DelayedEndProvider: ModelProvider {
    let inner: ScriptedProvider
    let delay: Duration
    var descriptor: ModelProviderDescriptor { inner.descriptor }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let upstream = inner.stream(request: request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream { continuation.yield(event) }
                    try await Task.sleep(for: delay)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class FinalCheckpointFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private let unknown: Bool
    init(unknown: Bool) { self.unknown = unknown }
    func arm() { lock.withLock { armed = true } }
    func check(_ stage: JournalFileFaultStage) throws {
        guard stage == (unknown ? .afterCurrentReplace : .beforeAppend), lock.withLock({ () -> Bool in
            defer { armed = false }
            return armed
        }) else { return }
        throw AgentJournalError.persistenceUnavailable("final checkpoint fixture")
    }
}
