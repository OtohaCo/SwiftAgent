@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentFollowUpQueueTests {
    @Test func explicitDispatcherAdmitsFifoAndStopsWithoutConsumingTheEventStream() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-dispatch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "dispatch")
        let provider = QueueFixtureProvider()
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let session = try agent.makeSession(journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "one", text: "first",
            operationID: "op-one", configurationRef: "v1"))
        _ = try await session.enqueueFollowUp(.init(inputID: "two", text: "second",
            operationID: "op-two", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(
            policy: .init(maxModelTurns: 2, maxToolCalls: 0, runTimeout: .seconds(10)),
            resolver: QueueFixtureResolver(session: session, provider: provider))
        await provider.waitForRequestCount(2)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        let requests = await provider.requests()
        #expect(requests.map { $0.messages.last } == [
            .user([.text("first")]), .user([.text("second")])
        ])
        guard case .admitted(let firstRun, let firstMessage)? = try await session.followUp(inputID: "one")?.state,
              case .admitted(let secondRun, let secondMessage)? = try await session.followUp(inputID: "two")?.state else {
            Issue.record("missing FIFO admissions"); return
        }
        #expect(firstRun != secondRun)
        #expect(try await session.withdrawFollowUp(inputID: "one") ==
                .alreadyAdmitted(runID: firstRun, formalMessageID: firstMessage))
        let formal = try await journal.readMessages(sessionID: session.id)
        #expect(formal.contains(where: { $0.id == firstMessage && $0.message == .user([.text("first")]) }))
        #expect(formal.contains(where: { $0.id == secondMessage && $0.message == .user([.text("second")]) }))
        try await journal.close()
    }

    @Test func reopenedQueueIsPausedUntilHostExplicitlyStartsDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-reopen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "reopen")
        let provider = QueueFixtureProvider()
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "later", text: "after reopen",
            operationID: "op-later", configurationRef: "approved-at-dispatch"))
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try agent.makeSession(id: sessionID, journal: reopened)
        #expect(try await restored.followUp(inputID: "later")?.state == .queued)
        #expect(await provider.requests().isEmpty)
        let dispatcher = try await restored.startFollowUpDispatch(
            policy: .init(maxModelTurns: 2, maxToolCalls: 0, runTimeout: .seconds(10)),
            resolver: QueueFixtureResolver(session: restored, provider: provider))
        await provider.waitForRequestCount(1)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        #expect(try await restored.followUp(inputID: "later")?.state != .queued)
        try await reopened.close()
    }

    @Test func directRunAndSecondConsumerCannotStealAnOwnedQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-owner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "owner")
        let provider = QueueFixtureProvider()
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let id = UUID()
        let session = try agent.makeSession(id: id, journal: journal)
        let dispatcher = try await session.startFollowUpDispatch(
            policy: .init(runTimeout: .seconds(10)), resolver: QueueFixtureResolver(session: session, provider: provider))
        await dispatcher.pause()
        await #expect(throws: AgentFollowUpError.dispatchOwned) { try await session.run("direct") }
        let replacement = try agent.makeSession(id: id, journal: journal)
        await #expect(throws: AgentFollowUpError.alreadyDispatching) {
            try await replacement.startFollowUpDispatch(
                policy: .init(), resolver: QueueFixtureResolver(session: replacement, provider: provider))
        }
        await #expect(throws: AgentFollowUpError.dispatchOwned) { try await replacement.run("direct") }
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        try await journal.close()
    }

    @Test func withdrawalWhileResolvingWinsTheAtomicAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-withdraw-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "withdraw-race")
        let provider = QueueFixtureProvider(), gate = QueueResolverGate(cooperative: false)
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let session = try agent.makeSession(journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "remove", text: "must not run",
            operationID: "never-run", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)),
            resolver: QueueFixtureResolver(session: session, provider: provider, gate: gate))
        await gate.waitUntilEntered()
        #expect(try await session.withdrawFollowUp(inputID: "remove") == .withdrawn)
        await gate.release()
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        #expect(try await session.followUp(inputID: "remove")?.state == .withdrawn)
        #expect(await provider.requests().isEmpty)
        #expect(try await journal.readMessages(sessionID: session.id).isEmpty)
        try await journal.close()
    }

    /// Formalized from /tmp/rc4-review-probe.diff (independent review, 2026-09-27).
    @Test func withdrawnResolverHeadDoesNotStallTheNextInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-withdraw-progress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "withdraw-progress")
        let provider = QueueFixtureProvider(), gate = QueueResolverGate(cooperative: false)
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let session = try agent.makeSession(journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "remove", text: "must not run",
            operationID: "never-run", configurationRef: "v1"))
        _ = try await session.enqueueFollowUp(.init(inputID: "next", text: "should run",
            operationID: "op-next", configurationRef: "v1"))
        let nextFinished = XCTestExpectation(description: "next input finished after withdrawn head")
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)),
            resolver: QueueFirstResolver(session: session, provider: provider, gate: gate),
            onRun: { record, run in
                for await _ in run.events {}
                if record.inputID == "next" { nextFinished.fulfill() }
            })
        await gate.waitUntilEntered()
        #expect(try await session.withdrawFollowUp(inputID: "remove") == .withdrawn)
        await gate.release()
        let observed = await XCTWaiter.fulfillment(of: [nextFinished], timeout: 3)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        #expect(observed == .completed)
        #expect(try await session.followUp(inputID: "remove")?.state == .withdrawn)
        #expect(try await session.followUp(inputID: "next")?.state != .queued)
        let requests = await provider.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.messages.last == .user([.text("should run")]))
        let formal = try await journal.readMessages(sessionID: session.id).map(\.message)
        #expect(!formal.contains(.user([.text("must not run")])))
        #expect(formal.filter { $0 == .user([.text("should run")]) }.count == 1)
        try await journal.close()
    }

    @Test func withdrawnHeadCannotOverridePauseOrStopBeforeResolverExits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-withdraw-stop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "withdraw-stop")
        let provider = QueueFixtureProvider(), gate = QueueResolverGate(cooperative: false)
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: provider).makeSession(journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "remove", text: "remove",
            operationID: "op-remove", configurationRef: "v1"))
        _ = try await session.enqueueFollowUp(.init(inputID: "next", text: "next",
            operationID: "op-next", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)),
            resolver: QueueFirstResolver(session: session, provider: provider, gate: gate))
        await gate.waitUntilEntered()
        #expect(try await session.withdrawFollowUp(inputID: "remove") == .withdrawn)
        await dispatcher.pause()
        #expect(await gate.waitUntilCancelled())
        await dispatcher.stop()
        await gate.release()
        try await dispatcher.waitForDrain()
        #expect(await dispatcher.status().mode == .stopped)
        #expect(await provider.requests().isEmpty)
        #expect(try await session.followUp(inputID: "next")?.state == .queued)
        #expect(try await journal.readMessages(sessionID: session.id).isEmpty)
        try await journal.close()
    }

    @Test func aRealJournalStartupErrorAfterWithdrawalStillPauses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-withdraw-error-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = QueueFaultProbe()
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "withdraw-error", fault: { try fault.check($0) })
        let provider = QueueFixtureProvider(), gate = QueueResolverGate(cooperative: false)
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: provider).makeSession(journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "remove", text: "remove",
            operationID: "op-remove", configurationRef: "v1"))
        _ = try await session.enqueueFollowUp(.init(inputID: "next", text: "next",
            operationID: "op-next", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)),
            resolver: QueueFirstFaultResolver(session: session, provider: provider,
                                             gate: gate, fault: fault))
        await gate.waitUntilEntered()
        #expect(try await session.withdrawFollowUp(inputID: "remove") == .withdrawn)
        await gate.release()
        await dispatcher.waitUntilPaused()
        #expect(await dispatcher.status().lastFailureKind == "journal")
        #expect(await provider.requests().isEmpty)
        #expect(try await session.followUp(inputID: "next")?.state == .queued)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        try await journal.close()
    }

    @Test func stopWhileQueuedStartupWaitsBeforeCommitRetainsItsLeaseThenKeepsInputQueued() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-startup-stop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "startup-stop")
        let provider = QueueFixtureProvider(), gate = QueueResolverPhaseGate()
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let session = try agent.makeSession(journal: journal,
            startupCommitWillBegin: { _ in await gate.wait() })
        _ = try await session.enqueueFollowUp(.init(inputID: "stopped", text: "not admitted",
            operationID: "op-stopped", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)),
            resolver: QueueFixtureResolver(session: session, provider: provider))
        await gate.waitUntilEntered()
        await dispatcher.stop()
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        await gate.release()
        try await dispatcher.waitForDrain()
        #expect(try await session.followUp(inputID: "stopped")?.state == .queued)
        #expect(try await journal.readMessages(sessionID: session.id).isEmpty)
        #expect(await provider.requests().isEmpty)
        try await journal.close()
    }

    @Test func stopWaitsForNoncooperativeResolverWithoutRestoringItsLateResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-resolver-drain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "resolver-drain")
        let provider = QueueFixtureProvider(), gate = QueueResolverGate(cooperative: false)
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let id = UUID(), session = try agent.makeSession(id: id, journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "late", text: "late result",
            operationID: "op-late", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)),
            resolver: QueueFixtureResolver(session: session, provider: provider, gate: gate))
        await gate.waitUntilEntered()
        await dispatcher.pause()
        #expect(await gate.waitUntilCancelled())
        await dispatcher.stop()
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        let replacement = try agent.makeSession(id: id, journal: journal)
        await #expect(throws: AgentFollowUpError.dispatchOwned) { try await replacement.run("too early") }
        await gate.release()
        try await dispatcher.waitForDrain()
        #expect(try await session.followUp(inputID: "late")?.state == .queued)
        #expect(await provider.requests().isEmpty)
        try await journal.close()
    }

    @Test func cancellingOneDrainWaiterDoesNotReleaseResolverOrOtherWaiters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-waiters-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "waiters")
        let provider = QueueFixtureProvider(), gate = QueueResolverGate(cooperative: false)
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: provider).makeSession(journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "one", text: "later",
            operationID: "op-one", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)),
            resolver: QueueFixtureResolver(session: session, provider: provider, gate: gate))
        await gate.waitUntilEntered()
        await dispatcher.stop()
        #expect(await gate.waitUntilCancelled())
        let abandoned = Task { try await dispatcher.waitForDrain() }
        let retained = Task { try await dispatcher.waitForDrain() }
        await dispatcher.waitUntilDrainWaiterCount(2)
        abandoned.cancel()
        await #expect(throws: CancellationError.self) { try await abandoned.value }
        await dispatcher.waitUntilDrainWaiterCount(1)
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        await gate.release()
        try await retained.value
        #expect(await dispatcher.status().physicallyDrained)
        #expect(try await session.followUp(inputID: "one")?.state == .queued)
        try await journal.close()
    }

    @Test func pauseCancelsCooperativeResolverAndKeepsTheInputQueued() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-cooperative-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "cooperative")
        let provider = QueueFixtureProvider(), gate = QueueResolverGate(cooperative: true)
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: provider).makeSession(journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "cooperate", text: "later",
            operationID: "op-later", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)),
            resolver: QueueFixtureResolver(session: session, provider: provider, gate: gate))
        await gate.waitUntilEntered()
        await dispatcher.pause()
        #expect(await gate.waitUntilCancelled())
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        #expect(try await session.followUp(inputID: "cooperate")?.state == .queued)
        #expect(await provider.requests().isEmpty)
        try await journal.close()
    }

    @Test func revokedCapabilityIsNotReplacedByADefaultBindingAtDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-revoked-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "revoked")
        let provider = QueueFixtureProvider()
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: provider).makeSession(journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "limited", text: "not authorized",
            operationID: "op-limited", configurationRef: "old-scope"))
        let old = try await session.bindCapabilities(identity: "old", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        await old.revoke()
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)),
            resolver: QueueRevokedResolver(session: session, provider: provider, capabilities: old))
        await dispatcher.waitUntilPaused()
        #expect(try await session.followUp(inputID: "limited")?.state == .queued)
        #expect(await provider.requests().isEmpty)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        try await journal.close()
    }

    @Test func dispatcherWaitsForEarlierRunsPhysicalDrainBeforeNextInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-physical-drain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "physical-drain")
        let gate = QueuePhysicalDrainGate()
        let provider = QueueDrainProvider(gate: gate)
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let session = try agent.makeSession(journal: journal)
        let direct = try await session.run("current")
        _ = try await session.enqueueFollowUp(.init(inputID: "next", text: "later",
            operationID: "op-next", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(
            policy: .init(maxModelTurns: 2, maxToolCalls: 0, runTimeout: .seconds(10)),
            resolver: QueueDrainResolver(session: session, provider: provider))
        #expect(try await direct.wait().outcome == .completed)
        await gate.waitUntilEntered()
        #expect(await provider.requests().count == 1)
        #expect(try await session.followUp(inputID: "next")?.state == .queued)
        await gate.release()
        try await direct.waitForDrain()
        await provider.waitForRequestCount(2)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        #expect(try await session.followUp(inputID: "next")?.state != .queued)
        try await journal.close()
    }

    @Test func admittedInputAfterRestartDoesNotAutomaticallyRunOrAdvanceTheQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-interrupted-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "interrupted")
        let provider = QueueFixtureProvider()
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "admitted", text: "maybe executed",
            operationID: "stable-admitted", configurationRef: "v1"))
        _ = try await session.enqueueFollowUp(.init(inputID: "next", text: "still queued",
            operationID: "stable-next", configurationRef: "v1"))
        _ = try await journal.appendStartupCheckpoint([
            .sessionCreated, .checkpoint(history: [.user([.text("maybe executed")])], steeringIDs: []),
            .userMessage("maybe executed")
        ], sessionID: sessionID, runID: UUID(), deadline: .now.advanced(by: .seconds(5)),
           durability: .durable, followUpInputID: "admitted")
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try agent.makeSession(id: sessionID, journal: reopened)
        let dispatcher = try await restored.startFollowUpDispatch(
            policy: .init(maxModelTurns: 2, maxToolCalls: 0, runTimeout: .seconds(10)),
            resolver: QueueFixtureResolver(session: restored, provider: provider))
        await dispatcher.waitUntilPaused()
        #expect(await dispatcher.status().interruptedInputID == "admitted")
        #expect(await provider.requests().isEmpty)
        await #expect(throws: AgentFollowUpError.needsInspection) { try await dispatcher.resume() }
        #expect(try await restored.followUp(inputID: "admitted")?.state != .queued)
        try await dispatcher.resumeAfterInspection(inputID: "admitted")
        await provider.waitForRequestCount(1)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        #expect(await provider.requests().count == 1)
        #expect(try await restored.followUp(inputID: "next")?.state != .queued)
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func stoppedInspectionCannotRestartDispatcherOrReleaseItsLeaseEarly(_ cancelCaller: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-inspection-stop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let barrier = QueueCommitBarrier()
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "inspection-stop", fault: { barrier.check($0) })
        let provider = QueueFixtureProvider()
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let id = UUID()
        let session = try agent.makeSession(id: id, journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "interrupted", text: "first",
            operationID: "op-first", configurationRef: "v1"))
        _ = try await session.enqueueFollowUp(.init(inputID: "later", text: "second",
            operationID: "op-second", configurationRef: "v1"))
        _ = try await journal.appendStartupCheckpoint([
            .sessionCreated, .checkpoint(history: [.user([.text("first")])], steeringIDs: []),
            .userMessage("first")
        ], sessionID: id, runID: UUID(), deadline: .now.advanced(by: .seconds(5)),
           durability: .durable, followUpInputID: "interrupted")
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(),
            resolver: QueueFixtureResolver(session: session, provider: provider))
        await dispatcher.waitUntilPaused()
        barrier.arm()
        let inspection = Task { try await dispatcher.resumeAfterInspection(inputID: "interrupted") }
        #expect(await barrier.waitUntilEntered())
        if cancelCaller { inspection.cancel() }
        await dispatcher.stop()
        await #expect(throws: AgentFollowUpError.dispatcherStopped) {
            try await dispatcher.resumeAfterInspection(inputID: "interrupted")
        }
        #expect(!(await dispatcher.status().physicallyDrained))
        barrier.release()
        await #expect(throws: AgentFollowUpError.staleDispatch) { try await inspection.value }
        try await dispatcher.waitForDrain()
        let status = await dispatcher.status()
        #expect(status.mode == .stopped && status.physicallyDrained)
        #expect(await provider.requests().isEmpty)
        #expect(try await session.followUp(inputID: "later")?.state == .queued)
        try await journal.close()
    }

    @Test(arguments: [StopReason.refusal, .maxOutputTokens])
    func existingDirectRunFailurePausesBeforeQueuedInput(_ stop: StopReason) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-initial-outcome-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "initial-outcome")
        let gate = QueuePhysicalDrainGate()
        let provider = QueueInitialOutcomeProvider(stop: stop, gate: gate)
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let session = try agent.makeSession(journal: journal)
        let direct = try await session.run("first")
        _ = try await session.enqueueFollowUp(.init(inputID: "later", text: "second",
            operationID: "op-second", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)),
            resolver: QueueInitialOutcomeResolver(session: session, provider: provider))
        _ = try? await direct.wait()
        await gate.waitUntilEntered()
        #expect(await provider.requests().count == 1)
        await gate.release()
        try await direct.waitForDrain()
        let unexpected = await XCTWaiter.fulfillment(of: [provider.secondRequest], timeout: 2)
        #expect(unexpected == .timedOut)
        #expect(await dispatcher.status().mode == .paused)
        #expect(await provider.requests().count == 1)
        #expect(try await session.followUp(inputID: "later")?.state == .queued)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        try await journal.close()
    }

    @Test func manualPauseCannotInspectAnUnfinishedReadOnlyRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-inspection-active-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "inspection-active")
        let provider = QueueDrainProvider(gate: QueuePhysicalDrainGate())
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let id = UUID(), session = try agent.makeSession(id: id, journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "old", text: "old",
            operationID: "op-old", configurationRef: "v1"))
        _ = try await session.enqueueFollowUp(.init(inputID: "later", text: "later",
            operationID: "op-later", configurationRef: "v1"))
        _ = try await journal.appendStartupCheckpoint([
            .sessionCreated, .checkpoint(history: [.user([.text("old")])], steeringIDs: []),
            .userMessage("old")
        ], sessionID: id, runID: UUID(), deadline: .now.advanced(by: .seconds(5)),
           durability: .durable, followUpInputID: "old")
        let direct = try await session.run("current")
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(),
            resolver: QueueDrainResolver(session: session, provider: provider))
        await dispatcher.pause()
        await #expect(throws: AgentFollowUpError.staleDispatch) {
            try await dispatcher.resumeAfterInspection(inputID: "old")
        }
        #expect(try await session.followUp(inputID: "later")?.state == .queued)
        await dispatcher.stop()
        await provider.gate.release()
        _ = try? await direct.wait()
        try await dispatcher.waitForDrain()
        try await journal.close()
    }

    @Test func failedExistingDirectRunCannotStartQueuedInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-initial-error-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "initial-error")
        let gate = QueuePhysicalDrainGate()
        let provider = QueueInitialOutcomeProvider(stop: .endTurn, gate: gate, failFirst: true)
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: provider).makeSession(journal: journal)
        let direct = try await session.run("first")
        _ = try await session.enqueueFollowUp(.init(inputID: "later", text: "second",
            operationID: "op-second", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(),
            resolver: QueueInitialOutcomeResolver(session: session, provider: provider))
        _ = try? await direct.wait()
        await gate.waitUntilEntered()
        await gate.release()
        try await direct.waitForDrain()
        await dispatcher.waitUntilPaused()
        #expect(await provider.requests().count == 1)
        #expect(try await session.followUp(inputID: "later")?.state == .queued)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        try await journal.close()
    }

    @Test func cancelledExistingDirectRunCannotStartQueuedInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-initial-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "initial-cancel")
        let work = QueueResolverGate(cooperative: true), drain = QueuePhysicalDrainGate()
        let provider = QueueCancellableProvider(work: work, drain: drain)
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: provider).makeSession(journal: journal)
        let direct = try await session.run("first")
        await work.waitUntilEntered()
        _ = try await session.enqueueFollowUp(.init(inputID: "later", text: "second",
            operationID: "op-second", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(),
            resolver: QueueCancellableResolver(session: session, provider: provider))
        await direct.cancel()
        #expect(await work.waitUntilCancelled())
        _ = try? await direct.wait()
        await drain.waitUntilEntered()
        await drain.release()
        try await direct.waitForDrain()
        await dispatcher.waitUntilPaused()
        #expect(await provider.requests().count == 1)
        #expect(try await session.followUp(inputID: "later")?.state == .queued)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        try await journal.close()
    }

    @Test(arguments: [StopReason.refusal, .maxOutputTokens])
    func refusedOrIncompleteRunPausesBeforeTheNextQueuedInput(_ stop: StopReason) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-halt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "halt")
        let provider = QueueFixtureProvider(firstStop: stop)
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: provider).makeSession(journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "first", text: "first",
            operationID: "op-first", configurationRef: "v1"))
        _ = try await session.enqueueFollowUp(.init(inputID: "second", text: "second",
            operationID: "op-second", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)),
            resolver: QueueFixtureResolver(session: session, provider: provider))
        await dispatcher.waitUntilPaused()
        #expect(await dispatcher.status().interruptedInputID == "first")
        #expect(await provider.requests().count == 1)
        #expect(try await session.followUp(inputID: "second")?.state == .queued)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        try await journal.close()
    }

    @Test func fullQueueStillAcceptsAnExistingIdentityAndNeverEvicts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-capacity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "capacity")
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: QueueFixtureProvider()).makeSession(journal: journal)
        for ordinal in 0..<128 {
            let value = AgentFollowUpInput(inputID: "id-\(ordinal)", text: "x",
                                           operationID: "op-\(ordinal)", configurationRef: "v1")
            #expect(try await session.enqueueFollowUp(value).ordinal == UInt64(ordinal))
        }
        let existing = AgentFollowUpInput(inputID: "id-0", text: "x",
                                          operationID: "op-0", configurationRef: "v1")
        #expect(try await session.enqueueFollowUp(existing).ordinal == 0)
        await #expect(throws: AgentFollowUpError.queueFull) {
            try await session.enqueueFollowUp(.init(inputID: "overflow", text: "x",
                operationID: "op-overflow", configurationRef: "v1"))
        }
        #expect(try await session.withdrawFollowUp(inputID: "id-0") == .withdrawn)
        #expect(try await session.enqueueFollowUp(.init(inputID: "next", text: "x",
            operationID: "op-next", configurationRef: "v1")).ordinal == 128)
        #expect(try await session.followUp(inputID: "id-0")?.state == .withdrawn)
        try await journal.close()
    }

    @Test func smallEnqueueDoesNotRewriteThePreviousLargeQueuedBody() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-large-tail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "large-tail")
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: QueueFixtureProvider()).makeSession(journal: journal)
        let large = String(repeating: "x", count: 200 * 1024)
        _ = try await session.enqueueFollowUp(.init(inputID: "large", text: large,
            operationID: "op-large", configurationRef: "v1"))
        let before = try #require(await journal.storageMetrics())
        _ = try await session.enqueueFollowUp(.init(inputID: "small", text: "short",
            operationID: "op-small", configurationRef: "v1"))
        let after = try #require(await journal.storageMetrics())
        #expect(after.bytesWritten - before.bytesWritten < 64 * 1024)
        #expect(try await session.followUpText(inputID: "large") == large)
        try await journal.close()
    }

    @Test func concurrentReceivesUsePublicationOrderAsFifoSequence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-order-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = QueueCommitBarrier()
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "ordering", fault: { gate.check($0) })
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: QueueFixtureProvider()).makeSession(journal: journal)
        gate.arm()
        let first = Task { try await session.enqueueFollowUp(.init(inputID: "first", text: "A",
            operationID: "op-A", configurationRef: "v1")) }
        #expect(await gate.waitUntilEntered())
        let second = Task { try await session.enqueueFollowUp(.init(inputID: "second", text: "B",
            operationID: "op-B", configurationRef: "v1")) }
        gate.release()
        #expect(try await first.value.ordinal == 0)
        #expect(try await second.value.ordinal == 1)
        #expect(try await session.followUps(after: nil, limit: 10).map(\.inputID) == ["first", "second"])
        try await journal.close()
    }

    @Test(arguments: [1, 2])
    func earlierSchemaIsRejectedWithoutModificationOrReset(_ schema: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-schema\(schema)-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = directory.appendingPathComponent("format.json")
        let original = Data("{\"magic\":\"SWIFTAGENT-SEGMENTED-JOURNAL\",\"schema\":\(schema),\"storeID\":\"\(UUID())\",\"domain\":\"old\"}".utf8)
        try original.write(to: format)
        #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try AgentIncrementalJournal.open(at: directory)
        }
        #expect(throws: AgentJournalError.persistenceUnavailable("create requires a new directory")) {
            _ = try AgentIncrementalJournal.create(at: directory, operationDomain: "new")
        }
        #expect(try Data(contentsOf: format) == original)
    }

    @Test func preAppendReceiveFailureIsDefiniteAndDoesNotPoisonTheStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-before-append-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = QueueFaultProbe()
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "pre-append", fault: { try fault.check($0) })
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: QueueFixtureProvider()).makeSession(journal: journal)
        fault.arm(.beforeAppend)
        await #expect(throws: AgentJournalError.persistenceUnavailable("synthetic prepublication failure")) {
            try await session.enqueueFollowUp(.init(inputID: "first", text: "not received",
                operationID: "op-first", configurationRef: "v1"))
        }
        #expect(try await session.followUp(inputID: "first") == nil)
        #expect(try await session.enqueueFollowUp(.init(inputID: "first", text: "not received",
            operationID: "op-first", configurationRef: "v1")).ordinal == 0)
        try await journal.close()
    }

    @Test func uncertainReceivePublicationIsRecoveredByTheSameInputID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-unknown-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = QueueFaultProbe()
        var journal: AgentJournal? = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "unknown", fault: { try fault.check($0) })
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                              provider: QueueFixtureProvider())
        let id = UUID()
        var session: AgentSession? = try agent.makeSession(id: id, journal: journal)
        fault.arm(.afterCurrentReplace)
        let input = AgentFollowUpInput(inputID: "stable", text: "received once",
                                       operationID: "stable-operation", configurationRef: "v1")
        await #expect(throws: AgentJournalError.commitUnknown) {
            try await session?.enqueueFollowUp(input)
        }
        session = nil
        journal = nil
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try agent.makeSession(id: id, journal: reopened)
        #expect(try await restored.followUp(inputID: "stable")?.state == .queued)
        #expect(try await restored.enqueueFollowUp(input).ordinal == 0)
        #expect(try await restored.followUps(after: nil, limit: 10).count == 1)
        try await reopened.close()
    }

    @Test func poisonedHandleClosesAfterDispatchDrainAndReopensWhileOldObjectsRemainAlive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-poison-close-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = QueueFaultProbe(), gate = QueueResolverGate(cooperative: false)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "poison-close", fault: { try fault.check($0) })
        let provider = QueueFixtureProvider()
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let session = try agent.makeSession(journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "held", text: "held",
            operationID: "op-held", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)),
            resolver: QueueFixtureResolver(session: session, provider: provider, gate: gate))
        await gate.waitUntilEntered()
        fault.arm(.afterCurrentReplace)
        await #expect(throws: AgentJournalError.commitUnknown) {
            try await session.enqueueFollowUp(.init(inputID: "uncertain", text: "maybe received",
                operationID: "op-uncertain", configurationRef: "v1"))
        }
        await dispatcher.stop()
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        await gate.release()
        try await dispatcher.waitForDrain()
        #expect(await provider.requests().isEmpty)
        #expect(throws: AgentJournalError.storeInUse) { _ = try AgentIncrementalJournal.open(at: directory) }
        fault.arm(.beforeClose)
        await #expect(throws: AgentJournalError.persistenceUnavailable("synthetic close failure")) {
            try await journal.close()
        }
        #expect(throws: AgentJournalError.storeInUse) { _ = try AgentIncrementalJournal.open(at: directory) }
        await #expect(throws: AgentJournalError.storeClosed) {
            _ = try await journal.appendCheckpoint([
                .checkpoint(history: [.user([.text("late")])], steeringIDs: [])
            ], sessionID: session.id, runID: UUID(), durability: .durable)
        }
        try await journal.close() // Poisoned does not mean ownership must leak until deinit.
        try await journal.close()
        await #expect(throws: AgentJournalError.storeClosed) {
            try await session.enqueueFollowUp(.init(inputID: "late", text: "cannot publish",
                operationID: "op-late", configurationRef: "v1"))
        }
        await #expect(throws: AgentJournalError.storeClosed) {
            try await session.run("must not reach Provider")
        }
        await #expect(throws: AgentJournalError.storeClosed) { try await journal.requestMaintenance() }
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try agent.makeSession(id: session.id, journal: reopened)
        #expect(try await restored.followUp(inputID: "uncertain")?.state == .queued)
        #expect(try await restored.followUp(inputID: "held")?.state == .queued)
        #expect(try await restored.followUp(inputID: "late") == nil)
        #expect(try await reopened.readMessages(sessionID: session.id).isEmpty)
        #expect(await provider.requests().isEmpty)
        try await reopened.close()
    }

    @Test(arguments: [JournalFileFaultStage.partialAppend, .beforeAppendSync, .afterAppendSync,
                      .beforeManagedWrite, .beforeManagedSync, .afterIndexSync,
                      .beforeCurrentReplace])
    func unpublishedQueueFailureDoesNotBecomeAnAcceptedInput(_ stage: JournalFileFaultStage) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-unpublished-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = QueueFaultProbe()
        var journal: AgentJournal? = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "unpublished", fault: { try fault.check($0) })
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                              provider: QueueFixtureProvider())
        let id = UUID()
        var session: AgentSession? = try agent.makeSession(id: id, journal: journal)
        fault.arm(stage)
        await #expect(throws: AgentJournalError.commitUnknown) {
            try await session?.enqueueFollowUp(.init(inputID: "id", text: "not published",
                operationID: "op-id", configurationRef: "v1"))
        }
        session = nil; journal = nil
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try agent.makeSession(id: id, journal: reopened)
        #expect(try await restored.followUp(inputID: "id") == nil)
        #expect(try await restored.enqueueFollowUp(.init(inputID: "id", text: "not published",
            operationID: "op-id", configurationRef: "v1")).ordinal == 0)
        try await reopened.close()
    }

    @Test func uncertainAtomicAdmissionDoesNotRequeueOrCallProviderAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-admit-unknown-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = QueueFaultProbe()
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "admit-unknown", fault: { try fault.check($0) })
        let provider = QueueFixtureProvider()
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let id = UUID()
        let session = try agent.makeSession(id: id, journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "one", text: "committed once",
            operationID: "stable-one", configurationRef: "v1"))
        let dispatcher = try await session.startFollowUpDispatch(
            policy: .init(maxModelTurns: 2, maxToolCalls: 0, runTimeout: .seconds(10)),
            resolver: QueueFaultingResolver(session: session, provider: provider, fault: fault))
        await dispatcher.waitUntilPaused()
        #expect(await provider.requests().isEmpty)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        try await journal.close()
        await #expect(throws: AgentJournalError.storeClosed) {
            try await session.run("do not reuse the poisoned startup")
        }

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let record = try #require(try await reopened.followUp(sessionID: id, inputID: "one"))
        guard case .admitted(let runID, let formalID) = record.state else {
            Issue.record("published startup lost its association"); return
        }
        let messages = try await reopened.readMessages(sessionID: id)
        #expect(messages.count == 1)
        #expect(messages.first?.id == formalID)
        #expect(try await reopened.followUps(sessionID: id, after: nil, limit: 10).count == 1)
        #expect(try await reopened.interruptedFollowUp(sessionID: id)?.ordinal == record.ordinal)
        #expect(runID != UUID())
        #expect(await provider.requests().isEmpty)
        try await reopened.close()
    }

    @Test func maintenanceReclaimsSegmentsWithoutForgettingQueueIdentityOrBodies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-gc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 8192,
                                                  maxUnreclaimedBytes: 65536, maxSegmentBatches: 2)
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "queue-gc", policy: policy)
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                              provider: QueueFixtureProvider())
        let id = UUID(), session = try agent.makeSession(id: id, journal: journal)
        for ordinal in 0..<16 {
            _ = try await session.enqueueFollowUp(.init(inputID: "id-\(ordinal)",
                text: "body-\(ordinal)-\(String(repeating: "x", count: 80))",
                operationID: "op-\(ordinal)", configurationRef: "v1"))
            if ordinal.isMultiple(of: 2) {
                #expect(try await session.withdrawFollowUp(inputID: "id-\(ordinal)") == .withdrawn)
            }
        }
        for _ in 0..<50 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        #expect(try await journal.storeStatus()?.sealedSegments == 0)
        for ordinal in 0..<16 {
            #expect(try await session.followUp(inputID: "id-\(ordinal)")?.state ==
                    (ordinal.isMultiple(of: 2) ? .withdrawn : .queued))
            #expect(try await session.followUpText(inputID: "id-\(ordinal)").hasPrefix("body-\(ordinal)-"))
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        #expect(try await reopened.followUps(sessionID: id, after: nil, limit: 100).count == 16)
        try await reopened.close()
    }

    @Test func maintenanceSnapshotCannotOverwriteNewReceiveOrWithdrawal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-maintenance-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 8192,
                                                  maxUnreclaimedBytes: 65536, maxSegmentBatches: 2)
        let gate = QueueMaintenanceBarrier()
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "maintenance-race", policy: policy, fault: { gate.check($0) })
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                              provider: QueueFixtureProvider())
        let id = UUID(), session = try agent.makeSession(id: id, journal: journal)
        // Arm before rotation; automatic maintenance may otherwise finish
        // its only sealed candidate before an explicit request can pause it.
        gate.arm()
        for ordinal in 0..<5 {
            _ = try await session.enqueueFollowUp(.init(inputID: "old-\(ordinal)", text: "old-\(ordinal)",
                operationID: "op-old-\(ordinal)", configurationRef: "v1"))
        }
        let maintenance = Task { try await journal.requestMaintenance() }
        #expect(await gate.waitUntilEntered())
        _ = try await session.enqueueFollowUp(.init(inputID: "new", text: "after snapshot",
            operationID: "op-new", configurationRef: "v2"))
        #expect(try await session.withdrawFollowUp(inputID: "old-0") == .withdrawn)
        gate.release()
        _ = try await maintenance.value
        for _ in 0..<30 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        #expect(try await reopened.followUp(sessionID: id, inputID: "new")?.state == .queued)
        #expect(try await reopened.followUp(sessionID: id, inputID: "old-0")?.state == .withdrawn)
        #expect(try await reopened.followUps(sessionID: id, after: nil, limit: 20).count == 6)
        try await reopened.close()
    }

    @Test func atomicAdmissionPublishesQueueRunAndFormalMessageTogether() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-admit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "admission")
        let sessionID = UUID(), runID = UUID()
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: QueueFixtureProvider()).makeSession(id: sessionID, journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "one", text: "formal input",
                                               operationID: "logical-one", configurationRef: "current"))
        _ = try await journal.appendStartupCheckpoint([
            .sessionCreated,
            .checkpoint(history: [.user([.text("formal input")])], steeringIDs: []),
            .userMessage("formal input")
        ], sessionID: sessionID, runID: runID, deadline: .now.advanced(by: .seconds(5)),
           durability: .durable, followUpInputID: "one")
        let record = try #require(try await session.followUp(inputID: "one"))
        guard case .admitted(let linkedRun, let formalID) = record.state else {
            Issue.record("missing queue admission"); return
        }
        #expect(linkedRun == runID)
        #expect(try await journal.readMessages(sessionID: sessionID).map(\.id) == [formalID])
        await #expect(throws: AgentJournalError.concurrentWriter) {
            try await journal.appendStartupCheckpoint([
                .checkpoint(history: [.user([.text("formal input")]), .user([.text("duplicated")])], steeringIDs: [])
            ], sessionID: sessionID, runID: UUID(), deadline: .now.advanced(by: .seconds(5)),
               durability: .durable, followUpInputID: "one")
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let persisted = try #require(try await reopened.readMessages(sessionID: sessionID).first)
        #expect(persisted.id == formalID)
        #expect(try await reopened.latestCheckpoint(sessionID: sessionID)?.history == [.user([.text("formal input")])])
        try await reopened.close()
    }

    @Test func durableAcceptDedupConflictWithdrawAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "queue-domain")
        let provider = QueueFixtureProvider()
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let id = UUID()
        let session = try agent.makeSession(id: id, journal: journal)
        let first = AgentFollowUpInput(inputID: "a", text: "first", operationID: "op-a", configurationRef: "v1")
        let second = AgentFollowUpInput(inputID: "b", text: "second", operationID: "op-b", configurationRef: "v1")
        let accepted = try await session.enqueueFollowUp(first)
        #expect(accepted.ordinal == 0)
        #expect(accepted.state == .queued)
        #expect(try await session.enqueueFollowUp(first) == accepted)
        #expect(try await session.enqueueFollowUp(second).ordinal == 1)
        await #expect(throws: AgentFollowUpError.inputConflict) {
            try await session.enqueueFollowUp(.init(inputID: "a", text: "changed", operationID: "op-a", configurationRef: "v1"))
        }
        #expect(await session.history == [])
        #expect(await provider.requests().isEmpty)
        #expect(try await session.withdrawFollowUp(inputID: "a") == .withdrawn)
        #expect(try await session.followUp(inputID: "a")?.state == .withdrawn)
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try agent.makeSession(id: id, journal: reopened)
        #expect(try await restored.followUp(inputID: "a")?.state == .withdrawn)
        #expect(try await restored.followUp(inputID: "b")?.state == .queued)
        #expect(try await restored.followUps(after: nil, limit: 10).map(\.inputID) == ["a", "b"])
        #expect(try await restored.enqueueFollowUp(first).ordinal == 0)
        try await reopened.close()
    }

    @Test func queueOnlyCommitDoesNotInvalidateActiveConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-concurrent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "queue-concurrent")
        let provider = QueueFixtureProvider()
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("live")
        let before = try await session.conversationSnapshot()
        _ = try await session.enqueueFollowUp(.init(inputID: "next", text: "later",
            operationID: "logical-later", configurationRef: "current"))
        #expect(try await session.conversationSnapshot().revision == before.revision)
        #expect(try await run.wait().outcome == .completed)
        try await run.waitForDrain()
        #expect(await session.history.contains(.user([.text("live")])))
        #expect(!(await session.history).contains(.user([.text("later")])))
        #expect(try await session.followUp(inputID: "next")?.state == .queued)
        try await journal.close()
    }

    @Test func enqueueDuringRealMutationSettlementPreservesReceiptAndCallPairing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-mutation-interleave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("effect.txt")
        try Data().write(to: file)
        let journal = try AgentIncrementalJournal.create(at: directory.appendingPathComponent("journal"),
                                                          operationDomain: "interleave")
        let gate = QueueMutationGate()
        let call = ToolCall(id: .init(rawValue: "write-B"), name: QueueMutationTool.name,
                            argumentsJSON: #"{"id":"B"}"#, completeness: .complete)
        let provider = ScriptedProvider { request, _ in
            request.messages.last?.role == .tool ? textResponse(request, "done") : toolResponse(request, [call])
        }
        let agent = try Agent(model: fixtureModel, provider: provider,
                              tools: [try QueueMutationTool(file: file, gate: gate)])
        let sessionID = UUID(), session = try agent.makeSession(id: sessionID, journal: journal)
        let run = try await session.run("write B", operationID: "stable-write")
        await gate.waitUntilEntered()
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
        let before = try await session.conversationSnapshot().revision
        _ = try await session.enqueueFollowUp(.init(inputID: "next", text: "later",
            operationID: "stable-next", configurationRef: "v1"))
        #expect(try await session.conversationSnapshot().revision == before)
        await gate.release()
        #expect(try await run.wait().receipts.count == 1)
        try await run.waitForDrain()
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory.appendingPathComponent("journal"))
        let history = try #require(try await reopened.latestCheckpoint(sessionID: sessionID)?.history)
        #expect(history.contains(.assistant(content: [], toolCalls: [call])))
        #expect(history.contains(where: { if case .tool(let result) = $0 { return result.callID == call.id }; return false }))
        #expect(try await reopened.mutationStatus(identity: #"stable-write/queue_mutation/{"id":"B"}"#)?.state == .settled)
        #expect(try await reopened.followUp(sessionID: sessionID, inputID: "next")?.state == .queued)
        try await reopened.close()
    }

    @Test(arguments: ["sessions", "queue-heads", "queue-ids", "operations"])
    func missingNecessaryIndexCannotLookLikeAnEmptyStore(_ kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-missing-\(kind)-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("effect.txt")
        try Data().write(to: file)
        let store = directory.appendingPathComponent("journal")
        let gate = QueueMutationGate(), entered = QueueEffectCounts()
        await gate.release()
        let call = ToolCall(id: .init(rawValue: "indexed-write"), name: QueueMutationTool.name,
                            argumentsJSON: #"{"id":"B"}"#, completeness: .complete)
        let provider = ScriptedProvider { request, _ in
            request.messages.last?.role == .tool ? textResponse(request, "done") : toolResponse(request, [call])
        }
        let agent = try Agent(model: fixtureModel, provider: provider,
            tools: [try QueueMutationTool(file: file, gate: gate, entered: entered)])
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024,
            maxWorkBytes: 4 * 1024 * 1024, maxUnreclaimedBytes: 8 * 1024 * 1024,
            maxSegmentBatches: 1)
        let journal = try AgentIncrementalJournal.create(at: store,
            operationDomain: "missing-index", policy: policy)
        let sessionID = UUID(), session = try agent.makeSession(id: sessionID, journal: journal)
        let queued = AgentFollowUpInput(inputID: "stable-input", text: "later",
                                        operationID: "queued-op", configurationRef: "v1")
        #expect(try await session.enqueueFollowUp(queued).ordinal == 0)
        let run = try await session.run("write B", operationID: "stable-index-write")
        #expect(try await run.wait().receipts.count == 1)
        try await run.waitForDrain()
        #expect(await entered.value == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
        var history = await session.history
        for number in 0..<4 {
            history.append(.user([.text("retained \(number)")]))
            _ = try await journal.appendCheckpoint([
                .checkpoint(history: history, steeringIDs: [])
            ], sessionID: sessionID, runID: UUID(), durability: .durable)
        }
        try await journal.close()

        let indexRoot = store.appendingPathComponent(kind)
        let shard = try #require(FileManager.default.contentsOfDirectory(at: indexRoot,
            includingPropertiesForKeys: nil).first)
        let index = try #require(FileManager.default.contentsOfDirectory(at: shard,
            includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "json" }))
        let saved = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        let reopened = try AgentIncrementalJournal.open(at: store, policy: policy)
        for _ in 0..<16 {
            do { _ = try await reopened.requestMaintenance() }
            catch AgentJournalError.invalidRecord { break }
        }
        // An unvisited pack may be left intact or another index may keep a
        // frame live. Restoring this single synthetic deletion must still
        // recover every committed fact after any maintenance that did run.
        switch kind {
        case "sessions":
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await reopened.latestCheckpoint(sessionID: sessionID)
            }
        case "queue-heads":
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await reopened.followUps(sessionID: sessionID, after: nil, limit: 10)
            }
            let restored = try agent.makeSession(id: sessionID, journal: reopened)
            await #expect(throws: AgentJournalError.invalidRecord) {
                try await restored.enqueueFollowUp(.init(inputID: "new", text: "new",
                    operationID: "new-op", configurationRef: "v1"))
            }
        case "queue-ids":
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await reopened.followUp(sessionID: sessionID, inputID: queued.inputID)
            }
            let restored = try agent.makeSession(id: sessionID, journal: reopened)
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await restored.enqueueFollowUp(queued)
            }
        case "operations":
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await reopened.mutationStatus(identity: #"stable-index-write/queue_mutation/{"id":"B"}"#)
            }
            let retry = try agent.makeSession(journal: reopened)
            await #expect(throws: AgentJournalError.invalidRecord) {
                let replay = try await retry.run("write B", operationID: "stable-index-write")
                do { _ = try await replay.wait() }
                catch {
                    try await replay.waitForDrain()
                    throw error
                }
                try await replay.waitForDrain()
            }
        default: Issue.record("unexpected index kind")
        }
        #expect(await entered.value == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
        try await reopened.close()
        try saved.write(to: index)
        let repaired = try AgentIncrementalJournal.open(at: store, policy: policy)
        #expect(try await repaired.followUp(sessionID: sessionID, inputID: queued.inputID)?.ordinal == 0)
        #expect(try await repaired.readMessages(sessionID: sessionID).count >= 4)
        #expect(try await repaired.mutationStatus(identity: #"stable-index-write/queue_mutation/{"id":"B"}"#)?.state == .settled)
        try await repaired.close()
        // Losing an entire index shard still leaves the independent witness.
        try FileManager.default.removeItem(at: shard)
        let missingShard = try AgentIncrementalJournal.open(at: store, policy: policy)
        switch kind {
        case "sessions":
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await missingShard.latestCheckpoint(sessionID: sessionID)
            }
        case "queue-heads":
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await missingShard.followUps(sessionID: sessionID, after: nil, limit: 1)
            }
        case "queue-ids":
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await missingShard.followUp(sessionID: sessionID, inputID: queued.inputID)
            }
        case "operations":
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await missingShard.mutationStatus(identity: #"stable-index-write/queue_mutation/{"id":"B"}"#)
            }
        default: Issue.record("unexpected index kind")
        }
        try await missingShard.close()
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: false)
        try saved.write(to: index)
        // The complementary loss of the witness must also fail closed while
        // the index itself remains present.
        let digest = try #require(index.deletingPathExtension().lastPathComponent.split(separator: "_").last)
        let storeID = try #require(await journal.storeIdentity()).storeID.uuidString
        let witness = store.appendingPathComponent("witnesses/\(digest.prefix(2))/\(storeID)_\(kind)_\(digest).witness")
        try FileManager.default.removeItem(at: witness)
        let missingWitness = try AgentIncrementalJournal.open(at: store, policy: policy)
        switch kind {
        case "sessions":
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await missingWitness.latestCheckpoint(sessionID: sessionID)
            }
        case "queue-heads":
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await missingWitness.followUps(sessionID: sessionID, after: nil, limit: 1)
            }
        case "queue-ids":
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await missingWitness.followUp(sessionID: sessionID, inputID: queued.inputID)
            }
        case "operations":
            await #expect(throws: AgentJournalError.invalidRecord) {
                _ = try await missingWitness.mutationStatus(identity: #"stable-index-write/queue_mutation/{"id":"B"}"#)
            }
        default: Issue.record("unexpected index kind")
        }
        try await missingWitness.close()
    }

    @Test func unpublishedIndexWitnessCannotTurnANewIdentityIntoCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-orphan-witness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = QueueFaultProbe()
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "orphan-witness", fault: { try fault.check($0) })
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                              provider: QueueFixtureProvider())
        let id = UUID(), session = try agent.makeSession(id: id, journal: journal)
        fault.arm(.afterIndexSync)
        await #expect(throws: AgentJournalError.commitUnknown) {
            try await session.enqueueFollowUp(.init(inputID: "never-published", text: "candidate",
                operationID: "candidate-op", configurationRef: "v1"))
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try agent.makeSession(id: id, journal: reopened)
        #expect(try await restored.followUp(inputID: "never-published") == nil)
        #expect(try await restored.enqueueFollowUp(.init(inputID: "different", text: "published",
            operationID: "different-op", configurationRef: "v1")).ordinal == 0)
        // The orphan witness has the same sequence as the real commit, but a
        // different immutable commit identity. It must not fabricate a fact.
        #expect(try await restored.followUp(inputID: "never-published") == nil)
        #expect(try await restored.enqueueFollowUp(.init(inputID: "never-published", text: "candidate",
            operationID: "candidate-op", configurationRef: "v1")).ordinal == 1)
        let fresh = try agent.makeSession(journal: reopened)
        #expect(try await fresh.enqueueFollowUp(.init(inputID: "first-here", text: "new Session",
            operationID: "fresh-op", configurationRef: "v1")).ordinal == 0)
        try await reopened.close()
    }
}

