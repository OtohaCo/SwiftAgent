@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

@Suite(.manualClock) struct AbandonedRunClosureTests {
    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("abandoned-run-closure-\(label)-\(UUID())")
    }

    private func makeFullJournal(
        at directory: URL,
        domain: String,
        fault: (@Sendable (JournalFileFaultStage) throws -> Void)? = nil
    ) throws -> AgentJournal {
        if let fault {
            return try AgentIncrementalJournal.createForTesting(
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
        return try AgentIncrementalJournal.createForIncompleteContextHandoff(
            at: directory,
            operationDomain: domain
        )
    }

    @Test func nonDurableAndUnsupportedJournalsRejectLatestRunRecordAndClosure() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "ok") }
        let agent = try Agent(model: fixtureModel, provider: provider)

        let unjournaled = try agent.makeSession()
        let unjournaledRun = try await unjournaled.run("hello")
        _ = try await unjournaledRun.wait()
        try await unjournaledRun.waitForDrain()
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try await unjournaled.latestRunRecord()
        }
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try await unjournaled.closeAbandonedRun(runID: unjournaledRun.id)
        }

        let memoryJournal = AgentJournal()
        let memorySession = try agent.makeSession(journal: memoryJournal)
        let memoryRun = try await memorySession.run("hello")
        _ = try await memoryRun.wait()
        try await memoryRun.waitForDrain()
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try await memoryJournal.latestRunRecord(sessionID: memorySession.id)
        }
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try await memorySession.latestRunRecord()
        }
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try await memorySession.closeAbandonedRun(runID: memoryRun.id)
        }

        let directory = tempDir("no-run-records")
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyJournal = try AgentIncrementalJournal.create(
            at: directory,
            operationDomain: "no-run-records"
        )
        let legacySession = try agent.makeSession(journal: legacyJournal)
        let legacyRun = try await legacySession.run("hello")
        _ = try await legacyRun.wait()
        try await legacyRun.waitForDrain()
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try await legacyJournal.latestRunRecord(sessionID: legacySession.id)
        }
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try await legacySession.latestRunRecord()
        }
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try await legacySession.closeAbandonedRun(runID: legacyRun.id)
        }
        try await legacyJournal.close()
    }

    @Test func activeStartingAndPhysicallyDrainingRunsRefuseClosureWithRunInProgress() async throws {
        // Subcase A & B: active run, then cancelled but physically draining run with no persisted terminal.
        let directory = tempDir("active-and-draining")
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminalFault = TerminalStageFault()
        let journal = try makeFullJournal(
            at: directory,
            domain: "active-draining",
            fault: { try terminalFault.check($0) }
        )
        let gate = ClosureGate()
        let provider = ClosureDrainingProvider(gate: gate)
        let binding = try makeClosureBinding(provider: provider, profile: "drain-profile")
        let agent = try Agent(binding: binding)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let peer = try agent.makeSession(id: sessionID, journal: journal)

        let run = try await session.run("hold open")
        await gate.waitEntered()

        // While active, latestRunRecord is .admitted and closure is refused on both sessions.
        guard case .admitted(let activeRecord) = try await session.latestRunRecord() else {
            Issue.record("expected active run to appear as .admitted")
            await gate.release()
            try await run.waitForDrain()
            try await journal.close()
            return
        }
        #expect(activeRecord.runID == run.id)
        await #expect(throws: AgentSessionError.runInProgress) {
            _ = try await session.closeAbandonedRun(runID: run.id)
        }
        await #expect(throws: AgentSessionError.runInProgress) {
            _ = try await peer.closeAbandonedRun(runID: run.id)
        }

        // Fail terminal publication on cancel so the run remains .admitted while physically draining.
        terminalFault.armOnce()
        await run.cancel()
        await #expect(throws: (any Error).self) {
            _ = try await run.wait()
        }
        #expect(try await journal.latestRunRecord(sessionID: sessionID) == .admitted(activeRecord))
        await #expect(throws: AgentSessionError.runInProgress) {
            _ = try await session.closeAbandonedRun(runID: run.id)
        }
        await #expect(throws: AgentSessionError.runInProgress) {
            _ = try await peer.closeAbandonedRun(runID: run.id)
        }

        await gate.release()
        try await run.waitForDrain()

        // Once physically drained, closure succeeds on the abandoned run.
        let closed = try await session.closeAbandonedRun(runID: run.id)
        #expect(closed == .incomplete(.other))
        #expect(try await session.latestRunRecord() == .terminal(activeRecord, .incomplete(.other)))
        try await journal.close()

        // Subcase C: starting run (before startup commit finishes) blocks closure on an earlier abandoned run.
        let startDirectory = tempDir("starting-run")
        defer { try? FileManager.default.removeItem(at: startDirectory) }
        let startFault = TerminalStageFault()
        let startJournal = try makeFullJournal(
            at: startDirectory,
            domain: "starting-run",
            fault: { try startFault.check($0) }
        )
        let simpleProvider = ScriptedProvider { request, _ in textResponse(request, "reply") }
        let startAgent = try Agent(model: fixtureModel, provider: simpleProvider)
        let startSessionID = UUID()
        let seedSession = try startAgent.makeSession(id: startSessionID, journal: startJournal)
        startFault.armOnce()
        let abandoned = try await seedSession.run("first")
        await #expect(throws: AgentJournalError.persistenceUnavailable("terminal fault")) {
            _ = try await abandoned.wait()
        }
        try await abandoned.waitForDrain()
        guard case .admitted(let abandonedRecord) = try await startJournal.latestRunRecord(sessionID: startSessionID) else {
            Issue.record("expected abandoned .admitted run before starting next run")
            try await startJournal.close()
            return
        }

        let startGate = ClosureGate()
        let startingSession = try startAgent.makeSession(
            id: startSessionID,
            journal: startJournal,
            startupCommitWillBegin: { _ in await startGate.pause() }
        )
        let peerDuringStart = try startAgent.makeSession(id: startSessionID, journal: startJournal)
        let startTask = Task { try await startingSession.run("second") }
        await startGate.waitEntered()

        await #expect(throws: AgentSessionError.runInProgress) {
            _ = try await startingSession.closeAbandonedRun(runID: abandonedRecord.runID)
        }
        await #expect(throws: AgentSessionError.runInProgress) {
            _ = try await peerDuringStart.closeAbandonedRun(runID: abandonedRecord.runID)
        }

        await startGate.release()
        let secondRun = try await startTask.value
        _ = try await secondRun.wait()
        try await secondRun.waitForDrain()
        try await startJournal.close()
    }

    @Test(arguments: ["completed", "failed", "cancelled", "incompleteMaxTokens", "alreadyClosed"])
    func existingTerminalsAreNeverOverwrittenAndRejectSecondClosure(_ kind: String) async throws {
        let directory = tempDir("existing-terminal-\(kind)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminalFault = TerminalStageFault()
        let journal = try makeFullJournal(
            at: directory,
            domain: "existing-terminal-\(kind)",
            fault: { try terminalFault.check($0) }
        )
        let gate = ClosureGate()
        let provider = ClosureTerminalVariantProvider(kind: kind, gate: gate)
        let binding = try makeClosureBinding(provider: provider, profile: "terminal-variant")
        let agent = try Agent(binding: binding)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)

        if kind == "alreadyClosed" {
            terminalFault.armOnce()
        }
        let run = try await session.run("run-\(kind)")
        switch kind {
        case "completed":
            #expect(try await run.wait().outcome == .completed)
        case "incompleteMaxTokens":
            #expect(try await run.wait().outcome == .incomplete(.maxOutputTokens))
        case "failed":
            await #expect(throws: ModelProviderError.self) { _ = try await run.wait() }
        case "cancelled":
            await gate.waitEntered()
            await run.cancel()
            await #expect(throws: CancellationError.self) { _ = try await run.wait() }
            await gate.release()
        case "alreadyClosed":
            await #expect(throws: AgentJournalError.persistenceUnavailable("terminal fault")) {
                _ = try await run.wait()
            }
        default:
            Issue.record("unexpected variant \(kind)")
        }
        try await run.waitForDrain()

        if kind == "alreadyClosed" {
            let firstClose = try await session.closeAbandonedRun(runID: run.id)
            #expect(firstClose == .incomplete(.other))
        }

        let expectedTerminal: AgentRunTerminal
        switch kind {
        case "completed": expectedTerminal = .completed
        case "failed": expectedTerminal = .failed(.provider)
        case "cancelled": expectedTerminal = .cancelled
        case "incompleteMaxTokens": expectedTerminal = .incomplete(.maxOutputTokens)
        case "alreadyClosed": expectedTerminal = .incomplete(.other)
        default: fatalError("unexpected variant")
        }

        guard case .terminal(let record, let beforeTerminal) = try await session.latestRunRecord() else {
            Issue.record("expected existing terminal for \(kind)")
            try await journal.close()
            return
        }
        #expect(beforeTerminal == expectedTerminal)

        await #expect(throws: AgentJournalError.invalidRecord) {
            _ = try await session.closeAbandonedRun(runID: run.id)
        }
        #expect(try await session.latestRunRecord() == .terminal(record, expectedTerminal))
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestRunRecord(sessionID: sessionID) == .terminal(record, expectedTerminal))
        let fresh = try agent.makeSession(id: sessionID, journal: reopened)
        await #expect(throws: AgentJournalError.invalidRecord) {
            _ = try await fresh.closeAbandonedRun(runID: run.id)
        }
        #expect(try await reopened.latestRunRecord(sessionID: sessionID) == .terminal(record, expectedTerminal))
        try await reopened.close()
    }

    @Test func wrongOrUnknownRunIDRefusesClosureAndLeavesLatestRunIntact() async throws {
        let directory = tempDir("wrong-run-id")
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminalFault = TerminalStageFault()
        let journal = try makeFullJournal(
            at: directory,
            domain: "wrong-run-id",
            fault: { try terminalFault.check($0) }
        )
        let provider = ScriptedProvider { request, _ in textResponse(request, "ok") }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let session = try agent.makeSession(journal: journal)

        #expect(try await session.latestRunRecord() == .notAdmitted)
        await #expect(throws: AgentJournalError.invalidRecord) {
            _ = try await session.closeAbandonedRun(runID: UUID())
        }

        let run1 = try await session.run("first")
        _ = try await run1.wait()
        try await run1.waitForDrain()
        guard case .terminal(let record1, .completed) = try await session.latestRunRecord() else {
            Issue.record("expected run1 completed")
            try await journal.close()
            return
        }

        terminalFault.armOnce()
        let run2 = try await session.run("second")
        await #expect(throws: AgentJournalError.persistenceUnavailable("terminal fault")) {
            _ = try await run2.wait()
        }
        try await run2.waitForDrain()
        guard case .admitted(let record2) = try await session.latestRunRecord() else {
            Issue.record("expected run2 admitted without terminal")
            try await journal.close()
            return
        }

        await #expect(throws: AgentJournalError.invalidRecord) {
            _ = try await session.closeAbandonedRun(runID: run1.id)
        }
        await #expect(throws: AgentJournalError.invalidRecord) {
            _ = try await session.closeAbandonedRun(runID: UUID())
        }
        #expect(try await journal.runRecord(sessionID: session.id, runID: run1.id) == .terminal(record1, .completed))
        #expect(try await session.latestRunRecord() == .admitted(record2))

        let terminal = try await session.closeAbandonedRun(runID: run2.id)
        #expect(terminal == .incomplete(.other))
        #expect(try await session.latestRunRecord() == .terminal(record2, .incomplete(.other)))
        #expect(try await journal.runRecord(sessionID: session.id, runID: run1.id) == .terminal(record1, .completed))
        try await journal.close()
    }

    @Test func staleSessionWitnessThrowsConcurrentWriterWithoutWritingTerminal() async throws {
        let directory = tempDir("stale-witness")
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminalFault = TerminalStageFault()
        let journal = try makeFullJournal(
            at: directory,
            domain: "stale-witness",
            fault: { try terminalFault.check($0) }
        )
        let provider = ScriptedProvider { _, _ in
            throw ModelProviderError(kind: .transport, message: "controlled failure")
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let sessionID = UUID()
        let initial = try agent.makeSession(id: sessionID, journal: journal)

        terminalFault.armOnce()
        let run = try await initial.run("question")
        await #expect(throws: (any Error).self) { _ = try await run.wait() }
        try await run.waitForDrain()
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        guard case .admitted(let record) = try await reopened.latestRunRecord(sessionID: sessionID) else {
            Issue.record("expected .admitted after reopen")
            try await reopened.close()
            return
        }

        let stale = try agent.makeSession(id: sessionID, journal: reopened)
        let snapshot = try await stale.conversationSnapshot()

        // Mutate the session head externally while keeping lastRunID == run.id and closed tool pairing.
        _ = try await reopened.appendCheckpoint(
            [.checkpoint(history: snapshot.messages + [.user([.text("external append")])], steeringIDs: [])],
            sessionID: sessionID,
            runID: run.id,
            durability: .durable
        )

        await #expect(throws: AgentJournalError.concurrentWriter) {
            _ = try await stale.closeAbandonedRun(runID: run.id)
        }
        #expect(try await reopened.latestRunRecord(sessionID: sessionID) == .admitted(record))

        let fresh = try agent.makeSession(id: sessionID, journal: reopened)
        #expect(try await fresh.closeAbandonedRun(runID: run.id) == .incomplete(.other))
        #expect(try await reopened.latestRunRecord(sessionID: sessionID) == .terminal(record, .incomplete(.other)))
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func unpairedAssistantToolCallsRefuseClosure(_ partialBatch: Bool) async throws {
        let directory = tempDir("unpaired-tool-\(partialBatch ? "partial" : "single")")
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminalFault = TerminalStageFault()
        let journal = try makeFullJournal(
            at: directory,
            domain: "unpaired-tool",
            fault: { try terminalFault.check($0) }
        )
        let provider = ScriptedProvider { _, _ in
            throw ModelProviderError(kind: .transport, message: "controlled failure")
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let sessionID = UUID()
        let initial = try agent.makeSession(id: sessionID, journal: journal)

        terminalFault.armOnce()
        let run = try await initial.run("ask")
        await #expect(throws: (any Error).self) { _ = try await run.wait() }
        try await run.waitForDrain()

        let call1 = ToolCall(id: .init(rawValue: "call-1"), name: "lookup", argumentsJSON: "{}", completeness: .complete)
        let call2 = ToolCall(id: .init(rawValue: "call-2"), name: "lookup", argumentsJSON: "{}", completeness: .complete)
        let unpairedHistory: [ModelMessage]
        if partialBatch {
            unpairedHistory = [
                .user([.text("ask")]),
                .assistant(content: [], toolCalls: [call1, call2]),
                .tool(.init(callID: call1.id, content: [.text("first result")], isError: false)),
            ]
        } else {
            unpairedHistory = [
                .user([.text("ask")]),
                .assistant(content: [], toolCalls: [call1]),
            ]
        }
        _ = try await journal.appendCheckpoint(
            [.checkpoint(history: unpairedHistory, steeringIDs: [])],
            sessionID: sessionID,
            runID: run.id,
            durability: .durable
        )

        guard case .admitted(let record) = try await journal.latestRunRecord(sessionID: sessionID) else {
            Issue.record("expected .admitted record")
            try await journal.close()
            return
        }

        let fresh = try agent.makeSession(id: sessionID, journal: journal)
        await #expect(throws: AgentJournalError.invalidRecord) {
            _ = try await fresh.closeAbandonedRun(runID: run.id)
        }
        #expect(try await journal.latestRunRecord(sessionID: sessionID) == .admitted(record))
        try await journal.close()
    }

    @Test func abandonedRunWithActiveDispatcherRejectsClosureUntilDispatcherDrains() async throws {
        let directory = tempDir("dispatcher-owned")
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminalFault = TerminalStageFault()
        let journal = try makeFullJournal(
            at: directory,
            domain: "dispatcher-owned",
            fault: { try terminalFault.check($0) }
        )
        let provider = ScriptedProvider { _, _ in
            throw ModelProviderError(kind: .transport, message: "controlled failure")
        }
        let binding = try makeClosureBinding(provider: provider, profile: "dispatch-profile")
        let agent = try Agent(binding: binding)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let peer = try agent.makeSession(id: sessionID, journal: journal)

        _ = try await session.enqueueFollowUp(.init(
            inputID: "queued-1",
            text: "queued prompt",
            operationID: "op-1",
            configurationRef: "v1"
        ))
        terminalFault.armOnce()
        let dispatcher = try await session.startFollowUpDispatch(
            policy: .init(runTimeout: .seconds(10)),
            resolver: ClosureQueueResolver(session: session, binding: binding)
        )
        await dispatcher.waitUntilPaused()
        #expect(await dispatcher.status().interruptedInputID == "queued-1")

        guard case .admitted(let record) = try await journal.latestRunRecord(sessionID: sessionID) else {
            Issue.record("expected .admitted follow-up run")
            await dispatcher.stop()
            try await dispatcher.waitForDrain()
            try await journal.close()
            return
        }
        #expect(record.followUpInputID == "queued-1")

        await #expect(throws: AgentFollowUpError.dispatchOwned) {
            _ = try await session.closeAbandonedRun(runID: record.runID)
        }
        await #expect(throws: AgentFollowUpError.dispatchOwned) {
            _ = try await peer.closeAbandonedRun(runID: record.runID)
        }

        await dispatcher.stop()
        try await dispatcher.waitForDrain()

        #expect(try await session.closeAbandonedRun(runID: record.runID) == .incomplete(.other))
        #expect(try await session.latestRunRecord() == .terminal(record, .incomplete(.other)))
        // Follow-up inspection barrier remains intact after closure.
        let dispatcher2 = try await session.startFollowUpDispatch(
            policy: .init(runTimeout: .seconds(10)),
            resolver: ClosureQueueResolver(session: session, binding: binding)
        )
        await dispatcher2.waitUntilPaused()
        #expect(await dispatcher2.status().interruptedInputID == "queued-1")
        await #expect(throws: AgentFollowUpError.needsInspection) {
            try await dispatcher2.resume()
        }
        await dispatcher2.stop()
        try await dispatcher2.waitForDrain()
        try await journal.close()
    }

    @Test func handoffToDifferentOrdinaryBindingAfterClosingAbandonedRunRetiresContinuationAndControls() async throws {
        let directory = tempDir("cross-binding-handoff")
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminalFault = TerminalStageFault()
        let journal = try makeFullJournal(
            at: directory,
            domain: "cross-binding",
            fault: { try terminalFault.check($0) }
        )

        let toolLog = EffectLog()
        let addTool = try AddTool(log: toolLog)
        let providerA = ClosureControlsProvider(terminalFault: terminalFault)
        let bindingA = try AgentModelBinding(
            profileID: "source-profile",
            profileRevision: "1",
            model: ModelID(provider: "source-controls", name: "model-a"),
            provider: providerA,
            deployment: .init(serviceInstanceID: "source-svc", endpointScope: "local", apiDialect: "controls-v1")
        )
        let agentA = try Agent(binding: bindingA, tools: [addTool])
        let sessionID = UUID()
        let sessionA = try agentA.makeSession(id: sessionID, journal: journal)

        // Run 1 completes with a provider continuation and reminder.
        let run1 = try await sessionA.run(
            "turn 1",
            contextControls: try .init(reminder: "keep answers short")
        )
        #expect(try await run1.wait().outcome == .completed)
        try await run1.waitForDrain()

        // Run 2 commits a closed tool round then fails before terminal publication.
        let run2 = try await sessionA.run(
            "turn 2 with tool",
            contextControls: try .init(reminder: "keep answers short")
        )
        await #expect(throws: (any Error).self) { _ = try await run2.wait() }
        try await run2.waitForDrain()
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        guard case .admitted(let record2) = try await reopened.latestRunRecord(sessionID: sessionID) else {
            Issue.record("expected open() to preserve .admitted state")
            try await reopened.close()
            return
        }
        #expect(record2.runID == run2.id)
        let beforeMessages = try await reopened.readMessages(sessionID: sessionID)
        #expect(beforeMessages.map(\.message.role) == [.user, .assistant, .user, .assistant, .tool])
        let controlsBefore = try #require(try await reopened.conversationControlState(sessionID: sessionID))
        #expect(controlsBefore.entries.count >= 3)

        let providerB = ScriptedProvider { request, _ in textResponse(request, "ordinary reply") }
        let bindingB = try AgentModelBinding(
            profileID: "ordinary-target",
            profileRevision: "1",
            model: ModelID(provider: "fixture", name: "model-b"),
            provider: providerB,
            deployment: .init(serviceInstanceID: "target-svc", endpointScope: "local", apiDialect: "ordinary-v1")
        )
        let agentB = try Agent(binding: bindingB, tools: [addTool])
        let fresh = try agentB.makeSession(id: sessionID, journal: reopened)

        let closed = try await fresh.closeAbandonedRun(runID: run2.id)
        #expect(closed == .incomplete(.other))
        #expect(try await reopened.readMessages(sessionID: sessionID) == beforeMessages)

        let op = try await fresh.handoffToOrdinary(
            using: bindingB,
            discardingRetiredProviderContinuations: true,
            allowingIncompleteTurn: true
        )
        let handoff = try await op.wait()
        try await op.waitForDrain()
        #expect(handoff.completedRunID == nil)
        #expect(handoff.closedTurnProof?.runID == run2.id)
        #expect(handoff.closedTurnProof?.terminal == .incomplete(.other))
        #expect(handoff.closedTurnProof?.formalMessageID == record2.formalMessageID)
        #expect(try await reopened.conversationControlState(sessionID: sessionID) == nil)
        #expect(try await reopened.readMessages(sessionID: sessionID) == beforeMessages)
        try await reopened.close()

        let reopened2 = try AgentIncrementalJournal.open(at: directory)
        let storedHandoff = try #require(try await reopened2.contextHandoff(sessionID: sessionID))
        #expect(storedHandoff == handoff)
        try await reopened2.validateStoredHandoff(storedHandoff, sessionID: sessionID)
        #expect(try await reopened2.readMessages(sessionID: sessionID) == beforeMessages)
        #expect(try await reopened2.latestRunRecord(sessionID: sessionID) == .terminal(record2, .incomplete(.other)))

        let resumed = try agentB.makeSession(id: sessionID, journal: reopened2)
        let run3 = try await resumed.run("continue on ordinary target")
        #expect(try await run3.wait().outcome == .completed)
        try await run3.waitForDrain()

        let sentToB = try #require(await providerB.log.requests.first)
        // Ordinary target receives all prior turns and tool round with retired provider continuation omitted.
        #expect(sentToB.messages.map(\.role) == [.user, .assistant, .user, .assistant, .tool, .user])
        let hasRetiredContinuation = sentToB.messages.contains { message in
            if case .assistant(let parts, _) = message {
                return parts.contains { if case .providerContinuation = $0 { true } else { false } }
            }
            return false
        }
        #expect(!hasRetiredContinuation)
        // Archival canonical messages on disk still retain exact original messages and IDs.
        let finalMessages = try await reopened2.readMessages(sessionID: sessionID)
        #expect(Array(finalMessages.prefix(beforeMessages.count)) == beforeMessages)
        try await reopened2.close()
    }
}

