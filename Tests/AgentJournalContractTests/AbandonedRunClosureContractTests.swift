@testable import AgentCore
@testable import AgentJournalSQLiteStore
import AgentModels
import AgentTools
import Foundation
import Testing
#if canImport(SQLite3)
import SQLite3
#else
import CAgentSQLite
#endif

@Suite struct AbandonedRunClosureContractTests {
    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-contract-abandoned-\(label)-\(UUID())")
    }

    private static var fullCapabilities: JournalContractCapabilities {
        .init(
            supportsConfirmedNoEffect: true,
            supportsPerCallFollowUps: true,
            supportsRunRecords: true,
            supportsNativeContext: true,
            supportsContextHandoff: true,
            supportsIncompleteContextHandoff: true
        )
    }

    private static func makeBinding(
        provider: any ModelProvider,
        profile: String = "abandoned-contract"
    ) throws -> AgentModelBinding {
        try AgentModelBinding(
            profileID: profile,
            profileRevision: "1",
            model: ModelID(provider: provider.descriptor.id, name: "model"),
            provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")
        )
    }

    private static func textEvents(_ request: ModelRequest, _ text: String) -> [ModelEvent] {
        let info = ResponseInfo(id: UUID().uuidString, model: request.model)
        return [
            .responseStarted(info),
            .textDelta(text),
            .responseCompleted(.init(info: info, content: [.text(text)], stopReason: .endTurn)),
        ]
    }

    private static func toolEvents(_ request: ModelRequest, _ calls: [ToolCall]) -> [ModelEvent] {
        let info = ResponseInfo(id: UUID().uuidString, model: request.model)
        var events: [ModelEvent] = [.responseStarted(info)]
        for call in calls {
            events.append(.toolCallStarted(call.id, name: call.name))
            events.append(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
            events.append(.toolCallCompleted(call))
        }
        events.append(.responseCompleted(.init(info: info, toolCalls: calls, stopReason: .toolCalls)))
        return events
    }

    @Test(arguments: JournalContractBackends.all)
    func latestRunRecordReflectsLifecycleAndOpenStaysReadOnly(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("lifecycle-\(backend.name)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = ContractCommitFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "abandoned-lifecycle",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )

        let gate = ContractAsyncGate()
        let provider = ContractControlsProvider { request, turn in
            if turn == 1 {
                return Self.textEvents(request, "first answer")
            }
            await gate.pause()
            fault.blockAll(.beforeCommit)
            throw ModelProviderError(kind: .transport, message: "crash before terminal")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)

        // Before any run: .notAdmitted.
        #expect(try await journal.latestRunRecord(sessionID: sessionID) == .notAdmitted)
        #expect(try await session.latestRunRecord() == .notAdmitted)

        // Completed run 1: .terminal(record1, .completed).
        let run1 = try await session.run("first prompt")
        #expect(try await run1.wait().outcome == .completed)
        try await run1.waitForDrain()
        guard case .terminal(let record1, .completed) = try await journal.latestRunRecord(sessionID: sessionID) else {
            Issue.record("expected run1 terminal")
            try await journal.close()
            return
        }
        #expect(record1.runID == run1.id)
        #expect(try await session.latestRunRecord() == .terminal(record1, .completed))

        // Active run 2: .admitted(record2) while running.
        let run2 = try await session.run("second prompt")
        await gate.waitEntered()
        guard case .admitted(let record2) = try await journal.latestRunRecord(sessionID: sessionID) else {
            Issue.record("expected active run2 as .admitted")
            await gate.release()
            _ = try? await run2.wait()
            try? await run2.waitForDrain()
            try await journal.close()
            return
        }
        #expect(record2.runID == run2.id)
        #expect(try await session.latestRunRecord() == .admitted(record2))

        // Fail before terminal commit, drain, and close.
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await run2.wait() }
        try await run2.waitForDrain()
        try await journal.close()

        // Reopening must stay read-only and never auto-write a terminal.
        let reopened = try backend.open(at: directory)
        #expect(try await reopened.latestRunRecord(sessionID: sessionID) == .admitted(record2))
        #expect(try await reopened.runRecord(sessionID: sessionID, runID: run2.id) == .admitted(record2))
        let fresh = try agent.makeSession(id: sessionID, journal: reopened)
        #expect(try await fresh.latestRunRecord() == .admitted(record2))

        // Explicit closure records .incomplete(.other) and persists across reopen.
        let closed = try await fresh.closeAbandonedRun(runID: run2.id)
        #expect(closed == .incomplete(.other))
        #expect(try await reopened.latestRunRecord(sessionID: sessionID) == .terminal(record2, .incomplete(.other)))
        #expect(try await fresh.latestRunRecord() == .terminal(record2, .incomplete(.other)))
        try await reopened.close()

        let reopened2 = try backend.open(at: directory)
        #expect(try await reopened2.latestRunRecord(sessionID: sessionID) == .terminal(record2, .incomplete(.other)))
        #expect(try await reopened2.runRecord(sessionID: sessionID, runID: run1.id) == .terminal(record1, .completed))
        try await reopened2.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func userTailAbandonedRunClosesHandsOffAndContinuesAcrossReopen(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("user-tail-\(backend.name)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = ContractCommitFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "user-tail-closure",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )

        let provider = ContractControlsProvider { request, turn in
            if turn == 1 {
                return Self.textEvents(request, "answer 1")
            }
            if turn == 2 {
                fault.blockAll(.beforeCommit)
                throw ModelProviderError(kind: .transport, message: "interrupted before answer 2")
            }
            return Self.textEvents(request, "answer 3")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)

        let run1 = try await session.run("user 1", contextControls: try .init(reminder: "reply briefly"))
        #expect(try await run1.wait().outcome == .completed)
        try await run1.waitForDrain()

        let run2 = try await session.run("user 2", contextControls: try .init(reminder: "reply briefly"))
        await #expect(throws: (any Error).self) { _ = try await run2.wait() }
        try await run2.waitForDrain()
        try await journal.close()

        let reopened = try backend.open(at: directory)
        guard case .admitted(let record2) = try await reopened.latestRunRecord(sessionID: sessionID) else {
            Issue.record("expected .admitted run2 after reopen")
            try await reopened.close()
            return
        }
        #expect(record2.runID == run2.id)

        let beforeMessages = try await reopened.readMessages(sessionID: sessionID)
        #expect(beforeMessages.map(\.message.role) == [.user, .assistant, .user])
        let beforeControls = try #require(try await reopened.conversationControlState(sessionID: sessionID))
        #expect(beforeControls.entries.count == 2)

        let fresh = try agent.makeSession(id: sessionID, journal: reopened)

        // Incomplete handoff refuses before the abandoned run is closed.
        let unclosedHandoff = try await fresh.handoffToOrdinary(
            using: binding,
            discardingRetiredProviderContinuations: true,
            allowingIncompleteTurn: true
        )
        await #expect(throws: (any Error).self) { _ = try await unclosedHandoff.wait() }
        try await unclosedHandoff.waitForDrain()
        #expect(try await reopened.contextHandoff(sessionID: sessionID) == nil)

        // Close the abandoned run explicitly.
        let closedTerminal = try await fresh.closeAbandonedRun(runID: run2.id)
        #expect(closedTerminal == .incomplete(.other))
        #expect(try await reopened.readMessages(sessionID: sessionID) == beforeMessages)
        #expect(try await reopened.readMessages(sessionID: sessionID).map(\.id) == beforeMessages.map(\.id))

        // Ordinary handoff without allowingIncompleteTurn still refuses.
        let withoutConsent = try await fresh.handoffToOrdinary(
            using: binding,
            discardingRetiredProviderContinuations: true
        )
        await #expect(throws: ModelProviderError.self) { _ = try await withoutConsent.wait() }
        try await withoutConsent.waitForDrain()

        // Incomplete handoff now succeeds and retires dangling controls cleanly.
        let handoffOp = try await fresh.handoffToOrdinary(
            using: binding,
            discardingRetiredProviderContinuations: true,
            allowingIncompleteTurn: true
        )
        let handoff = try await handoffOp.wait()
        try await handoffOp.waitForDrain()
        #expect(handoff.completedRunID == nil)
        #expect(handoff.closedTurnProof?.runID == run2.id)
        #expect(handoff.closedTurnProof?.terminal == .incomplete(.other))
        #expect(handoff.closedTurnProof?.formalMessageID == record2.formalMessageID)
        #expect(try await reopened.conversationControlState(sessionID: sessionID)?.entries.isEmpty == true)
        #expect(try await reopened.readMessages(sessionID: sessionID) == beforeMessages)
        try await reopened.close()

        // Reopen and verify persistence, validateStoredHandoff, and subsequent continuation.
        let reopened2 = try backend.open(at: directory)
        let storedHandoff = try #require(try await reopened2.contextHandoff(sessionID: sessionID))
        #expect(storedHandoff == handoff)
        try await reopened2.validateStoredHandoff(storedHandoff, sessionID: sessionID)
        #expect(try await reopened2.readMessages(sessionID: sessionID) == beforeMessages)
        #expect(try await reopened2.latestRunRecord(sessionID: sessionID) == .terminal(record2, .incomplete(.other)))

        let resumed = try agent.makeSession(id: sessionID, journal: reopened2)
        let run3 = try await resumed.run("user 3", contextControls: try .init(reminder: "fresh reminder"))
        #expect(try await run3.wait().outcome == .completed)
        try await run3.waitForDrain()

        let thirdRequest = try #require(await provider.lastRequest)
        #expect(thirdRequest.messages == beforeMessages.map(\.message) + [.user([.text("user 3")])])
        #expect(try await reopened2.runRecord(sessionID: sessionID, runID: run2.id) == .terminal(record2, .incomplete(.other)))
        let afterMessages = try await reopened2.readMessages(sessionID: sessionID)
        #expect(Array(afterMessages.prefix(beforeMessages.count)) == beforeMessages)
        try await reopened2.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func multiRoundToolTailAbandonedRunClosesHandsOffAndPreservesToolRounds(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("tool-tail-\(backend.name)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = ContractCommitFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "tool-tail-closure",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )

        let toolCounter = ContractCounter()
        let addTool = try ContractAddTool(counter: toolCounter)
        let call1 = ToolCall(
            id: .init(rawValue: "tool-round-1"),
            name: ContractAddTool.name,
            argumentsJSON: #"{"lhs":10,"rhs":20}"#,
            completeness: .complete
        )
        let call2 = ToolCall(
            id: .init(rawValue: "tool-round-2"),
            name: ContractAddTool.name,
            argumentsJSON: #"{"lhs":30,"rhs":12}"#,
            completeness: .complete
        )
        let provider = ContractControlsProvider { request, turn in
            switch turn {
            case 1:
                return Self.textEvents(request, "seed answer")
            case 2:
                return Self.toolEvents(request, [call1])
            case 3:
                return Self.toolEvents(request, [call2])
            case 4:
                // Both tool rounds and their recurring reminder boundaries are already committed.
                fault.blockAll(.beforeCommit)
                throw ModelProviderError(kind: .transport, message: "crash after two tool rounds")
            default:
                return Self.textEvents(request, "final summary")
            }
        }
        let binding = try Self.makeBinding(provider: provider, profile: "tool-tail-profile")
        let agent = try Agent(binding: binding, tools: [addTool])
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)

        let run1 = try await session.run("seed turn", contextControls: try .init(reminder: "check math"))
        #expect(try await run1.wait().outcome == .completed)
        try await run1.waitForDrain()

        let run2 = try await session.run("two step math", contextControls: try .init(reminder: "check math"))
        await #expect(throws: (any Error).self) { _ = try await run2.wait() }
        try await run2.waitForDrain()
        #expect(await toolCounter.count == 2)
        try await journal.close()

        let reopened = try backend.open(at: directory)
        guard case .admitted(let record2) = try await reopened.latestRunRecord(sessionID: sessionID) else {
            Issue.record("expected .admitted multi-round tool run after reopen")
            try await reopened.close()
            return
        }
        let beforeMessages = try await reopened.readMessages(sessionID: sessionID)
        #expect(beforeMessages.map(\.message.role) == [.user, .assistant, .user, .assistant, .tool, .assistant, .tool])
        let controls = try #require(try await reopened.conversationControlState(sessionID: sessionID))
        // Reminders anchored at user1, user2, tool(r1), and tool(r2).
        #expect(controls.entries.count == 4)

        let fresh = try agent.makeSession(id: sessionID, journal: reopened)
        #expect(try await fresh.closeAbandonedRun(runID: run2.id) == .incomplete(.other))
        #expect(try await reopened.readMessages(sessionID: sessionID) == beforeMessages)

        let handoffOp = try await fresh.handoffToOrdinary(
            using: binding,
            discardingRetiredProviderContinuations: true,
            allowingIncompleteTurn: true
        )
        let handoff = try await handoffOp.wait()
        try await handoffOp.waitForDrain()
        #expect(handoff.completedRunID == nil)
        #expect(handoff.closedTurnProof?.runID == run2.id)
        #expect(handoff.closedTurnProof?.terminal == .incomplete(.other))
        #expect(try await reopened.conversationControlState(sessionID: sessionID)?.entries.isEmpty == true)
        #expect(try await reopened.readMessages(sessionID: sessionID) == beforeMessages)
        try await reopened.close()

        let reopened2 = try backend.open(at: directory)
        let storedHandoff = try #require(try await reopened2.contextHandoff(sessionID: sessionID))
        try await reopened2.validateStoredHandoff(storedHandoff, sessionID: sessionID)
        #expect(try await reopened2.readMessages(sessionID: sessionID) == beforeMessages)
        #expect(try await reopened2.latestRunRecord(sessionID: sessionID) == .terminal(record2, .incomplete(.other)))

        let resumed = try agent.makeSession(id: sessionID, journal: reopened2)
        let run3 = try await resumed.run("summarize all steps", contextControls: try .init(reminder: "summarize"))
        #expect(try await run3.wait().outcome == .completed)
        try await run3.waitForDrain()

        let finalRequest = try #require(await provider.lastRequest)
        #expect(finalRequest.messages == beforeMessages.map(\.message) + [.user([.text("summarize all steps")])])
        #expect(await toolCounter.count == 2)
        try await reopened2.close()
    }

    @Test(arguments: JournalContractBackends.all, [false, true])
    func pendingMutationIntentAndNeedsReconciliationBlockClosureUntilAbortedOrReconciled(
        _ backend: any JournalBackendHarness,
        _ reconcile: Bool
    ) async throws {
        let directory = tempDir("mutation-\(reconcile ? "reconcile" : "abort")-\(backend.name)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = ContractCommitFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "mutation-closure",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )

        let mutationCounter = ContractCounter()
        let writeTool = try ContractMutationTool(counter: mutationCounter) {
            // Intent is already durable before execute(); block markMutationNeedsReconciliation and commitRunTerminal.
            fault.blockAll(.beforeCommit)
            throw ContractSimulatedToolError.crashDuringEffect
        }
        let mutationCall = ToolCall(
            id: .init(rawValue: "mutate-1"),
            name: ContractMutationTool.name,
            argumentsJSON: #"{"item":"doc-1"}"#,
            completeness: .complete
        )
        let provider = ContractControlsProvider { request, turn in
            if turn == 1 {
                return Self.toolEvents(request, [mutationCall])
            }
            return Self.textEvents(request, "continued after recovery")
        }
        let binding = try Self.makeBinding(provider: provider, profile: "mutation-profile")
        let agent = try Agent(binding: binding, tools: [writeTool])
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)

        let run = try await session.run(
            "apply mutation",
            contextControls: try .init(reminder: "report outcome"),
            operationID: "mutation-op-1"
        )
        await #expect(throws: (any Error).self) { _ = try await run.wait() }
        try await run.waitForDrain()
        #expect(await mutationCounter.count == 1)
        try await journal.close()

        let reopened = try backend.open(at: directory)
        guard case .admitted(let record) = try await reopened.latestRunRecord(sessionID: sessionID) else {
            Issue.record("expected .admitted run with pending mutation")
            try await reopened.close()
            return
        }
        #expect(record.runID == run.id)
        let intentPending = try await reopened.pendingMutations(sessionID: sessionID)
        #expect(intentPending.map(\.state) == [.intent])

        let staleSession = try agent.makeSession(id: sessionID, journal: reopened)
        _ = try await staleSession.conversationSnapshot()

        // 1. Refuses closure while mutation is .intent.
        await #expect(throws: AgentJournalError.mutationRequiresReconciliation) {
            _ = try await staleSession.closeAbandonedRun(runID: run.id)
        }
        #expect(try await reopened.latestRunRecord(sessionID: sessionID) == .admitted(record))

        // 2. Quarantining to .needsReconciliation still refuses closure.
        let quarantined = try await reopened.recoverPendingMutations(sessionID: sessionID)
        let pending = try #require(quarantined.first)
        #expect(pending.state == .needsReconciliation)
        await #expect(throws: AgentJournalError.mutationRequiresReconciliation) {
            _ = try await staleSession.closeAbandonedRun(runID: run.id)
        }
        #expect(try await reopened.latestRunRecord(sessionID: sessionID) == .admitted(record))

        // 3. Resolve mutation via either abortMutation or reconcileMutation.
        if reconcile {
            let receipt = ToolReceipt(
                operationID: pending.intent.idempotencyKey,
                status: .succeeded,
                confirmedTargets: [.init(namespace: "contract.mutation", id: "doc-1")],
                revision: "rev-1"
            )
            try await reopened.reconcileMutation(
                pending,
                receipt: receipt,
                output: .object(["written": .bool(true)])
            )
            // reconcileMutation advances historyHead, so staleSession must throw concurrentWriter.
            await #expect(throws: AgentJournalError.concurrentWriter) {
                _ = try await staleSession.closeAbandonedRun(runID: run.id)
            }
        } else {
            try await reopened.abortMutation(
                pending,
                confirmedNoEffect: try AgentNoEffectConfirmation(basis: "verified absent on target")
            )
        }
        #expect(try await reopened.pendingMutations(sessionID: sessionID).isEmpty)

        // 4. Fresh session closes the abandoned run and performs incomplete handoff cleanly.
        let settledMessages = try await reopened.readMessages(sessionID: sessionID)
        if reconcile {
            #expect(settledMessages.map(\.message.role) == [.user, .assistant, .tool])
        } else {
            #expect(settledMessages.map(\.message.role) == [.user])
        }

        let fresh = try agent.makeSession(id: sessionID, journal: reopened)
        #expect(try await fresh.closeAbandonedRun(runID: run.id) == .incomplete(.other))
        #expect(try await reopened.readMessages(sessionID: sessionID) == settledMessages)

        let handoffOp = try await fresh.handoffToOrdinary(
            using: binding,
            discardingRetiredProviderContinuations: true,
            allowingIncompleteTurn: true
        )
        let handoff = try await handoffOp.wait()
        try await handoffOp.waitForDrain()
        #expect(handoff.completedRunID == nil)
        #expect(handoff.closedTurnProof?.runID == run.id)
        #expect(handoff.closedTurnProof?.terminal == .incomplete(.other))
        #expect(try await reopened.readMessages(sessionID: sessionID) == settledMessages)
        #expect(try await reopened.conversationControlState(sessionID: sessionID)?.entries.isEmpty == true)
        try await reopened.close()

        let reopened2 = try backend.open(at: directory)
        let storedHandoff = try #require(try await reopened2.contextHandoff(sessionID: sessionID))
        try await reopened2.validateStoredHandoff(storedHandoff, sessionID: sessionID)
        let resumed = try agent.makeSession(id: sessionID, journal: reopened2)
        let nextRun = try await resumed.run("continue", contextControls: try .init(reminder: "next"))
        #expect(try await nextRun.wait().outcome == .completed)
        try await nextRun.waitForDrain()
        #expect(await mutationCounter.count == 1)
        let nextRequest = try #require(await provider.lastRequest)
        #expect(nextRequest.messages == settledMessages.map(\.message) + [.user([.text("continue")])])
        try await reopened2.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func followUpAdmittedAbandonedRunClosesWithoutReleasingNeedsInspection(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("followup-\(backend.name)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = ContractCommitFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "followup-closure",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )

        let failingProvider = ContractControlsProvider { _, _ in
            fault.blockAll(.beforeCommit)
            throw ModelProviderError(kind: .transport, message: "queued run interrupted")
        }
        let failingBinding = try Self.makeBinding(provider: failingProvider, profile: "queue-profile")
        let agent = try Agent(binding: failingBinding)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)

        _ = try await session.enqueueFollowUp(.init(
            inputID: "queued-1",
            text: "first queued",
            operationID: "op-queued-1",
            configurationRef: "v1"
        ))
        _ = try await session.enqueueFollowUp(.init(
            inputID: "queued-2",
            text: "second queued",
            operationID: "op-queued-2",
            configurationRef: "v1"
        ))

        let dispatcher1 = try await session.startFollowUpDispatch(
            policy: .init(runTimeout: .seconds(10)),
            resolver: ContractFollowUpResolver(session: session, binding: failingBinding)
        )
        await dispatcher1.waitUntilPaused()
        await dispatcher1.stop()
        try await dispatcher1.waitForDrain()
        try await journal.close()

        // Reopen into a clean unpoisoned handle and verify dispatchOwned while active, then closure preserves needsInspection.
        let reopened = try backend.open(at: directory)
        guard case .admitted(let record) = try await reopened.latestRunRecord(sessionID: sessionID) else {
            Issue.record("expected .admitted follow-up run after reopen")
            try await reopened.close()
            return
        }
        #expect(record.followUpInputID == "queued-1")

        let succeedingProvider = ContractControlsProvider { request, _ in
            Self.textEvents(request, "queued answer")
        }
        let succeedingBinding = try Self.makeBinding(provider: succeedingProvider, profile: "queue-profile")
        let resumedAgent = try Agent(binding: succeedingBinding)
        let fresh = try resumedAgent.makeSession(id: sessionID, journal: reopened)
        let peer = try resumedAgent.makeSession(id: sessionID, journal: reopened)

        let dispatcher2 = try await fresh.startFollowUpDispatch(
            policy: .init(runTimeout: .seconds(10)),
            resolver: ContractFollowUpResolver(session: fresh, binding: succeedingBinding)
        )
        await dispatcher2.waitUntilPaused()
        #expect(await dispatcher2.status().interruptedInputID == "queued-1")

        // Active dispatcher owns the session on both the owning handle and peer handle.
        await #expect(throws: AgentFollowUpError.dispatchOwned) {
            _ = try await fresh.closeAbandonedRun(runID: record.runID)
        }
        await #expect(throws: AgentFollowUpError.dispatchOwned) {
            _ = try await peer.closeAbandonedRun(runID: record.runID)
        }

        await dispatcher2.stop()
        try await dispatcher2.waitForDrain()

        // Close abandoned run: writes .incomplete(.other) without releasing queued-1 from needsInspection.
        #expect(try await fresh.closeAbandonedRun(runID: record.runID) == .incomplete(.other))
        #expect(try await reopened.latestRunRecord(sessionID: sessionID) == .terminal(record, .incomplete(.other)))
        #expect(
            try await fresh.followUp(inputID: "queued-1")?.state
                == .admitted(runID: record.runID, formalMessageID: record.formalMessageID)
        )
        #expect(try await fresh.followUp(inputID: "queued-2")?.state == .queued)

        let secondCompleted = ContractAsyncGate()
        let dispatcher3 = try await fresh.startFollowUpDispatch(
            policy: .init(runTimeout: .seconds(10)),
            resolver: ContractFollowUpResolver(session: fresh, binding: succeedingBinding),
            onRun: { item, run in
                _ = try? await run.wait()
                try? await run.waitForDrain()
                if item.inputID == "queued-2" {
                    await secondCompleted.release()
                }
            }
        )
        await dispatcher3.waitUntilPaused()
        #expect(await dispatcher3.status().interruptedInputID == "queued-1")
        #expect(await succeedingProvider.requestCount == 0)
        await #expect(throws: AgentFollowUpError.needsInspection) {
            try await dispatcher3.resume()
        }

        try await dispatcher3.resumeAfterInspection(inputID: "queued-1")
        await secondCompleted.waitReleased()
        await dispatcher3.stop()
        try await dispatcher3.waitForDrain()

        #expect(await succeedingProvider.requestCount == 1)
        #expect(try await fresh.followUp(inputID: "queued-2")?.state != .queued)
        try await reopened.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func commitUnknownAndClosedStoreRejectLatestRunRecordAndClosure(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("commit-unknown-\(backend.name)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = ContractCommitFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "commit-unknown-closure",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )

        let provider = ContractControlsProvider { request, _ in
            Self.textEvents(request, "should not run")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)

        fault.armOnce(.afterCommitBeforeAck)
        let run = try await session.run("uncertain startup")
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await run.wait() }
        try await run.waitForDrain()
        #expect(await provider.requestCount == 0)

        // Poisoned / commitUnknown session refuses both latestRunRecord and closeAbandonedRun.
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.latestRunRecord()
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.closeAbandonedRun(runID: run.id)
        }
        try await journal.close()

        // Closed journal refuses latestRunRecord with storeClosed.
        await #expect(throws: AgentJournalError.storeClosed) {
            _ = try await journal.latestRunRecord(sessionID: sessionID)
        }

        // Reopen reveals the committed startup as .admitted, ready for explicit closure.
        let reopened = try backend.open(at: directory)
        guard case .admitted(let record) = try await reopened.latestRunRecord(sessionID: sessionID) else {
            Issue.record("expected startup commit to be visible as .admitted after reopen")
            try await reopened.close()
            return
        }
        #expect(record.runID == run.id)

        let fresh = try agent.makeSession(id: sessionID, journal: reopened)
        try await reopened.close()

        // Cleanly closed store throws storeClosed from journal and session APIs alike.
        await #expect(throws: AgentJournalError.storeClosed) {
            _ = try await reopened.latestRunRecord(sessionID: sessionID)
        }
        await #expect(throws: AgentJournalError.storeClosed) {
            _ = try await fresh.latestRunRecord()
        }
        await #expect(throws: AgentJournalError.storeClosed) {
            _ = try await fresh.closeAbandonedRun(runID: run.id)
        }

        // Reopen once more and verify explicit closure succeeds.
        let reopened2 = try backend.open(at: directory)
        let fresh2 = try agent.makeSession(id: sessionID, journal: reopened2)
        #expect(try await fresh2.closeAbandonedRun(runID: run.id) == .incomplete(.other))
        #expect(try await reopened2.latestRunRecord(sessionID: sessionID) == .terminal(record, .incomplete(.other)))
        try await reopened2.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func unsupportedFormatJournalsRejectLatestRunRecordAndClosure(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("unsupported-format-\(backend.name)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(
            at: directory,
            operationDomain: "unsupported-format",
            capabilities: .init()
        )
        #expect(!journal.supportsRunRecords)

        let provider = ContractPlainProvider { request, _ in Self.textEvents(request, "ok") }
        let agent = try Agent(model: ModelID(provider: provider.descriptor.id, name: "model"), provider: provider)
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("plain")
        _ = try await run.wait()
        try await run.waitForDrain()

        await #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try await journal.latestRunRecord(sessionID: session.id)
        }
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try await session.latestRunRecord()
        }
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try await session.closeAbandonedRun(runID: run.id)
        }
        try await journal.close()
    }

    @Test func sqliteSchemaVersionStaysV1AndStoredHandoffValidatesAfterAbandonedRunClosure() async throws {
        let directory = tempDir("sqlite-schema-v1")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = SQLiteBackendHarness()
        let fault = ContractCommitFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "sqlite-schema-v1",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )

        let provider = ContractControlsProvider { request, turn in
            if turn == 1 {
                fault.blockAll(.beforeCommit)
                throw ModelProviderError(kind: .transport, message: "crash before terminal")
            }
            return Self.textEvents(request, "recovered reply")
        }
        let binding = try Self.makeBinding(provider: provider, profile: "sqlite-v1")
        let agent = try Agent(binding: binding)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)

        let run = try await session.run("abandoned on sqlite", contextControls: try .init(reminder: "keep v1"))
        await #expect(throws: (any Error).self) { _ = try await run.wait() }
        try await run.waitForDrain()
        try await journal.close()

        #expect(try Self.readSQLiteSchemaVersion(at: directory) == 1)
        #expect(try Self.readSQLiteRunTerminalJSON(at: directory, sessionID: sessionID, runID: run.id) == nil)

        let reopened = try backend.open(at: directory)
        guard case .admitted(let record) = try await reopened.latestRunRecord(sessionID: sessionID) else {
            Issue.record("expected .admitted on reopened sqlite store")
            try await reopened.close()
            return
        }
        let beforeMessages = try await reopened.readMessages(sessionID: sessionID)

        let fresh = try agent.makeSession(id: sessionID, journal: reopened)
        #expect(try await fresh.closeAbandonedRun(runID: run.id) == .incomplete(.other))

        let handoffOp = try await fresh.handoffToOrdinary(
            using: binding,
            discardingRetiredProviderContinuations: true,
            allowingIncompleteTurn: true
        )
        let handoff = try await handoffOp.wait()
        try await handoffOp.waitForDrain()
        #expect(handoff.closedTurnProof?.terminal == .incomplete(.other))
        try await reopened.close()

        // Inspect SQLite directly: schema_version remains 1 and terminal_json encodes .incomplete(.other).
        #expect(try Self.readSQLiteSchemaVersion(at: directory) == 1)
        let terminalBytes = try #require(
            try Self.readSQLiteRunTerminalJSON(at: directory, sessionID: sessionID, runID: run.id)
        )
        let decodedTerminal = try JSONDecoder().decode(AgentRunTerminal.self, from: terminalBytes)
        #expect(decodedTerminal == .incomplete(.other))

        // Reopen and validate stored handoff and continuation.
        let reopened2 = try backend.open(at: directory)
        let storedHandoff = try #require(try await reopened2.contextHandoff(sessionID: sessionID))
        #expect(storedHandoff == handoff)
        try await reopened2.validateStoredHandoff(storedHandoff, sessionID: sessionID)
        #expect(try await reopened2.readMessages(sessionID: sessionID) == beforeMessages)
        #expect(try await reopened2.latestRunRecord(sessionID: sessionID) == .terminal(record, .incomplete(.other)))

        let resumed = try agent.makeSession(id: sessionID, journal: reopened2)
        let nextRun = try await resumed.run("follow up", contextControls: try .init(reminder: "next"))
        #expect(try await nextRun.wait().outcome == .completed)
        try await nextRun.waitForDrain()
        try await reopened2.close()
    }

    // MARK: - SQLite Direct Inspection

    private static func withReadOnlySQLite<T>(at directory: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let dbURL = directory.appendingPathComponent("journal.sqlite3")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw AgentJournalError.persistenceUnavailable("unable to open sqlite file for inspection")
        }
        defer { sqlite3_close_v2(db) }
        return try body(db)
    }

    private static func readSQLiteSchemaVersion(at directory: URL) throws -> Int {
        try withReadOnlySQLite(at: directory) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT schema_version FROM store_meta WHERE singleton = 1;",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK, let prepared = stmt else {
                if let stmt { sqlite3_finalize(stmt) }
                throw AgentJournalError.persistenceUnavailable("unable to prepare schema_version query")
            }
            defer { sqlite3_finalize(prepared) }
            guard sqlite3_step(prepared) == SQLITE_ROW else {
                throw AgentJournalError.invalidHeader
            }
            return Int(sqlite3_column_int64(prepared, 0))
        }
    }

    private static func readSQLiteRunTerminalJSON(
        at directory: URL,
        sessionID: UUID,
        runID: UUID
    ) throws -> Data? {
        try withReadOnlySQLite(at: directory) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT terminal_json FROM run_records WHERE session_id = ? AND run_id = ?;",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK, let prepared = stmt else {
                if let stmt { sqlite3_finalize(stmt) }
                throw AgentJournalError.persistenceUnavailable("unable to prepare run_records query")
            }
            defer { sqlite3_finalize(prepared) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = sessionID.uuidString.withCString { sqlite3_bind_text(prepared, 1, $0, -1, transient) }
            _ = runID.uuidString.withCString { sqlite3_bind_text(prepared, 2, $0, -1, transient) }
            guard sqlite3_step(prepared) == SQLITE_ROW else {
                throw AgentJournalError.invalidRecord
            }
            if sqlite3_column_type(prepared, 0) == SQLITE_NULL {
                return nil
            }
            guard let ptr = sqlite3_column_blob(prepared, 0) else {
                return Data()
            }
            let count = Int(sqlite3_column_bytes(prepared, 0))
            return Data(bytes: ptr, count: count)
        }
    }
}

