@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

/// Unified session-level `commitUnknown` locking across startup, mid-run, mutation,
/// follow-up queue, and compaction write paths on the segmented file journal.
@Suite struct SessionCommitUnknownLockTests {
    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("session-commit-unknown-\(label)-\(UUID())")
    }

    private func makeFullJournal(
        at directory: URL,
        domain: String,
        fault: @escaping @Sendable (JournalFileFaultStage) throws -> Void
    ) throws -> AgentJournal {
        try AgentIncrementalJournal.createForTesting(
            at: directory,
            operationDomain: domain,
            supportsConfirmedNoEffect: true,
            supportsPerCallFollowUps: true,
            supportsRunRecords: true,
            supportsNativeContext: true,
            supportsContextHandoff: true,
            supportsIncompleteContextHandoff: true,
            fault: fault
        )
    }

    @Test func startupRunCommitUnknownPreservesInMemoryHistoryAndLocksAllSessionAPIs() async throws {
        let directory = tempDir("startup-run")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = FileCommitFaultController()
        let journal = try makeFullJournal(at: directory, domain: "startup-run", fault: { try fault.check($0) })

        let addLog = EffectLog()
        let addTool = try AddTool(log: addLog)
        let priorReadCall = ToolCall(
            id: .init(rawValue: "prior-add"),
            name: AddTool.name,
            argumentsJSON: #"{"lhs":2,"rhs":3}"#,
            completeness: .complete
        )
        let provider = SessionLockFixtureProvider { request, turn in
            if turn == 1 { return toolResponse(request, [priorReadCall]) }
            if turn == 2 { return textResponse(request, "sum is 5") }
            return textResponse(request, "after reopen")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding, tools: [addTool])
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindAddCapability(session: session, tool: addTool)

        let first = try await session.run("add 2 and 3")
        _ = try await first.wait()
        try await first.waitForDrain()
        let priorSnapshot = try await session.conversationSnapshot()
        let priorHistory = await session.history
        #expect(priorHistory == priorSnapshot.messages)
        #expect(await provider.requestCount == 2)

        fault.arm(.afterCurrentReplace)
        let uncertain = try await session.run("uncertain input")
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await uncertain.wait() }
        try await uncertain.waitForDrain()

        #expect(fault.firedCount(.afterCurrentReplace) == 1)
        #expect(await provider.requestCount == 2, "provider must not run when startup commit is unknown")
        #expect(await session.history == priorHistory, "unconfirmed input must not mutate in-memory history")
        #expect(!String(describing: await session.history).contains("uncertain input"))

        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            excerptCallID: priorReadCall.id
        )
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let expectedDurable = priorHistory + [.user([.text("uncertain input")])]
        #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.history == expectedDurable)

        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        let restoredSnapshot = try await fresh.conversationSnapshot()
        #expect(restoredSnapshot.messages == expectedDurable)
        let continued = try await fresh.run("after reopen")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        #expect(try await fresh.conversationSnapshot().revision > restoredSnapshot.revision)
        #expect(await provider.lastRequest?.messages == expectedDurable + [.user([.text("after reopen")])])
        try await reopened.close()
    }

    @Test func startupRunCommitUnknownPreservesOwedSteeringAndHistory() async throws {
        let directory = tempDir("startup-owed-steering")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = FileCommitFaultController()
        let journal = try makeFullJournal(at: directory, domain: "startup-owed-steering", fault: { try fault.check($0) })

        let (stalled, signal) = AsyncStream<Void>.makeStream()
        let provider = SessionLockFixtureProvider { request, turn in
            if turn == 1 {
                signal.yield()
                try await Task.sleep(for: .seconds(30))
            }
            return textResponse(request, "reply \(turn)")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)

        let first = try await session.run("original")
        for await _ in stalled { break }
        _ = try await first.steer("owed correction")
        // Definite failure while retaining steering leaves "owed correction" pending for the next startup.
        fault.arm(.beforeAppend)
        await first.cancel()
        await #expect(throws: AgentJournalError.self) { _ = try await first.wait() }
        try await first.waitForDrain()
        #expect(fault.firedCount(.beforeAppend) == 1)
        let priorHistory: [ModelMessage] = [.user([.text("original")])]
        #expect(await session.history == priorHistory)

        fault.arm(.afterCurrentReplace)
        let uncertain = try await session.run("uncertain next")
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await uncertain.wait() }
        try await uncertain.waitForDrain()

        #expect(fault.firedCount(.afterCurrentReplace) == 1)
        #expect(await provider.requestCount == 1, "provider must not run when startup commit is unknown")
        #expect(await session.history == priorHistory, "neither owed steering nor unconfirmed input may mutate session.history")
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await session.conversationSnapshot() }
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await session.run("blocked") }
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let expectedDurable: [ModelMessage] = [
            .user([.text("original")]),
            .user([.text("owed correction")]),
            .user([.text("uncertain next")]),
        ]
        #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.history == expectedDurable)
        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        #expect(try await fresh.conversationSnapshot().messages == expectedDurable)
        let continued = try await fresh.run("final input")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        #expect(await provider.lastRequest?.messages == expectedDurable + [.user([.text("final input")])])
        try await reopened.close()
    }

    @Test func startupHostInvocationCommitUnknownPreservesInMemoryHistoryAndLocksAllSessionAPIs() async throws {
        let directory = tempDir("startup-host")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = FileCommitFaultController()
        let journal = try makeFullJournal(at: directory, domain: "startup-host", fault: { try fault.check($0) })

        let addLog = EffectLog()
        let addTool = try AddTool(log: addLog)
        let provider = SessionLockFixtureProvider { request, turn in
            textResponse(request, turn == 1 ? "seed reply" : "reopened reply")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindAddCapability(session: session, tool: addTool)

        let seed = try await session.run("seed prompt")
        _ = try await seed.wait()
        try await seed.waitForDrain()
        let priorHistory = await session.history

        fault.arm(.afterCurrentReplace)
        let call = try await session.invokeHostTool(
            AgentHostToolCall(
                name: AddTool.name,
                argumentsJSON: #"{"lhs":4,"rhs":5}"#,
                note: "unconfirmed host call request"
            ),
            capabilities: capabilities,
            operationID: "host-startup-op"
        )
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await call.wait() }
        try await call.waitForDrain()

        #expect(fault.firedCount(.afterCurrentReplace) == 1)
        #expect(await addLog.names.isEmpty, "host tool executor must not run when startup commit is unknown")
        #expect(await session.history == priorHistory, "unconfirmed host call request must not mutate session.history")
        #expect(!String(describing: await session.history).contains("unconfirmed host call request"))

        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            excerptCallID: ToolCallID(rawValue: "unused-call")
        )
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let diskHistory = try #require(try await reopened.latestCheckpoint(sessionID: session.id)?.history)
        #expect(diskHistory.count == priorHistory.count + 1)
        #expect(Array(diskHistory.prefix(priorHistory.count)) == priorHistory)

        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        #expect(try await fresh.conversationSnapshot().messages == diskHistory)
        let continued = try await fresh.run("after host reopen")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        #expect(await provider.lastRequest?.messages == diskHistory + [.user([.text("after host reopen")])])
        try await reopened.close()
    }

    @Test func midRunCheckpointCommitUnknownLocksAllSessionAPIsUntilReopened() async throws {
        let directory = tempDir("midrun-checkpoint")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = FileCommitFaultController()
        let journal = try makeFullJournal(at: directory, domain: "midrun-checkpoint", fault: { try fault.check($0) })

        let addTool = try AddTool(log: EffectLog())
        let provider = SessionLockFixtureProvider { request, turn in
            if turn == 1 {
                fault.arm(.afterCurrentReplace)
                return textResponse(request, "uncertain final answer")
            }
            return textResponse(request, "reopened answer")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindAddCapability(session: session, tool: addTool)

        let run = try await session.run("ask")
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await run.wait() }
        try await run.waitForDrain()

        #expect(fault.firedCount(.afterCurrentReplace) == 1)
        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            excerptCallID: ToolCallID(rawValue: "unused-call")
        )
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let expectedDurable: [ModelMessage] = [
            .user([.text("ask")]),
            .assistant(content: [.text("uncertain final answer")], toolCalls: []),
        ]
        #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.history == expectedDurable)
        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        let continued = try await fresh.run("next")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        #expect(await provider.lastRequest?.messages == expectedDurable + [.user([.text("next")])])
        try await reopened.close()
    }

    @Test func midRunRunTerminalCommitUnknownLocksAllSessionAPIsUntilReopened() async throws {
        let directory = tempDir("midrun-terminal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = TerminalPublishFaultController()
        let journal = try makeFullJournal(at: directory, domain: "midrun-terminal", fault: { try fault.check($0) })

        let addTool = try AddTool(log: EffectLog())
        let provider = SessionLockFixtureProvider { request, _ in textResponse(request, "done") }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindAddCapability(session: session, tool: addTool)

        let run = try await session.run("finish run")
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await run.wait() }
        try await run.waitForDrain()

        #expect(fault.fired)
        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            excerptCallID: ToolCallID(rawValue: "unused-call")
        )
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        guard case .terminal(_, .completed) = try await reopened.runRecord(sessionID: session.id, runID: run.id) else {
            Issue.record("expected committed terminal run record after post-replace fault")
            try await reopened.close()
            return
        }
        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        let continued = try await fresh.run("after terminal reopen")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        try await reopened.close()
    }

    @Test func midRunMutationSettlementCommitUnknownLocksAllSessionAPIsUntilReopened() async throws {
        let directory = tempDir("midrun-mutation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = FileCommitFaultController()
        let journal = try makeFullJournal(at: directory, domain: "midrun-mutation", fault: { try fault.check($0) })

        let probe = SessionLockMutationProbe()
        let mutationTool = try SessionLockMutationTool(probe: probe) {
            fault.arm(.afterCurrentReplace)
        }
        let addTool = try AddTool(log: EffectLog())
        let call = ToolCall(
            id: .init(rawValue: "lock-mutate-1"),
            name: SessionLockMutationTool.name,
            argumentsJSON: #"{"id":"resource-1"}"#,
            completeness: .complete
        )
        let provider = SessionLockFixtureProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "after reopen")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding, tools: [mutationTool])
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindAddCapability(session: session, tool: addTool)

        let run = try await session.run("mutate resource", operationID: "lock-mutate-op")
        do {
            _ = try await run.wait()
            Issue.record("expected commitUnknown or AgentMutationPersistenceError")
        } catch let error as AgentJournalError {
            #expect(error == .commitUnknown)
        } catch let error as AgentMutationPersistenceError {
            #expect(error.settlement == .journal(.commitUnknown))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        try await run.waitForDrain()

        #expect(fault.firedCount(.afterCurrentReplace) == 1)
        #expect(await probe.executions == 1)
        #expect(await provider.requestCount == 1)
        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            excerptCallID: call.id
        )
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.pendingMutations().isEmpty)
        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        let diskHistory = try await fresh.conversationSnapshot().messages
        let continued = try await fresh.run("after mutation reopen")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        #expect(await probe.executions == 1, "settled mutation must not re-execute after reopen")
        #expect(await provider.lastRequest?.messages == diskHistory + [.user([.text("after mutation reopen")])])
        try await reopened.close()
    }

    @Test func midRunExecutorNoEffectCommitUnknownLocksAllSessionAPIsUntilReopened() async throws {
        let directory = tempDir("midrun-no-effect")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = FileCommitFaultController()
        let journal = try makeFullJournal(at: directory, domain: "midrun-no-effect", fault: { try fault.check($0) })

        let counts = NoEffectCounts()
        let effectFile = directory.appendingPathComponent("effect.txt")
        let noEffectTool = try NoEffectFileTool(
            file: effectFile,
            counts: counts,
            mode: "conflict",
            beforeReturn: { fault.arm(.afterCurrentReplace) }
        )
        let addTool = try AddTool(log: EffectLog())
        let call = noEffectCall("no-effect-1")
        let provider = SessionLockFixtureProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "after reopen")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding, tools: [noEffectTool])
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindAddCapability(session: session, tool: addTool)

        let run = try await session.run("write conflict", operationID: "no-effect-lock-op")
        do {
            _ = try await run.wait()
            Issue.record("expected commitUnknown or AgentMutationPersistenceError")
        } catch let error as AgentJournalError {
            #expect(error == .commitUnknown)
        } catch let error as AgentMutationPersistenceError {
            #expect(error.settlement == .journal(.commitUnknown))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        try await run.waitForDrain()

        #expect(fault.firedCount(.afterCurrentReplace) == 1)
        #expect(await counts.executions == 1)
        #expect(await counts.effects == 0)
        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            excerptCallID: call.id
        )
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: call.id) != nil)
        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        let continued = try await fresh.run("after no-effect reopen")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func followUpEnqueueAndWithdrawCommitUnknownLockAllSessionAPIs(withdraw: Bool) async throws {
        let directory = tempDir("follow-up-\(withdraw ? "withdraw" : "enqueue")")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = FileCommitFaultController()
        let journal = try makeFullJournal(at: directory, domain: "follow-up-lock", fault: { try fault.check($0) })

        let addTool = try AddTool(log: EffectLog())
        let provider = SessionLockFixtureProvider { request, _ in textResponse(request, "ok") }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindAddCapability(session: session, tool: addTool)

        if withdraw {
            _ = try await session.enqueueFollowUp(.init(
                inputID: "queued-1",
                text: "queued item",
                operationID: "op-queued-1",
                configurationRef: "cfg-1"
            ))
            fault.arm(.afterCurrentReplace)
            await #expect(throws: AgentJournalError.commitUnknown) {
                _ = try await session.withdrawFollowUp(inputID: "queued-1")
            }
        } else {
            fault.arm(.afterCurrentReplace)
            await #expect(throws: AgentJournalError.commitUnknown) {
                _ = try await session.enqueueFollowUp(.init(
                    inputID: "queued-1",
                    text: "queued item",
                    operationID: "op-queued-1",
                    configurationRef: "cfg-1"
                ))
            }
        }

        #expect(fault.firedCount(.afterCurrentReplace) == 1)
        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            excerptCallID: ToolCallID(rawValue: "unused-call")
        )
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        #expect(try await fresh.followUp(inputID: "queued-1")?.state == (withdraw ? .withdrawn : .queued))
        let continued = try await fresh.run("after follow-up reopen")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        try await reopened.close()
    }

    @Test func standaloneCompactionCommitUnknownLocksAllSessionAPIs() async throws {
        let directory = tempDir("compaction-lock")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = FileCommitFaultController()
        let journal = try makeFullJournal(at: directory, domain: "compaction-lock", fault: { try fault.check($0) })

        let addTool = try AddTool(log: EffectLog())
        let provider = SessionLockFixtureProvider { request, _ in textResponse(request, "reply") }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindAddCapability(session: session, tool: addTool)

        let first = try await session.run("seed before compact")
        _ = try await first.wait()
        try await first.waitForDrain()

        fault.arm(.afterCurrentReplace)
        let compaction = try await session.compact(mode: .openAIStandalone)
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await compaction.wait() }
        try await compaction.waitForDrain()

        #expect(fault.firedCount(.afterCurrentReplace) == 1)
        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            excerptCallID: ToolCallID(rawValue: "unused-call")
        )
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.nativeContextCheckpoint(sessionID: session.id) != nil)
        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        let continued = try await fresh.run("after compaction reopen")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        try await reopened.close()
    }

    // MARK: - Assertions & Fixtures

    private func assertSessionLockedInCommitUnknown(
        _ session: AgentSession,
        binding: AgentModelBinding,
        capabilities: AgentCapabilityBinding,
        excerptCallID: ToolCallID
    ) async throws {
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.conversationSnapshot()
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.run("blocked after commitUnknown")
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.invokeHostTool(
                AgentHostToolCall(name: AddTool.name, argumentsJSON: #"{"lhs":1,"rhs":1}"#),
                capabilities: capabilities,
                operationID: "blocked-host"
            )
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.contextHistorySpan(start: 0, count: 1)
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.contextToolExcerpt(callID: excerptCallID, text: "blocked excerpt")
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.compactionBoundaries()
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.handoffToOrdinary(
                using: binding,
                discardingRetiredProviderContinuations: true
            )
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.compact(mode: .openAIStandalone)
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.enqueueFollowUp(.init(
                inputID: "blocked-follow-up",
                text: "blocked",
                operationID: "op-blocked-follow-up",
                configurationRef: "cfg-1"
            ))
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.withdrawFollowUp(inputID: "blocked-follow-up")
        }
    }

    private static func makeBinding(provider: SessionLockFixtureProvider) throws -> AgentModelBinding {
        try AgentModelBinding(
            profileID: "session-lock-fixture",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: .init(
                serviceInstanceID: "session-lock-deployment",
                endpointScope: "fixture://session-lock",
                apiDialect: "fixture"
            )
        )
    }

    private static func bindAddCapability(
        session: AgentSession,
        tool: AddTool
    ) async throws -> AgentCapabilityBinding {
        try await session.bindCapabilities(
            identity: "session-lock-host",
            version: "1",
            backendInstanceID: "fixture",
            backendVersion: "1",
            allowedResources: [.global],
            tools: [AgentCapabilityTool(id: "add", version: "1", tool: tool)]
        )
    }
}