private func makeClosureBinding(
    provider: any ModelProvider,
    profile: String
) throws -> AgentModelBinding {
    try AgentModelBinding(
        profileID: profile,
        profileRevision: "1",
        model: ModelID(provider: provider.descriptor.id, name: "model"),
        provider: provider,
        deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")
    )
}

private final class TerminalStageFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    func armOnce() {
        lock.withLock { armed = true }
    }

    func check(_ stage: JournalFileFaultStage) throws {
        guard stage == .beforeRunTerminalPublish else { return }
        let shouldFail = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false
            return true
        }
        if shouldFail {
            throw AgentJournalError.persistenceUnavailable("terminal fault")
        }
    }
}

private actor ClosureGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        let observers = entryWaiters
        entryWaiters.removeAll()
        observers.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { pauseWaiters.append($0) }
        }
    }

    func waitEntered() async {
        if !entered {
            await withCheckedContinuation { entryWaiters.append($0) }
        }
    }

    func release() {
        released = true
        let paused = pauseWaiters
        pauseWaiters.removeAll()
        paused.forEach { $0.resume() }
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitReleased() async {
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }
}

private actor ClosureDrainingProvider: ModelProviderConversationControls, ModelProviderRunDrain {
    nonisolated let descriptor = ModelProviderDescriptor(id: "closure-drain", capabilities: [.streaming, .multiTurn])
    nonisolated let conversationControlCapabilities: ModelConversationControlCapabilities? = .init(inlineTools: true, reminders: true)
    nonisolated let gate: ClosureGate

    init(gate: ClosureGate) {
        self.gate = gate
    }

    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: UUID().uuidString, model: request.model)
            try emit(.responseStarted(info))
            await self.gate.pause()
            try emit(.textDelta("done"))
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
        }
    }

    func waitForRunToDrain(sessionID: UUID, runID: UUID) async {
        await gate.waitReleased()
    }
}

