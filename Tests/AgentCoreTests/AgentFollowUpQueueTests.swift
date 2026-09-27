@testable import AgentCore
import AgentJournalFileStore
import AgentModels
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
            resolver: QueueFixtureResolver(provider: provider))
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
            resolver: QueueFixtureResolver(provider: provider))
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
            policy: .init(runTimeout: .seconds(10)), resolver: QueueFixtureResolver(provider: provider))
        await dispatcher.pause()
        await #expect(throws: AgentFollowUpError.dispatchOwned) { try await session.run("direct") }
        let replacement = try agent.makeSession(id: id, journal: journal)
        await #expect(throws: AgentFollowUpError.alreadyDispatching) {
            try await replacement.startFollowUpDispatch(
                policy: .init(), resolver: QueueFixtureResolver(provider: provider))
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
            resolver: QueueFixtureResolver(provider: provider, gate: gate))
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
            resolver: QueueFixtureResolver(provider: provider, gate: gate))
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
            resolver: QueueDrainResolver(provider: provider))
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
            resolver: QueueFixtureResolver(provider: provider))
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

    @Test func schemaOneStoreIsRejectedWithoutModificationOrReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-schema1-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = directory.appendingPathComponent("format.json")
        let original = Data("{\"magic\":\"SWIFTAGENT-SEGMENTED-JOURNAL\",\"schema\":1,\"storeID\":\"\(UUID())\",\"domain\":\"old\"}".utf8)
        try original.write(to: format)
        #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try AgentIncrementalJournal.open(at: directory)
        }
        #expect(throws: AgentJournalError.persistenceUnavailable("create requires a new directory")) {
            _ = try AgentIncrementalJournal.create(at: directory, operationDomain: "new")
        }
        #expect(try Data(contentsOf: format) == original)
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
}

private struct QueueFixtureResolver: AgentFollowUpResolver {
    let provider: QueueFixtureProvider
    var gate: QueueResolverGate? = nil
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        try await gate?.wait()
        return .init(model: try AgentModelBinding(profileID: "queue-fixture", profileRevision: "1",
            model: .init(provider: "queue-fixture", name: "fixed"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")),
            capabilities: nil, expectedConversationRevision: nil)
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
    let provider: QueueDrainProvider
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        .init(model: try AgentModelBinding(profileID: "queue-fixture", profileRevision: "1",
            model: .init(provider: "queue-fixture", name: "fixed"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")),
            capabilities: nil, expectedConversationRevision: nil)
    }
}