private final class QueueEffectCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var executions = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return executions }
    func enter() { lock.lock(); executions += 1; lock.unlock() }
}

private actor QueueFixtureRequests {
    var values: [ModelRequest] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func append(_ value: ModelRequest) {
        values.append(value)
        let finished = waiters.filter { values.count >= $0.0 }
        waiters.removeAll { values.count >= $0.0 }
        finished.forEach { $0.1.resume() }
    }
    func waitForCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private struct QueueFixtureProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "queue-fixture", capabilities: [.streaming, .multiTurn])
    var firstStop: StopReason? = nil
    private let log = QueueFixtureRequests()
    func requests() async -> [ModelRequest] { await log.values }
    func waitForRequestCount(_ count: Int) async { await log.waitForCount(count) }
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await log.append(request)
            let info = ResponseInfo(id: "fixed", model: request.model)
            try emit(.responseStarted(info))
            try emit(.textDelta("done"))
            let stop: StopReason = request.messages.last == .user([.text("first")]) ? firstStop ?? .endTurn : .endTurn
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: stop)))
        }
    }
}

private struct QueueFixtureResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: QueueFixtureProvider
    var gate: QueueResolverGate? = nil
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        try await gate?.wait()
        let scope = try await session.bindCapabilities(identity: "explicit-empty", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        return .init(model: try AgentModelBinding(profileID: "queue-fixture", profileRevision: "1",
            model: .init(provider: "queue-fixture", name: "fixed"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")),
            capabilities: scope, expectedConversationRevision: nil)
    }
}

private struct QueueFirstResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: QueueFixtureProvider
    let gate: QueueResolverGate
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        if request.record.inputID == "remove" { try await gate.wait() }
        return try await QueueFixtureResolver(session: session, provider: provider).resolve(request)
    }
}