private actor ClosureTerminalVariantProvider: ModelProvider, ModelProviderRunDrain {
    nonisolated let descriptor = ModelProviderDescriptor(id: "closure-variant", capabilities: [.streaming, .multiTurn])
    nonisolated let kind: String
    nonisolated let gate: ClosureGate

    init(kind: String, gate: ClosureGate) {
        self.kind = kind
        self.gate = gate
    }

    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: UUID().uuidString, model: request.model)
            switch self.kind {
            case "failed":
                throw ModelProviderError(kind: .transport, message: "controlled failure")
            case "cancelled":
                try emit(.responseStarted(info))
                await self.gate.pause()
                try emit(.textDelta("late"))
                try emit(.responseCompleted(.init(info: info, content: [.text("late")], stopReason: .endTurn)))
            case "incompleteMaxTokens":
                try emit(.responseStarted(info))
                try emit(.textDelta("partial"))
                try emit(.responseCompleted(.init(info: info, content: [.text("partial")], stopReason: .maxOutputTokens)))
            default:
                try emit(.responseStarted(info))
                try emit(.textDelta("done"))
                try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
            }
        }
    }

    func waitForRunToDrain(sessionID: UUID, runID: UUID) async {
        if kind == "cancelled" {
            await gate.waitReleased()
        }
    }
}

