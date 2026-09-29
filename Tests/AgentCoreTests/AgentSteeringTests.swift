import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentSteeringTests {
    @Test func correctionDuringModelTurnReplansBeforeExecutingStaleProposal() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Model entered")
        let log = EffectLog()
        let provider = ScriptedProvider { request, turn in
            if turn == 1 { entered.fulfill(); await gate.wait(); return toolResponse(request, [addition("stale")]) }
            return textResponse(request, "Corrected")
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [AddTool(log: log)]).makeSession()
        let run = try await session.run("original")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        await #expect(throws: AgentRunError.emptySteering) { try await run.steer(" \n") }
        let id = try await run.steer("correction")
        await gate.open()
        let result = try await run.wait()
        #expect(result.modelTurns == 2)
        #expect(result.toolCalls == 0)
        #expect(await log.names.isEmpty)
        #expect(await provider.log.requests.last?.messages == [.user([.text("original")]), .user([.text("correction")])])
        #expect(await collectEvents(run.events).contains(.steeringApplied(id: id, text: "correction")))
        await #expect(throws: AgentRunError.finished) { try await run.steer("too late") }
    }

    @Test func steeringAdvancesTheProjectionCoordinatesBeforeTheNextRequest() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Model entered")
        let projections = ProjectionLog()
        let provider = ScriptedProvider { request, turn in
            if turn == 1 {
                entered.fulfill()
                await gate.wait()
            }
            return textResponse(request, turn == 1 ? "stale" : "fresh")
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try AgentModelBinding(
            profileID: "projection-steering",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: try .init(
                serviceInstanceID: "projection-steering",
                endpointScope: "fixture://projection-steering",
                apiDialect: "fixture"
            ),
            projector: RecordingProjector(log: projections)
        )

        let run = try await session.run("original", using: binding)
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        _ = try await run.steer("correction")
        await gate.open()
        _ = try await run.wait()

        #expect(await projections.coordinates.map { "\($0.0):\($0.1)" } == ["1:1", "2:2"])
    }

    @Test func steeringDuringToolBatchWaitsForBothResults() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Tool entered")
        let returned = XCTestExpectation(description: "Tool returned")
        let tool = try BlockingTool(gate: gate, entered: entered, returned: returned, timeout: .seconds(5))
        let calls = [blockingCall, addition("second")]
        let provider = ScriptedProvider { request, turn in turn == 1 ? toolResponse(request, calls) : textResponse(request, "Done") }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [tool, AddTool(log: EffectLog())]).makeSession()
        let run = try await session.run("work")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        _ = try await run.steer("adjust")
        await gate.open()
        let result = try await run.wait()
        #expect(result.toolCalls == 2)
        let messages = try #require(await provider.log.requests.last?.messages)
        #expect(Array(messages.suffix(3)) == [
            .tool(.init(callID: blockingCall.id, content: [.json(.string("Late result"))], isError: false)),
            .tool(.init(callID: calls[1].id, content: [.json(.object(["sum": .number(5)]))], isError: false)),
            .user([.text("adjust")]),
        ])
    }

    @Test func exhaustedBudgetRetainsAcceptedCorrectionsInOrder() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Model entered")
        let provider = ScriptedProvider { request, _ in entered.fulfill(); await gate.wait(); return textResponse(request, "Stale") }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            configuration: AgentConfiguration(maxModelTurns: 1)
        ).makeSession()
        let run = try await session.run("original")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        let a = try await run.steer("one"), b = try await run.steer("two")
        #expect(a != b)
        await gate.open()
        await #expect(throws: AgentLoopError.modelTurnLimitReached) { try await run.wait() }
        #expect(await session.history == [.user([.text("original")]), .user([.text("one")]), .user([.text("two")])])
        let events = await collectEvents(run.events)
        #expect(!events.contains { if case .steeringApplied = $0 { true } else { false } })
        #expect(await provider.log.requests.count == 1)
    }

    @Test func cancelledBatchKeepsCompletedPairAndUndeliveredCorrectionExactlyOnce() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Tool entered"), returned = XCTestExpectation(description: "Tool returned")
        let blocker = try BlockingTool(gate: gate, entered: entered, returned: returned, timeout: .seconds(5))
        let call = addition("done")
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call, blockingCall]) : textResponse(request, "Next")
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [AddTool(log: EffectLog()), blocker]).makeSession()
        let run = try await session.run("original")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        _ = try await run.steer("remember")
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        let checkpoint: [ModelMessage] = [.user([.text("original")]), .assistant(content: [], toolCalls: [call]),
            .tool(.init(callID: call.id, content: [.json(.object(["sum": .number(5)]))], isError: false)), .user([.text("remember")])]
        #expect(await session.history == checkpoint)
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        let next = try await session.run("continue")
        _ = try await next.wait()
        #expect(await session.history == checkpoint + [.user([.text("continue")]), .assistant(content: [.text("Next")], toolCalls: [])])
        await #expect(throws: AgentRunError.finished) { try await run.steer("late") }
    }

    @Test func competingDeliveryAndCancellationKeepAcceptedInputsExactlyOnce() async throws {
        for iteration in 0..<32 {
            let responseGate = ManualGate(), continuationGate = ManualGate(), barrier = ManualGate()
            let entered = XCTestExpectation(description: "First response entered")
            let firstReturned = XCTestExpectation(description: "First response returned")
            let secondReturned = XCTestExpectation(description: "Second response returned")
            let log = EffectLog()
            let provider = ScriptedProvider { request, turn in
                if request.messages.last == .user([.text("next")]) { return textResponse(request, "Next") }
                if turn == 1 {
                    entered.fulfill()
                    await responseGate.wait()
                    firstReturned.fulfill()
                    return toolResponse(request, [addition("stale")])
                }
                await continuationGate.wait()
                secondReturned.fulfill()
                return textResponse(request, "Stale")
            }
            let session = try Agent(model: fixtureModel, provider: provider, tools: [AddTool(log: log)]).makeSession()
            let run = try await session.run("original")
            #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
            _ = try await run.steer("correction A")
            _ = try await run.steer("correction B")
            let release: @Sendable () async -> Void = { await responseGate.open() }
            let cancel: @Sendable () async -> Void = { await run.cancel() }
            let actions = iteration.isMultiple(of: 2) ? [release, cancel] : [cancel, release]
            let jobs = actions.map { action in Task { await barrier.wait(); await action() } }
            await barrier.open()
            for job in jobs { await job.value }
            await #expect(throws: CancellationError.self) { try await run.wait() }
            let oldRequestCount = await provider.log.requests.count
            await responseGate.open()
            await continuationGate.open()
            #expect(await XCTWaiter.fulfillment(of: [firstReturned], timeout: 1) == .completed)
            if oldRequestCount > 1 { #expect(await XCTWaiter.fulfillment(of: [secondReturned], timeout: 1) == .completed) }
            let expected: [ModelMessage] = [.user([.text("original")]), .user([.text("correction A")]), .user([.text("correction B")])]
            #expect(await session.history == expected)
            #expect(await session.activeRunID == nil)
            #expect(await log.names.isEmpty)
            let next = try await session.run("next")
            _ = try await next.wait()
            let followUp = await provider.log.requests.first { $0.messages.last == .user([.text("next")]) }
            #expect(followUp?.messages == expected + [.user([.text("next")])])
        }
    }
}