private final class FileCommitFaultController: @unchecked Sendable {
    private let lock = NSLock()
    private var armedStages: Set<JournalFileFaultStage> = []
    private var firedCounts: [JournalFileFaultStage: Int] = [:]

    func arm(_ stage: JournalFileFaultStage) {
        lock.withLock { _ = armedStages.insert(stage) }
    }

    func firedCount(_ stage: JournalFileFaultStage) -> Int {
        lock.withLock { firedCounts[stage, default: 0] }
    }

    func check(_ stage: JournalFileFaultStage) throws {
        let shouldThrow = lock.withLock { () -> Bool in
            guard armedStages.remove(stage) != nil else { return false }
            firedCounts[stage, default: 0] += 1
            return true
        }
        if shouldThrow {
            throw AgentJournalError.persistenceUnavailable("injected \(stage)")
        }
    }
}

private final class TerminalPublishFaultController: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var didFire = false

    var fired: Bool { lock.withLock { didFire } }

    func check(_ stage: JournalFileFaultStage) throws {
        let shouldThrow = lock.withLock { () -> Bool in
            if stage == .beforeRunTerminalPublish {
                armed = true
                return false
            }
            guard armed, !didFire, stage == .afterCurrentReplace else { return false }
            didFire = true
            return true
        }
        if shouldThrow {
            throw AgentJournalError.persistenceUnavailable("injected terminal publish fault")
        }
    }
}