private struct QueueFirstFaultResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: QueueFixtureProvider
    let gate: QueueResolverGate
    let fault: QueueFaultProbe
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        if request.record.inputID == "remove" { try await gate.wait() }
        else { fault.arm(.beforeAppend) }
        return try await QueueFixtureResolver(session: session, provider: provider).resolve(request)
    }
}

private struct QueueFaultingResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: QueueFixtureProvider
    let fault: QueueFaultProbe
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        fault.arm(.afterCurrentReplace)
        return try await QueueFixtureResolver(session: session, provider: provider).resolve(request)
    }
}

private struct QueueRevokedResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: QueueFixtureProvider
    let capabilities: AgentCapabilityBinding
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        let unscoped = try await QueueFixtureResolver(session: session, provider: provider).resolve(request)
        return .init(model: unscoped.model, capabilities: capabilities)
    }
}

private actor QueueResolverGate {
    private let cooperative: Bool
    private let cancelled = XCTestExpectation(description: "resolver received cancellation")
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Error>?
    init(cooperative: Bool) { self.cooperative = cooperative }
    func wait() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                entered = true
                let pending = observers
                observers.removeAll()
                pending.forEach { $0.resume() }
                if Task.isCancelled && cooperative { self.continuation = nil; continuation.resume(throwing: CancellationError()) }
            }
        }, onCancel: {
            cancelled.fulfill()
            Task { await self.cancelIfCooperative() }
        })
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func waitUntilCancelled() async -> Bool {
        await XCTWaiter.fulfillment(of: [cancelled], timeout: 3) == .completed
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
    private func cancelIfCooperative() {
        guard cooperative else { return }
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor QueuePhysicalDrainGate {
    private var released = false
    private var entered = false
    private var enteredObservers: [CheckedContinuation<Void, Never>] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !released else { return }
        entered = true
        let pending = enteredObservers
        enteredObservers.removeAll()
        pending.forEach { $0.resume() }
        await withCheckedContinuation { drainWaiters.append($0) }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredObservers.append($0) }
    }
    func release() {
        released = true
        let pending = drainWaiters
        drainWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct QueueDrainProvider: ModelProvider, ModelProviderRunDrain {
    let descriptor = ModelProviderDescriptor(id: "queue-fixture", capabilities: [.streaming, .multiTurn])
    let gate: QueuePhysicalDrainGate
    private let log = QueueFixtureRequests()
    func requests() async -> [ModelRequest] { await log.values }
    func waitForRequestCount(_ count: Int) async { await log.waitForCount(count) }
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await log.append(request)
            let info = ResponseInfo(id: "fixed", model: request.model)
            try emit(.responseStarted(info))
            try emit(.textDelta("done"))
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
        }
    }
    func waitForRunToDrain(sessionID: UUID, runID: UUID) async { await gate.wait() }
}