/// A correction accepted but not delivered when a Run is cancelled is part of the conversation:
/// it is committed with its stable ID before the Run ends, or its failure is reported.
struct AgentSteeringDurabilityTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("steering-durability-\(UUID().uuidString)")
    }

    @Test func retainedCorrectionIsCommittedWhenTheRunIsCancelled() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try AgentIncrementalJournal.create(at: url, operationDomain: "steering")
        let model = StalledModel()
        let agent = try Agent(model: fixtureModel, provider: model.provider)
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("original")
        await model.waitUntilStalled()
        let correctionID = try await run.steer("correction")
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        try await run.waitForDrain()

        let expected: [ModelMessage] = [.user([.text("original")]), .user([.text("correction")])]
        #expect(try await session.conversationSnapshot().messages == expected)
        let committed = try #require(try await journal.latestCheckpoint(sessionID: session.id))
        #expect(committed.history == expected)
        #expect(committed.steeringIDs == [correctionID])

        let next = try await session.run("next")
        _ = try await next.wait()
        try await next.waitForDrain()
        #expect(await model.lastRequest?.messages == expected + [.user([.text("next")])])
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: url)
        let restored = try await agent.makeSession(id: session.id, journal: reopened).conversationSnapshot()
        #expect(restored.messages.filter { $0 == .user([.text("correction")]) }.count == 1)
        try await reopened.close()
    }

    /// An unknown outcome is neither adopted nor dropped: the Run reports it and the Session
    /// refuses to present or extend history until the Journal is reopened and inspected.
    @Test(arguments: [JournalFileFaultStage.afterIndexSync, .afterCurrentReplace])
    func uncertainCorrectionCommitIsReportedNotAssumed(_ stage: JournalFileFaultStage) async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let fault = SteeringJournalFault()
        let journal = try AgentIncrementalJournal.createForTesting(at: url, operationDomain: "steering",
                                                                   fault: { try fault.check($0) })
        let model = StalledModel()
        let agent = try Agent(model: fixtureModel, provider: model.provider)
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("original")
        await model.waitUntilStalled()
        _ = try await run.steer("correction")
        fault.arm(stage)
        await run.cancel()
        await #expect(throws: AgentJournalError.commitUnknown) { try await run.wait() }
        try await run.waitForDrain()
        #expect(fault.fired)
        await #expect(throws: AgentJournalError.commitUnknown) { try await session.conversationSnapshot() }
        await #expect(throws: AgentJournalError.commitUnknown) { try await session.run("next") }
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: url)
        let restored = try await agent.makeSession(id: session.id, journal: reopened).conversationSnapshot()
        let published = stage == .afterCurrentReplace
        #expect(restored.messages == [.user([.text("original")])] + (published ? [.user([.text("correction")])] : []))
        try await reopened.close()
    }

    /// A definite failure is reported; the correction stays owed and joins the next Run's
    /// admitted input, once.
    @Test func correctionThatCouldNotBeCommittedJoinsTheNextRun() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let fault = SteeringJournalFault()
        let journal = try AgentIncrementalJournal.createForTesting(at: url, operationDomain: "steering",
                                                                   fault: { try fault.check($0) })
        let model = StalledModel()
        let session = try Agent(model: fixtureModel, provider: model.provider).makeSession(journal: journal)
        let run = try await session.run("original")
        await model.waitUntilStalled()
        _ = try await run.steer("correction")
        fault.arm(.beforeAppend)
        await run.cancel()
        await #expect(throws: AgentJournalError.self) { try await run.wait() }
        try await run.waitForDrain()
        #expect(fault.fired)
        #expect(try await session.conversationSnapshot().messages == [.user([.text("original")])])
        #expect(try await journal.latestCheckpoint(sessionID: session.id)?.history == [.user([.text("original")])])

        let next = try await session.run("next")
        _ = try await next.wait()
        try await next.waitForDrain()
        let expected: [ModelMessage] = [.user([.text("original")]), .user([.text("correction")]), .user([.text("next")])]
        #expect(await model.lastRequest?.messages == expected)
        #expect(try await journal.latestCheckpoint(sessionID: session.id)?.history.prefix(3).elementsEqual(expected) == true)
        try await journal.close()
    }
}