private actor SessionLockFixtureProvider: ModelProviderCompaction {
    nonisolated let descriptor = ModelProviderDescriptor(
        id: "fixture",
        capabilities: [.streaming, .multiTurn, .tools]
    )
    nonisolated let compactionModes: Set<ModelCompactionMode> = [.openAIStandalone]
    nonisolated let automaticCompaction: ModelAutomaticCompaction? = nil
    private let respond: @Sendable (ModelRequest, Int) async throws -> [ModelEvent]
    private var recordedRequests: [ModelRequest] = []

    init(respond: @escaping @Sendable (ModelRequest, Int) async throws -> [ModelEvent]) {
        self.respond = respond
    }

    var requestCount: Int { recordedRequests.count }
    var lastRequest: ModelRequest? { recordedRequests.last }

    private func record(_ request: ModelRequest) -> Int {
        recordedRequests.append(request)
        return recordedRequests.count
    }

    nonisolated func validateCompaction(request: ModelCompactionRequest) throws {}

    nonisolated func compact(request: ModelCompactionRequest) -> AsyncThrowingStream<ModelCompactionEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let info = ResponseInfo(id: "compact", model: request.request.model)
                let transition = ModelNativeContextTransition(
                    mode: request.mode,
                    source: request.request.nativeContextSource!,
                    replayPosition: 0,
                    invocationID: request.invocationID,
                    responseID: info.id
                )
                let state = ModelProviderContinuation(
                    model: info.model,
                    format: "fixture-native",
                    payload: Data("opaque".utf8),
                    contextTransition: transition
                )
                continuation.yield(.completed(.init(info: info, continuation: state, usage: .init(inputTokens: 4, outputTokens: 1))))
                continuation.finish()
            }
        }
    }

    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let turn = await self.record(request)
            for event in try await self.respond(request, turn) {
                try emit(event)
            }
        }
    }
}

private actor SessionLockMutationProbe {
    private(set) var executions = 0
    func recordExecution() { executions += 1 }
}

private struct SessionLockMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = "session_lock_mutate"
    static let description = "Mutation fixture tool"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let probe: SessionLockMutationProbe
    let beforeReturn: @Sendable () -> Void
    let policy: ToolPolicy

    init(probe: SessionLockMutationProbe, beforeReturn: @escaping @Sendable () -> Void) throws {
        self.probe = probe
        self.beforeReturn = beforeReturn
        self.policy = try .mutation(authorization: .notRequired, evidence: .none)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "session.lock", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "session.lock", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.recordExecution()
        beforeReturn()
        return ToolResult(
            output: Output(updated: true),
            receipt: ToolReceipt(
                operationID: context.idempotencyKey ?? "",
                status: .succeeded,
                confirmedTargets: [.init(namespace: "session.lock", id: input.id)],
                revision: "rev-1"
            )
        )
    }
}