private enum ContractSimulatedToolError: Error {
    case crashDuringEffect
}

private final class ContractCommitFaultController: @unchecked Sendable {
    private let lock = NSLock()
    private var armedOnceStages: Set<JournalContractFaultStage> = []
    private var blockedStages: Set<JournalContractFaultStage> = []

    func armOnce(_ stage: JournalContractFaultStage) {
        lock.withLock { _ = armedOnceStages.insert(stage) }
    }

    func blockAll(_ stage: JournalContractFaultStage) {
        lock.withLock { _ = blockedStages.insert(stage) }
    }

    func check(_ stage: JournalContractFaultStage) throws {
        let shouldThrow = lock.withLock { () -> Bool in
            if blockedStages.contains(stage) { return true }
            return armedOnceStages.remove(stage) != nil
        }
        if shouldThrow {
            throw AgentJournalError.persistenceUnavailable("injected \(stage.rawValue)")
        }
    }
}

private actor ContractAsyncGate {
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

private actor ContractCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct ContractPlainProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(
        id: "abandoned-plain",
        capabilities: [.streaming, .multiTurn]
    )
    let respond: @Sendable (ModelRequest, Int) async throws -> [ModelEvent]

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            for event in try await respond(request, 1) {
                try emit(event)
            }
        }
    }
}