/// The first model turn stalls until cancelled; later turns answer at once.
private struct StalledModel {
    let provider: ScriptedProvider
    private let stalled: AsyncStream<Void>

    init() {
        let (stalled, signal) = AsyncStream<Void>.makeStream()
        self.stalled = stalled
        provider = ScriptedProvider { request, turn in
            if turn == 1 {
                signal.yield()
                try await Task.sleep(for: .seconds(30))
            }
            return textResponse(request, "answer \(turn)")
        }
    }

    func waitUntilStalled() async { for await _ in stalled { return } }
    var lastRequest: ModelRequest? { get async { await provider.log.requests.last } }
}

/// Throws once at an armed Journal stage.
private final class SteeringJournalFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: JournalFileFaultStage?
    private var didFire = false
    var fired: Bool { lock.withLock { didFire } }
    func arm(_ stage: JournalFileFaultStage) { lock.withLock { armed = stage } }
    func check(_ stage: JournalFileFaultStage) throws {
        let fire = lock.withLock { () -> Bool in
            guard armed == stage else { return false }
            armed = nil
            didFire = true
            return true
        }
        if fire { throw AgentJournalError.persistenceUnavailable("injected \(stage)") }
    }
}

private actor ProjectionLog {
    private(set) var coordinates: [(UInt64, UInt64)] = []

    func append(_ input: AgentContextProjectionInput) {
        coordinates.append((input.conversationRevision, input.contextEpoch))
    }
}

private struct RecordingProjector: AgentContextProjector {
    let log: ProjectionLog

    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        await log.append(input)
        return try await AgentIdentityContextProjector().project(input)
    }
}