private actor ClosureControlsProvider: ModelProviderConversationControls {
    nonisolated let descriptor = ModelProviderDescriptor(
        id: "source-controls",
        capabilities: [.streaming, .multiTurn, .tools]
    )
    nonisolated let conversationControlCapabilities: ModelConversationControlCapabilities? = .init(
        inlineTools: true,
        reminders: true
    )
    nonisolated let terminalFault: TerminalStageFault
    private var turnCount = 0

    init(terminalFault: TerminalStageFault) {
        self.terminalFault = terminalFault
    }

    private func nextTurn() -> Int {
        turnCount += 1
        return turnCount
    }

    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let turn = await self.nextTurn()
            let info = ResponseInfo(id: "controls-\(turn)", model: request.model)
            if turn == 1 {
                let continuation = ModelProviderContinuation(
                    model: request.model,
                    format: "controls.continuation.v1",
                    payload: Data(#"{"opaque":"turn-1"}"#.utf8)
                )
                try emit(.responseStarted(info))
                try emit(.providerContinuation(continuation))
                try emit(.textDelta("first answer"))
                try emit(.responseCompleted(.init(
                    info: info,
                    content: [.providerContinuation(continuation), .text("first answer")],
                    stopReason: .endTurn
                )))
                return
            }
            if turn == 2 {
                let call = ToolCall(
                    id: .init(rawValue: "add-step-1"),
                    name: AddTool.name,
                    argumentsJSON: #"{"lhs":2,"rhs":5}"#,
                    completeness: .complete
                )
                for event in toolResponse(request, [call]) {
                    try emit(event)
                }
                return
            }
            // Tool round 1 and updated reminder controls are already committed; fail before terminal publish.
            self.terminalFault.armOnce()
            throw ModelProviderError(kind: .transport, message: "interrupted after tool round")
        }
    }
}

private struct ClosureQueueResolver: AgentFollowUpResolver {
    let session: AgentSession
    let binding: AgentModelBinding

    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        let capabilities = try await session.bindCapabilities(
            identity: "closure-queue",
            version: "1",
            backendInstanceID: "fixture",
            backendVersion: "1",
            allowedResources: [],
            tools: []
        )
        return .init(model: binding, capabilities: capabilities, expectedConversationRevision: nil)
    }
}