private struct QueueDrainResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: QueueDrainProvider
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        let scope = try await session.bindCapabilities(identity: "explicit-empty", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        return .init(model: try AgentModelBinding(profileID: "queue-fixture", profileRevision: "1",
            model: .init(provider: "queue-fixture", name: "fixed"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")),
            capabilities: scope, expectedConversationRevision: nil)
    }
}

private struct QueueInitialOutcomeProvider: ModelProvider, ModelProviderRunDrain {
    let descriptor = ModelProviderDescriptor(id: "queue-fixture", capabilities: [.streaming, .multiTurn])
    let stop: StopReason
    let gate: QueuePhysicalDrainGate
    var failFirst = false
    let secondRequest = XCTestExpectation(description: "unexpected second Provider request")
    private let log = QueueFixtureRequests()
    func requests() async -> [ModelRequest] { await log.values }
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await log.append(request)
            if await log.values.count == 2 { secondRequest.fulfill() }
            let info = ResponseInfo(id: "fixed", model: request.model)
            try emit(.responseStarted(info))
            if failFirst && request.messages.last == .user([.text("first")]) {
                throw AgentJournalError.invalidRecord
            }
            try emit(.responseCompleted(.init(info: info, content: [.text("done")],
                                             stopReason: request.messages.last == .user([.text("first")]) ? stop : .endTurn)))
        }
    }
    func waitForRunToDrain(sessionID: UUID, runID: UUID) async { await gate.wait() }
}