private actor ContractControlsProvider: ModelProviderConversationControls {
    nonisolated let descriptor = ModelProviderDescriptor(
        id: "abandoned-contract",
        capabilities: [.streaming, .multiTurn, .tools]
    )
    nonisolated let conversationControlCapabilities: ModelConversationControlCapabilities? = .init(
        inlineTools: true,
        reminders: true
    )
    private let respond: @Sendable (ModelRequest, Int) async throws -> [ModelEvent]
    private var requests: [ModelRequest] = []

    init(respond: @escaping @Sendable (ModelRequest, Int) async throws -> [ModelEvent]) {
        self.respond = respond
    }

    var requestCount: Int { requests.count }
    var lastRequest: ModelRequest? { requests.last }

    private func record(_ request: ModelRequest) -> Int {
        requests.append(request)
        return requests.count
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

private struct ContractAddTool: AgentTool {
    struct Input: Codable, Sendable { let lhs: Int; let rhs: Int }
    struct Output: Codable, Sendable { let sum: Int }
    static let name = "contract_add"
    static let description = "Add two integers"
    static let inputSchema = ToolSchema.object(
        properties: ["lhs": .integer, "rhs": .integer],
        required: ["lhs", "rhs"]
    )
    static let outputSchema = ToolSchema.object(properties: ["sum": .integer], required: ["sum"])
    let counter: ContractCounter
    let policy: ToolPolicy

    init(counter: ContractCounter) throws {
        self.counter = counter
        self.policy = try .readOnly(authorization: .notRequired)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await counter.increment()
        return ToolResult(output: Output(sum: input.lhs + input.rhs))
    }
}

private struct ContractMutationTool: AgentTool {
    struct Input: Codable, Sendable { let item: String }
    struct Output: Codable, Sendable { let written: Bool }
    static let name = "contract_mutate"
    static let description = "Mutation fixture tool"
    static let inputSchema = ToolSchema.object(properties: ["item": .string], required: ["item"])
    static let outputSchema = ToolSchema.object(properties: ["written": .boolean], required: ["written"])
    let counter: ContractCounter
    let body: @Sendable () throws -> Void
    let policy: ToolPolicy

    init(counter: ContractCounter, body: @escaping @Sendable () throws -> Void) throws {
        self.counter = counter
        self.body = body
        self.policy = try .mutation(authorization: .notRequired, evidence: .none)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "contract.mutation", id: input.item))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "contract.mutation", id: input.item)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await counter.increment()
        try body()
        return ToolResult(
            output: Output(written: true),
            receipt: ToolReceipt(
                operationID: context.idempotencyKey ?? "",
                status: .succeeded,
                confirmedTargets: [.init(namespace: "contract.mutation", id: input.item)],
                revision: "rev-1"
            )
        )
    }
}

private struct ContractFollowUpResolver: AgentFollowUpResolver {
    let session: AgentSession
    let binding: AgentModelBinding

    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        let capabilities = try await session.bindCapabilities(
            identity: "contract-followup",
            version: "1",
            backendInstanceID: "fixture",
            backendVersion: "1",
            allowedResources: [],
            tools: []
        )
        return .init(model: binding, capabilities: capabilities, expectedConversationRevision: nil)
    }
}