private struct QueueInitialOutcomeResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: QueueInitialOutcomeProvider
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        let scope = try await session.bindCapabilities(identity: "initial-outcome", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        return .init(model: try AgentModelBinding(profileID: "queue-fixture", profileRevision: "1",
            model: .init(provider: "queue-fixture", name: "fixed"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")),
            capabilities: scope)
    }
}

private struct QueueCancellableProvider: ModelProvider, ModelProviderRunDrain {
    let descriptor = ModelProviderDescriptor(id: "queue-fixture", capabilities: [.streaming, .multiTurn])
    let work: QueueResolverGate
    let drain: QueuePhysicalDrainGate
    private let log = QueueFixtureRequests()
    func requests() async -> [ModelRequest] { await log.values }
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await log.append(request)
            if request.messages.last == .user([.text("first")]) { try await work.wait() }
            let info = ResponseInfo(id: "fixed", model: request.model)
            try emit(.responseStarted(info))
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
        }
    }
    func waitForRunToDrain(sessionID: UUID, runID: UUID) async { await drain.wait() }
}

private struct QueueCancellableResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: QueueCancellableProvider
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        let scope = try await session.bindCapabilities(identity: "cancelled-run", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        return .init(model: try AgentModelBinding(profileID: "queue-fixture", profileRevision: "1",
            model: .init(provider: "queue-fixture", name: "fixed"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")),
            capabilities: scope)
    }
}

private final class QueueFaultProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: JournalFileFaultStage?
    func arm(_ stage: JournalFileFaultStage) { lock.lock(); armed = stage; lock.unlock() }
    func check(_ stage: JournalFileFaultStage) throws {
        lock.lock()
        let shouldFail: Bool
        switch (armed, stage) {
        case (.beforeAppend?, .beforeAppend), (.afterCurrentReplace?, .afterCurrentReplace),
             (.beforeClose?, .beforeClose):
            shouldFail = true; armed = nil
        case (.partialAppend?, .partialAppend), (.beforeAppendSync?, .beforeAppendSync),
             (.afterAppendSync?, .afterAppendSync), (.beforeManagedWrite?, .beforeManagedWrite),
             (.beforeManagedSync?, .beforeManagedSync), (.afterIndexSync?, .afterIndexSync),
             (.beforeCurrentReplace?, .beforeCurrentReplace):
            shouldFail = true; armed = nil
        default: shouldFail = false
        }
        lock.unlock()
        if shouldFail {
            if case .beforeClose = stage {
                throw AgentJournalError.persistenceUnavailable("synthetic close failure")
            }
            throw AgentJournalError.persistenceUnavailable("synthetic prepublication failure")
        }
    }
}

private final class QueueCommitBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let entered = XCTestExpectation(description: "queue publisher reached append")
    private var armed = false, released = false
    func arm() { condition.lock(); armed = true; condition.unlock() }
    func check(_ stage: JournalFileFaultStage) {
        guard case .beforeAppend = stage else { return }
        condition.lock()
        guard armed else { condition.unlock(); return }
        armed = false
        entered.fulfill()
        while !released { condition.wait() }
        condition.unlock()
    }
    func waitUntilEntered() async -> Bool {
        await XCTWaiter.fulfillment(of: [entered], timeout: 3) == .completed
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

private final class QueueMaintenanceBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let entered = XCTestExpectation(description: "maintenance captured a candidate")
    private var armed = false, released = false
    func arm() { condition.lock(); armed = true; condition.unlock() }
    func check(_ stage: JournalFileFaultStage) {
        guard case .afterMaintenanceSnapshot = stage else { return }
        condition.lock()
        guard armed else { condition.unlock(); return }
        armed = false
        entered.fulfill()
        while !released { condition.wait() }
        condition.unlock()
    }
    func waitUntilEntered() async -> Bool {
        await XCTWaiter.fulfillment(of: [entered], timeout: 3) == .completed
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private actor QueueMutationGate {
    private var entered = false, released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let current = observers; observers.removeAll(); current.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        released = true
        let current = waiters; waiters.removeAll(); current.forEach { $0.resume() }
    }
}

private actor QueueResolverPhaseGate {
    private var entered = false, released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let current = observers; observers.removeAll(); current.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        released = true
        let current = waiters; waiters.removeAll(); current.forEach { $0.resume() }
    }
}

private struct QueueMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = "queue_mutation"
    static let description = "Write to one disposable fixture resource"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let file: URL
    let gate: QueueMutationGate
    let entered: QueueEffectCounts?
    let policy: ToolPolicy
    init(file: URL, gate: QueueMutationGate, entered: QueueEffectCounts? = nil) throws {
        self.file = file; self.gate = gate
        self.entered = entered
        policy = try .mutation(authorization: .notRequired, evidence: .none)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "queue.test", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "queue.test", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        entered?.enter()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("effect\n".utf8))
        try handle.synchronize()
        try handle.close()
        await gate.wait()
        return .init(output: .init(updated: true), receipt: .init(
            operationID: context.idempotencyKey ?? "", status: .succeeded,
            confirmedTargets: [.init(namespace: "queue.test", id: input.id)], revision: "v1"))
    }
}
