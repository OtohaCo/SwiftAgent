@testable import AgentCore
import AgentModels
import AgentTools
import Foundation
import XCTest

final class AgentMutationRecoveryTests: XCTestCase {
    func testMutationIntentIsDurableBeforeExecutorAndSettledByReceipt() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let probe = MutationProbe()
        let journal = try AgentJournal(persistenceURL: url)
        let tool = try MutationTool(probe: probe, journalURL: url)
        let call = mutationCall()
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "Done")
        }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])
        let run = try await agent.makeSession(journal: journal).run("Update the listing")

        let result = try await run.wait()
        let executionCount = await probe.count
        let sawDurableIntent = await probe.sawDurableIntent
        let pending = await journal.pendingMutations()
        XCTAssertEqual(result.toolCalls, 1)
        XCTAssertEqual(executionCount, 1)
        XCTAssertTrue(sawDurableIntent)
        XCTAssertTrue(pending.isEmpty)

        let events = await journal.snapshot().map(\.event)
        XCTAssertTrue(events.contains(where: { if case .pendingMutation = $0 { true } else { false } }))
        XCTAssertTrue(events.contains(where: {
            if case .mutationSettled(_, _, .executor) = $0 { true } else { false }
        }))
    }

    func testMutationWithoutJournalFailsClosedBeforeExecutor() async throws {
        let probe = MutationProbe()
        let tool = try MutationTool(probe: probe)
        let call = mutationCall()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])
        do {
            _ = try agent.makeSession()
            XCTFail("Mutation without a journal should fail before a run starts")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .durableJournalRequired)
        }
        let executionCount = await probe.count
        XCTAssertEqual(executionCount, 0)
    }

    func testMutationWithMemoryJournalFailsClosedBeforeExecutor() async throws {
        let probe = MutationProbe()
        let tool = try MutationTool(probe: probe)
        let call = mutationCall()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])
        let journal = AgentJournal()
        XCTAssertEqual(journal.storage, .memory)
        do {
            _ = try agent.makeSession(journal: journal)
            XCTFail("Memory journals must not open a mutation Session")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .durableJournalRequired)
        }
        let executionCount = await probe.count
        XCTAssertEqual(executionCount, 0)
        let snapshot = await journal.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        let pending = await journal.pendingMutations()
        XCTAssertTrue(pending.isEmpty)
        let modelRequests = await provider.log.requests
        XCTAssertEqual(modelRequests.count, 0)
    }

    func testPersistenceFailurePreventsMutationExecutor() async throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: blocker) }

        let journal = try AgentJournal(persistenceURL: blocker.appendingPathComponent("journal.log"))
        let probe = MutationProbe()
        let tool = try MutationTool(probe: probe, journalURL: blocker.appendingPathComponent("journal.log"))
        let call = mutationCall()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])

        do {
            let run = try await agent.makeSession(journal: journal).run("Update the listing")
            _ = try await run.wait()
            XCTFail("Expected durable journal failure")
        } catch is AgentJournalError {
            // The parent path is a file, so no durable session record can be created.
        }
        let executionCount = await probe.count
        XCTAssertEqual(executionCount, 0)
    }

    func testRecoveryQuarantinesUnknownMutationAndRequiresExplicitReceipt() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let sessionID = UUID()
        let runID = UUID()
        let request = mutationRequest(sessionID: sessionID, runID: runID, callID: .init(rawValue: "call-1"))
        try await journal.admit(request)

        let restarted = try AgentJournal.load(from: url)
        let recovered = try await restarted.recoverPendingMutations(sessionID: sessionID)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].state, .needsReconciliation)

        do {
            try await restarted.admit(mutationRequest(sessionID: sessionID, runID: UUID(), callID: .init(rawValue: "call-2")))
            XCTFail("A quarantined mutation must block new mutations")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .mutationRequiresReconciliation)
        }

        try await restarted.reconcileMutation(recovered[0], receipt: validReceipt(operationID: request.idempotencyKey))
        let pending = await restarted.pendingMutations()
        XCTAssertTrue(pending.isEmpty)
        let otherSession = UUID()
        try await restarted.admit(mutationRequest(sessionID: otherSession, runID: UUID(), callID: .init(rawValue: "call-2")))
        try await restarted.admit(mutationRequest(sessionID: sessionID, runID: UUID(), callID: .init(rawValue: "call-1")))
    }

    func testAbortMutationRequiresQuarantineAndDoesNotSettleArbitraryJSON() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let sessionID = UUID()
        let runID = UUID()
        let request = mutationRequest(sessionID: sessionID, runID: runID, callID: .init(rawValue: "call-abort"))
        try await journal.admit(request)
        let pendingBefore = await journal.pendingMutations()
        let intent = try XCTUnwrap(pendingBefore.first)
        XCTAssertEqual(intent.state, .intent)
        do {
            try await journal.abortMutation(intent)
            XCTFail("An in-flight intent must not be aborted without recovery")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .mutationRequiresReconciliation)
        }

        let recovered = try await journal.recoverPendingMutations(sessionID: sessionID)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].state, .needsReconciliation)
        try await journal.abortMutation(recovered[0])
        let remaining = await journal.pendingMutations()
        XCTAssertTrue(remaining.isEmpty)

        do {
            try await journal.abortMutation(recovered[0])
            XCTFail("A settled abort must not be repeated")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .mutationRequiresReconciliation)
        }
        let fakeReceipt = validReceipt(operationID: request.idempotencyKey)
        do {
            try await journal.reconcileMutation(recovered[0], receipt: fakeReceipt)
            XCTFail("Abort must close the intent against later settlement")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .mutationRequiresReconciliation)
        }
    }

    func testReceiptMismatchLeavesPendingMutationForRecovery() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let sessionID = UUID()
        let runID = UUID()
        let callID = ToolCallID(rawValue: "call-1")
        let request = mutationRequest(sessionID: sessionID, runID: runID, callID: callID)
        try await journal.admit(request)

        do {
            try await journal.settleMutation(sessionID: sessionID, runID: runID, callID: callID,
                                             receipt: validReceipt(operationID: "wrong-operation"),
                                             output: .object(["updated": .bool(true)]))
            XCTFail("Receipt binding must fail closed")
        } catch {
            XCTAssertEqual(error as? ToolReceiptError, .operationMismatch)
        }
        let remaining = await journal.pendingMutations()
        XCTAssertEqual(remaining.count, 1)
    }

    func testAtomicMutationCommitKeepsIntentWhenHistoryCommitCannotPublish() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let sessionID = UUID()
        let runID = UUID()
        let request = mutationRequest(sessionID: sessionID, runID: runID, callID: .init(rawValue: "call-1"))
        try await journal.admit(request)

        // Make this instance stale without touching the mutation intent. A failed
        // atomic commit must leave the intent available for crash recovery.
        let concurrent = try AgentJournal.load(from: url)
        _ = try await concurrent.append(.userMessage("concurrent writer"), sessionID: sessionID,
                                        runID: UUID(), durability: .durable)

        do {
            try await journal.commitMutation(
                sessionID: sessionID,
                runID: runID,
                callID: request.callID,
                receipt: validReceipt(operationID: request.idempotencyKey),
                output: .object(["updated": .bool(true)]),
                history: [.user([.text("Update the listing")])],
                steeringIDs: []
            )
            XCTFail("A stale journal must reject the atomic mutation commit")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .concurrentWriter)
        }

        let pending = await journal.pendingMutations()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].state, .intent)

        let restarted = try AgentJournal.load(from: url)
        let recovered = try await restarted.recoverPendingMutations(sessionID: sessionID)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].state, .needsReconciliation)
    }

    func testPostExecutorFailureSurfacesQuarantineFailure() async throws {
        let call = mutationCall()
        let tool = try MutationTool(probe: MutationProbe())
        let registry = try ToolRegistry(tools: [AnyAgentTool(tool)])
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: call.id,
                                  deadline: .now.advanced(by: .seconds(2)),
                                  idempotencyKey: "operation", argumentsJSON: call.argumentsJSON,
                                  evidenceLedger: EvidenceLedger(), mutationAdmission: NoopMutationAdmission())
        let prepared = try registry.prepare(call, context: context)
        let info = ResponseInfo(id: "response", model: fixtureModel)
        let response = ModelResponse(info: info, toolCalls: [call], stopReason: .toolCalls)
        let settlementFailure = AgentJournalError.mutationRequiresReconciliation
        let quarantineFailure = AgentJournalError.concurrentWriter
        let lifecycle = AgentLoopLifecycle(
            control: AgentRunControl(),
            evidenceLedger: EvidenceLedger(),
            checkpoint: { messages, _ in messages },
            recordMutationReceipt: { _, _, _ in throw settlementFailure },
            markMutationNeedsReconciliation: { _ in throw quarantineFailure }
        )
        let progress = AgentToolBatchProgress(prefix: [], response: response, budget: try testBudget(),
                                              lifecycle: lifecycle, emitter: nil)

        do {
            try await progress.record(index: 0, call: prepared,
                                      result: ToolResult(output: .object(["updated": .bool(true)]),
                                                         receipt: validReceipt(operationID: "operation")))
            XCTFail("A quarantine failure must be surfaced")
        } catch let error as AgentMutationPersistenceError {
            XCTAssertEqual(error.settlement, .journal(settlementFailure))
            XCTAssertEqual(error.quarantine, .journal(quarantineFailure))
        } catch {
            XCTFail("Expected AgentMutationPersistenceError, got \(error)")
        }
    }

    func testReceiptSettlementFailureImmediatelyQuarantinesMutation() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let probe = MutationProbe()
        let tool = try MutationTool(probe: probe, journalURL: url, receiptOperationID: "wrong-operation")
        let call = mutationCall()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])
        let run = try await agent.makeSession(journal: journal).run("Update the listing")

        do {
            _ = try await run.wait()
            XCTFail("A receipt settlement failure must fail the run")
        } catch {
            XCTAssertEqual(error as? ToolReceiptError, .operationMismatch)
        }
        let remaining = await journal.pendingMutations()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].state, .needsReconciliation)
    }

    func testLegacyV1PendingMutationLoadsAndIsQuarantined() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let runID = UUID()
        let callID = ToolCallID(rawValue: "legacy-call")
        let intentJSON = """
        {"call":{"id":"legacy-call","name":"update_listing","argumentsJSON":"{\\"id\\":\\"listing-1\\"}","completeness":"complete"},"resources":[{"named":{"_0":{"namespace":"property.listing","id":"listing-1"}}}],"idempotencyKey":"legacy-key"}
        """
        let intent = try JSONDecoder().decode(PendingMutationIntent.self, from: Data(intentJSON.utf8))
        XCTAssertNil(intent.receiptExpectation)
        let record = LegacyJournalRecord(
            sequence: 1,
            timestamp: Date(),
            sessionID: sessionID,
            runID: runID,
            checkpointID: UUID(),
            event: .pendingMutation(intent)
        )
        let payload = try JSONEncoder().encode(LegacyJournalFrame(schemaVersion: 1, records: [record]))
        var data = Data("SWIFTAGENT-JOURNAL-1".utf8)
        data.append(LegacyJournalFrameCodec.frame(payload))
        try data.write(to: url)

        let journal = try AgentJournal.load(from: url)
        let recoveredPending = await journal.pendingMutations()
        XCTAssertEqual(recoveredPending.count, 1)
        XCTAssertEqual(recoveredPending[0].state, .needsReconciliation)
        XCTAssertEqual(recoveredPending[0].runID, runID)
        XCTAssertEqual(recoveredPending[0].intent.call.id, callID)

        let expectation = try ToolReceiptExpectation(
            targets: [.init(namespace: "property.listing", id: "listing-1")],
            revision: .present
        )
        try await journal.reconcileMutation(recoveredPending[0], receipt: validReceipt(operationID: "legacy-key"),
                                            receiptExpectation: expectation)
        let settledPending = await journal.pendingMutations()
        XCTAssertTrue(settledPending.isEmpty)
        let reloaded = try AgentJournal.load(from: url)
        let reloadedPending = await reloaded.pendingMutations()
        XCTAssertTrue(reloadedPending.isEmpty)
    }

    func testLegacyReconciliationRejectsExpectationForDifferentResource() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let runID = UUID()
        let intentJSON = """
        {"call":{"id":"legacy-call","name":"update_listing","argumentsJSON":"{\\"id\\":\\"listing-1\\"}","completeness":"complete"},"resources":[{"named":{"_0":{"namespace":"property.listing","id":"listing-1"}}}],"idempotencyKey":"legacy-key"}
        """
        let intent = try JSONDecoder().decode(PendingMutationIntent.self, from: Data(intentJSON.utf8))
        let record = LegacyJournalRecord(sequence: 1, timestamp: Date(), sessionID: sessionID, runID: runID,
                                          checkpointID: UUID(), event: .pendingMutation(intent))
        let payload = try JSONEncoder().encode(LegacyJournalFrame(schemaVersion: 1, records: [record]))
        var data = Data("SWIFTAGENT-JOURNAL-1".utf8)
        data.append(LegacyJournalFrameCodec.frame(payload))
        try data.write(to: url)

        let journal = try AgentJournal.load(from: url)
        let pending = try await journal.recoverPendingMutations(sessionID: sessionID)
        let wrongExpectation = try ToolReceiptExpectation(
            targets: [.init(namespace: "property.listing", id: "listing-2")], revision: .present
        )
        let wrongReceipt = ToolReceipt(operationID: "legacy-key", status: .succeeded,
                                       confirmedTargets: [.init(namespace: "property.listing", id: "listing-2")],
                                       revision: "v2")

        do {
            try await journal.reconcileMutation(pending[0], receipt: wrongReceipt,
                                                receiptExpectation: wrongExpectation)
            XCTFail("Legacy reconciliation must bind the supplied expectation to the durable resource")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .mutationReceiptInvalid)
        }
        let remaining = await journal.pendingMutations()
        XCTAssertEqual(remaining.count, 1)
    }

    func testRawMutationSettlementEventCannotBypassReconciliationAPI() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let request = mutationRequest(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "call-1"))
        try await journal.admit(request)

        do {
            _ = try await journal.append(.mutationSettled(callID: request.callID,
                                                           receipt: validReceipt(operationID: request.idempotencyKey),
                                                           source: .reconciliation),
                                          sessionID: request.sessionID, runID: request.runID,
                                          durability: .durable)
            XCTFail("Raw settlement events must not bypass reconciliation")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .mutationSettlementRequiresReconciliation)
        }
        let pending = await journal.pendingMutations()
        XCTAssertEqual(pending.count, 1)
    }

    func testMutationLifecycleCannotBePublishedWithMemoryDurability() async throws {
        let journal = AgentJournal()
        let request = mutationRequest(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "call-1"))
        let call = ToolCall(id: request.callID, name: request.name, argumentsJSON: request.argumentsJSON,
                            completeness: .complete)
        let intent = try PendingMutationIntent(call: call, resources: request.resources,
                                               idempotencyKey: request.idempotencyKey,
                                               receiptExpectation: request.receiptExpectation)

        do {
            _ = try await journal.append(.pendingMutation(intent), sessionID: request.sessionID,
                                          runID: request.runID, durability: .memory)
            XCTFail("Mutation lifecycle must be durable")
        } catch {
            XCTAssertEqual(error as? AgentJournalError,
                           .persistenceUnavailable("mutation lifecycle events require durable persistence"))
        }
        let pending = await journal.pendingMutations()
        XCTAssertTrue(pending.isEmpty)
    }

    func testCancellationAfterMutationExecutorEntryQuarantinesWithoutSettlement() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let gate = ManualGate()
        let entered = expectation(description: "mutation executor entered")
        let journal = try AgentJournal(persistenceURL: url)
        let tool = try BlockingMutationTool(gate: gate, entered: entered)
        let call = blockingMutationCall()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])
        let run = try await agent.makeSession(journal: journal).run("Change the listing")

        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(enteredResult, .completed)
        await run.cancel()
        await gate.open()

        do {
            _ = try await run.wait()
            XCTFail("Cancelled mutation must not complete")
        } catch is CancellationError {
            // The executor may have been reached, so the intent remains quarantined.
        }
        let pending = await journal.pendingMutations()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].state, .needsReconciliation)
        let events = await journal.snapshot().map(\.event)
        XCTAssertTrue(events.contains(where: {
            if case .mutationNeedsReconciliation(let callID) = $0 { return callID == call.id }
            return false
        }))
        XCTAssertFalse(events.contains(where: {
            if case .mutationSettled = $0 { true } else { false }
        }))
    }

    func testMutationTimeoutQuarantinesAfterExecutorEntry() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let gate = ManualGate()
        let entered = expectation(description: "mutation executor entered")
        let journal = try AgentJournal(persistenceURL: url)
        let tool = try BlockingMutationTool(gate: gate, entered: entered, timeout: .milliseconds(50))
        let call = blockingMutationCall()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let agent = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [tool],
            configuration: AgentConfiguration(runTimeout: .seconds(2))
        )
        let run = try await agent.makeSession(journal: journal).run("Change the listing")

        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(enteredResult, .completed)
        try await Task.sleep(for: .milliseconds(120))
        await gate.open()
        do {
            _ = try await run.wait()
            XCTFail("Timed out mutation must not complete")
        } catch {
            XCTAssertEqual(error as? AgentLoopError, .toolTimedOut(call.id))
        }
        let pending = await journal.pendingMutations()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].state, .needsReconciliation)
    }

    func testCancellationWhileWaitingForResourcesDoesNotStartExecutor() async throws {
        let scheduler = ToolScheduler()
        let gate = ManualGate()
        let firstEntered = expectation(description: "first mutation executor entered")
        let secondEntered = expectation(description: "waiting mutation must not reach the executor")
        secondEntered.isInverted = true
        let firstURL = temporaryURL()
        let secondURL = temporaryURL()
        defer { cleanup(firstURL); cleanup(secondURL) }
        let firstJournal = try AgentJournal(persistenceURL: firstURL)
        let secondJournal = try AgentJournal(persistenceURL: secondURL)
        let firstTool = try BlockingMutationTool(gate: gate, entered: firstEntered)
        let secondProbe = MutationProbe()
        let secondTool = try MutationTool(probe: secondProbe, entered: secondEntered)
        let firstCall = blockingMutationCall()
        let waitingCall = mutationCall(id: "waiting-call")
        let firstAgent = try Agent(
            model: fixtureModel,
            provider: ScriptedProvider { request, turn in
                turn == 1 ? toolResponse(request, [firstCall]) : textResponse(request, "Done")
            },
            tools: [firstTool],
            configuration: AgentConfiguration(scheduler: scheduler)
        )
        let secondAgent = try Agent(
            model: fixtureModel,
            provider: ScriptedProvider { request, _ in toolResponse(request, [waitingCall]) },
            tools: [secondTool],
            configuration: AgentConfiguration(scheduler: scheduler)
        )
        let firstRun = try await firstAgent.makeSession(journal: firstJournal).run("Change the listing")
        let enteredResult = await XCTWaiter.fulfillment(of: [firstEntered], timeout: 1)
        XCTAssertEqual(enteredResult, .completed)

        let secondRun = try await secondAgent.makeSession(journal: secondJournal).run("Change another listing")
        await scheduler.waitUntilPendingWaiterCountEquals(1)
        await secondRun.cancel()
        let skipped = await XCTWaiter.fulfillment(of: [secondEntered], timeout: 0.3)
        XCTAssertEqual(skipped, .completed)
        await gate.open()
        _ = try await firstRun.wait()
        do {
            _ = try await secondRun.wait()
            XCTFail("Cancelled waiter must not complete")
        } catch is CancellationError {
        }
        let skippedCount = await secondProbe.count
        XCTAssertEqual(skippedCount, 0)
        let pending = await secondJournal.pendingMutations()
        XCTAssertTrue(pending.isEmpty)
        let events = await secondJournal.snapshot().map(\.event)
        XCTAssertFalse(events.contains { if case .pendingMutation = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .mutationSettled = $0 { true } else { false } })
    }

    func testRunStartPersistenceFailureDoesNotCallExecutor() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let probe = MutationProbe()
        let tool = try MutationTool(probe: probe, journalURL: url)
        let call = mutationCall()
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? textResponse(request, "Ready") : toolResponse(request, [call])
        }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])
        let session = try agent.makeSession(journal: journal)
        let warmup = try await session.run("hello")
        _ = try await warmup.wait()
        await session.waitForRunToDrain(runID: warmup.id)
        let warmupRequests = await provider.log.requests.count

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await session.run("Update the listing").wait()
            XCTFail("A journal that can no longer persist must fail closed")
        } catch is AgentJournalError {
        }
        let executionCount = await probe.count
        let authorizationCount = await probe.authorizationCount
        let requests = await provider.log.requests
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(authorizationCount, 0)
        XCTAssertEqual(requests.count, warmupRequests)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("not-a-marker").path))
    }

    func testDurableIntentWriteFailureAfterAuthorizationDoesNotCallExecutor() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let probe = MutationProbe()
        let tool = try MutationTool(probe: probe, journalURL: url) {
            await probe.markAuthorized()
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let call = mutationCall()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])
        let session = try agent.makeSession(journal: journal)

        do {
            _ = try await session.run("Update the listing").wait()
            XCTFail("Durable intent persistence failure must fail closed")
        } catch is AgentJournalError {
        }
        let executionCount = await probe.count
        let authorizationCount = await probe.authorizationCount
        let requests = await provider.log.requests
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(authorizationCount, 1)
        XCTAssertGreaterThanOrEqual(requests.count, 1)
        let pending = await journal.pendingMutations()
        XCTAssertTrue(pending.isEmpty)
        let events = await journal.snapshot().map(\.event)
        XCTAssertTrue(events.contains { if case .userMessage = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .pendingMutation = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .mutationSettled = $0 { true } else { false } })
    }

    func testTimeoutAfterExecutorSideEffectDoesNotReplayMutation() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let gate = ManualGate()
        let entered = expectation(description: "mutation executor entered")
        let probe = MutationProbe()
        let journal = try AgentJournal(persistenceURL: url)
        let tool = try BlockingMutationTool(gate: gate, entered: entered, timeout: .milliseconds(500), probe: probe)
        let call = blockingMutationCall()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let agent = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [tool],
            configuration: AgentConfiguration(runTimeout: .seconds(2))
        )
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let run = try await session.run("Change the listing")
        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(enteredResult, .completed)
        do {
            _ = try await run.wait()
            XCTFail("Timed out mutation must not complete")
        } catch {
            XCTAssertEqual(error as? AgentLoopError, .toolTimedOut(call.id))
        }
        await gate.open()
        await session.waitForRunToDrain(runID: run.id)
        let firstCount = await probe.count
        XCTAssertEqual(firstCount, 1)

        let restarted = try AgentJournal.load(from: url)
        let recovered = try await restarted.recoverPendingMutations(sessionID: sessionID)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].state, .needsReconciliation)
        let replayProbe = MutationProbe()
        let replayTool = try MutationTool(probe: replayProbe)
        let replayCall = mutationCall(id: "replay")
        let replayAgent = try Agent(
            model: fixtureModel,
            provider: ScriptedProvider { request, _ in toolResponse(request, [replayCall]) },
            tools: [replayTool]
        )
        do {
            _ = try await replayAgent.makeSession(id: sessionID, journal: restarted).run("Try again").wait()
            XCTFail("Restart must not replay a quarantined mutation")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .mutationRequiresReconciliation)
        }
        let afterCount = await probe.count
        let replayCount = await replayProbe.count
        XCTAssertEqual(afterCount, 1)
        XCTAssertEqual(replayCount, 0)
        let remaining = await restarted.pendingMutations()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].state, .needsReconciliation)
    }

    func testReceiptAndCancellationDoNotDoubleSettle() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let gate = ManualGate()
        let entered = expectation(description: "mutation executor entered")
        let probe = MutationProbe()
        let journal = try AgentJournal(persistenceURL: url)
        let tool = try BlockingMutationTool(gate: gate, entered: entered, probe: probe)
        let call = blockingMutationCall()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let run = try await session.run("Change the listing")
        await gate.waitUntilBlocked()
        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 0)
        XCTAssertEqual(enteredResult, .completed)

        async let cancelled: Void = run.cancel()
        async let released: Void = gate.open()
        _ = await (cancelled, released)

        var terminalError: (any Error)?
        do {
            _ = try await run.wait()
        } catch {
            terminalError = error
        }
        await session.waitForRunToDrain(runID: run.id)
        let events = await journal.snapshot().map(\.event)
        let settled = events.filter { if case .mutationSettled = $0 { true } else { false } }
        let quarantined = events.filter {
            if case .mutationNeedsReconciliation(let callID) = $0 { return callID == call.id }
            return false
        }
        XCTAssertLessThanOrEqual(settled.count, 1)
        XCTAssertTrue(settled.isEmpty || quarantined.isEmpty, "A call must not both settle and enter reconciliation")
        if settled.isEmpty {
            XCTAssertTrue(terminalError is CancellationError || terminalError is AgentLoopError)
            let pending = await journal.pendingMutations()
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(pending[0].state, .needsReconciliation)
            XCTAssertEqual(quarantined.count, 1)
        } else {
            let leftover = await journal.pendingMutations()
            XCTAssertTrue(leftover.isEmpty)
            XCTAssertEqual(settled.count, 1)
        }
        let sideEffects = await probe.count
        XCTAssertEqual(sideEffects, 1)

        let restarted = try AgentJournal.load(from: url)
        if settled.isEmpty {
            _ = try await restarted.recoverPendingMutations(sessionID: sessionID)
        }
        let replayProbe = MutationProbe()
        let replayCall = mutationCall(id: "replay")
        let replayAgent = try Agent(
            model: fixtureModel,
            provider: ScriptedProvider { request, _ in toolResponse(request, [replayCall]) },
            tools: [try MutationTool(probe: replayProbe)]
        )
        if settled.isEmpty {
            do {
                _ = try await replayAgent.makeSession(id: sessionID, journal: restarted).run("Try again").wait()
                XCTFail("A quarantined mutation must not be replayed")
            } catch {
                XCTAssertEqual(error as? AgentJournalError, .mutationRequiresReconciliation)
            }
            let replayCount = await replayProbe.count
            XCTAssertEqual(replayCount, 0)
        }
        let settledAfter = await restarted.snapshot().map(\.event).filter {
            if case .mutationSettled = $0 { true } else { false }
        }
        XCTAssertEqual(settledAfter.count, settled.count)
    }

    func testPendingMutationBlocksSameSessionAcrossResourcesNotOtherSessions() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let sessionA = UUID()
        let sessionB = UUID()
        try await journal.admit(mutationRequest(sessionID: sessionA, runID: UUID(), callID: .init(rawValue: "call-a1")))
        let recovered = try await journal.recoverPendingMutations(sessionID: sessionA)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].state, .needsReconciliation)

        let blockedProbe = MutationProbe()
        let blockedCall = mutationCall(id: "call-a2", listing: "listing-2")
        let blockedAgent = try Agent(
            model: fixtureModel,
            provider: ScriptedProvider { request, _ in
                toolResponse(request, [blockedCall])
            },
            tools: [try MutationTool(probe: blockedProbe)]
        )
        do {
            _ = try await blockedAgent.makeSession(id: sessionA, journal: journal).run("Update another listing").wait()
            XCTFail("A quarantined session must not start another mutation, even on a disjoint resource")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .mutationRequiresReconciliation)
        }
        let blockedCount = await blockedProbe.count
        XCTAssertEqual(blockedCount, 0)

        let otherProbe = MutationProbe()
        let otherCall = mutationCall(id: "call-b", listing: "listing-2")
        let otherAgent = try Agent(
            model: fixtureModel,
            provider: ScriptedProvider { request, turn in
                turn == 1
                    ? toolResponse(request, [otherCall])
                    : textResponse(request, "Done")
            },
            tools: [try MutationTool(probe: otherProbe)]
        )
        let result = try await otherAgent.makeSession(id: sessionB, journal: journal).run("Update a disjoint listing").wait()
        XCTAssertEqual(result.outcome, .completed)
        let otherCount = await otherProbe.count
        XCTAssertEqual(otherCount, 1)
        let remaining = await journal.pendingMutations()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].sessionID, sessionA)
    }

    func testExplicitlyReusedSessionIDCannotRunConcurrently() async throws {
        let gate = ManualGate()
        let entered = expectation(description: "first session entered")
        let provider = ScriptedProvider { request, _ in
            entered.fulfill()
            await gate.wait()
            return textResponse(request, "Done")
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let sessionID = UUID()
        let first = try agent.makeSession(id: sessionID)
        let second = try agent.makeSession(id: sessionID)
        let run = try await first.run("first")
        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(enteredResult, .completed)

        do {
            _ = try await second.run("second")
            XCTFail("Sessions with the same identity must not run concurrently")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .runInProgress)
        }
        await gate.open()
        _ = try await run.wait()
    }

    func testPendingIdempotencyKeyConflictsAcrossSessionsInOneJournalDomain() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let firstSession = UUID()
        let secondSession = UUID()
        let sharedKey = "shared-operation"
        let first = mutationRequest(sessionID: firstSession, runID: UUID(), callID: .init(rawValue: "first"))
        let second = ToolMutationAdmissionRequest(
            sessionID: secondSession,
            runID: UUID(),
            callID: .init(rawValue: "second"),
            name: first.name,
            argumentsJSON: first.argumentsJSON,
            resources: first.resources,
            idempotencyKey: sharedKey,
            receiptExpectation: first.receiptExpectation
        )
        let firstWithSharedKey = ToolMutationAdmissionRequest(
            sessionID: first.sessionID,
            runID: first.runID,
            callID: first.callID,
            name: first.name,
            argumentsJSON: first.argumentsJSON,
            resources: first.resources,
            idempotencyKey: sharedKey,
            receiptExpectation: first.receiptExpectation
        )

        try await journal.admit(firstWithSharedKey)
        do {
            try await journal.admit(second)
            XCTFail("A pending logical mutation must be exclusive across the journal domain")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .mutationPending)
        }
        let pending = await journal.pendingMutations()
        XCTAssertEqual(pending.count, 1)
    }

    func testSettledMutationReplaysAfterSessionRestartWithSameOperationID() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let probe = MutationProbe()
        let tool = try MutationTool(probe: probe, journalURL: url)
        let provider = ScriptedProvider { request, turn in
            let call = ToolCall(
                id: .init(rawValue: turn == 1 ? "call-1" : "call-2"),
                name: MutationTool.name,
                argumentsJSON: #"{"id":"listing-1"}"#,
                completeness: .complete
            )
            return turn.isMultiple(of: 2) ? textResponse(request, "Done") : toolResponse(request, [call])
        }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])
        let sessionID = UUID()
        let operationID = "queue-operation-1"

        let first = try agent.makeSession(id: sessionID, journal: journal)
        let firstRun = try await first.run("Update the listing", operationID: operationID)
        _ = try await firstRun.wait()
        try await firstRun.waitForDrain()
        let firstCount = await probe.count
        XCTAssertEqual(firstCount, 1)

        let restartedJournal = try AgentJournal.load(from: url)
        let restarted = try agent.makeSession(id: sessionID, journal: restartedJournal)
        let retry = try await restarted.run("Update the listing", operationID: operationID).wait()
        let secondCount = await probe.count
        XCTAssertEqual(secondCount, 1)
        XCTAssertEqual(retry.receipts.first?.callID, .init(rawValue: "call-2"))
    }

    func testSessionRestartRestoresCanonicalHistoryBeforeNextRun() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let provider = ScriptedProvider { request, _ in
            textResponse(request, "ack")
        }
        let agent = try Agent(model: fixtureModel, provider: provider, instructions: "Be concise.")
        let sessionID = UUID()

        let first = try agent.makeSession(id: sessionID, journal: journal)
        let firstRun = try await first.run("first request")
        _ = try await firstRun.wait()
        await first.waitForRunToDrain(runID: firstRun.id)

        let restartedJournal = try AgentJournal.load(from: url)
        let restarted = try agent.makeSession(id: sessionID, journal: restartedJournal)
        _ = try await restarted.run("second request").wait()

        let requests = await provider.log.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].messages.contains(.user([.text("first request")])) )
        XCTAssertTrue(requests[1].messages.contains(.assistant(content: [.text("ack")], toolCalls: [])))
        XCTAssertTrue(requests[1].messages.contains(.user([.text("second request")])) )
    }

    func testDurableSessionLeaseIsExclusiveAcrossJournalInstances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-session-lease-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("journal.log")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try AgentJournal(persistenceURL: url)
        let second = try AgentJournal(persistenceURL: url)
        let sessionID = UUID()
        try await first.acquireSessionLease(sessionID: sessionID)

        do {
            try await second.acquireSessionLease(sessionID: sessionID)
            XCTFail("A durable session lease must reject a concurrent owner")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .sessionLeaseUnavailable)
        }

        await first.releaseSessionLease(sessionID: sessionID)
        try await second.acquireSessionLease(sessionID: sessionID)
        await second.releaseSessionLease(sessionID: sessionID)
    }

    func testSessionAcquiresAndReleasesDurableLease() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-session-integration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("journal.log")
        defer { try? FileManager.default.removeItem(at: directory) }

        let owner = try AgentJournal(persistenceURL: url)
        let sessionJournal = try AgentJournal(persistenceURL: url)
        let sessionID = UUID()
        try await owner.acquireSessionLease(sessionID: sessionID)

        let provider = ScriptedProvider { request, _ in textResponse(request, "Done") }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let session = try agent.makeSession(id: sessionID, journal: sessionJournal)

        do {
            _ = try await session.run("blocked")
            XCTFail("A session must reject a durable lease owned by another journal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .runInProgress)
        }

        await owner.releaseSessionLease(sessionID: sessionID)
        let run = try await session.run("allowed")
        _ = try await run.wait()
        try await run.waitForDrain()

        let verifier = try AgentJournal(persistenceURL: url)
        try await verifier.acquireSessionLease(sessionID: sessionID)
        await verifier.releaseSessionLease(sessionID: sessionID)
    }

    private func mutationRequest(
        sessionID: UUID,
        runID: UUID,
        callID: ToolCallID,
        listing: String = "listing-1",
        idempotencyKey: String? = nil
    ) -> ToolMutationAdmissionRequest {
        ToolMutationAdmissionRequest(
            sessionID: sessionID,
            runID: runID,
            callID: callID,
            name: MutationTool.name,
            argumentsJSON: #"{"id":"\#(listing)"}"#,
            resources: [.named(.init(namespace: "property.listing", id: listing))],
            idempotencyKey: idempotencyKey ?? "\(runID.uuidString)/\(callID.rawValue)",
            receiptExpectation: try? ToolReceiptExpectation(
                targets: [.init(namespace: "property.listing", id: listing)], revision: .present
            )
        )
    }

    private func validReceipt(operationID: String, listing: String = "listing-1") -> ToolReceipt {
        ToolReceipt(operationID: operationID, status: .succeeded,
                    confirmedTargets: [.init(namespace: "property.listing", id: listing)], revision: "v2")
    }

    private func mutationCall(id: String = "call-1", listing: String = "listing-1") -> ToolCall {
        .init(id: .init(rawValue: id), name: MutationTool.name,
              argumentsJSON: #"{"id":"\#(listing)"}"#, completeness: .complete)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("swift-agent-mutation-\(UUID().uuidString).log")
    }

    private func cleanup(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let lockPath = url.path + ".lock"
        if FileManager.default.fileExists(atPath: lockPath) {
            try? FileManager.default.removeItem(atPath: lockPath)
        }
    }
}

private actor MutationProbe {
    private(set) var count = 0
    private(set) var authorizationCount = 0
    private(set) var sawDurableIntent = false

    func markAuthorized() {
        authorizationCount += 1
    }

    func record(journalURL: URL?, context: ToolContext) async {
        count += 1
        guard let journalURL, let journal = try? AgentJournal.load(from: journalURL) else { return }
        let events = await journal.snapshot().map(\.event)
        sawDurableIntent = events.contains {
            if case .pendingMutation(let intent) = $0 {
                return intent.call.id == context.callID
            }
            return false
        }
    }
}

private struct NoopMutationAdmission: ToolMutationAdmission {
    func admit(_ request: ToolMutationAdmissionRequest) async throws -> ToolMutationAdmissionResult { .admitted }
}

private struct MutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }

    static let name = "update_listing"
    static let description = "Update a property listing"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])

    let probe: MutationProbe
    let journalURL: URL?
    let receiptOperationID: String?
    let entered: XCTestExpectation?
    let onAuthorize: (@Sendable () async throws -> Void)?
    let policy: ToolPolicy

    init(
        probe: MutationProbe,
        journalURL: URL? = nil,
        receiptOperationID: String? = nil,
        entered: XCTestExpectation? = nil,
        onAuthorize: (@Sendable () async throws -> Void)? = nil
    ) throws {
        self.probe = probe
        self.journalURL = journalURL
        self.receiptOperationID = receiptOperationID
        self.entered = entered
        self.onAuthorize = onAuthorize
        policy = try ToolPolicy(
            effect: .mutation,
            execution: .exclusive,
            idempotency: .requiresReceipt,
            timeout: .seconds(2),
            authorization: onAuthorize == nil ? .notRequired : .required
        )
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        try await onAuthorize?()
        return .allowed
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "property.listing", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "property.listing", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        entered?.fulfill()
        await probe.record(journalURL: journalURL, context: context)
        let receipt = ToolReceipt(operationID: receiptOperationID ?? context.idempotencyKey ?? "missing", status: .succeeded,
                                  confirmedTargets: [.init(namespace: "property.listing", id: input.id)], revision: "v2")
        return ToolResult(output: .init(updated: true), receipt: receipt)
    }
}

private struct LegacyJournalFrame: Codable {
    let schemaVersion: Int
    let records: [LegacyJournalRecord]
}

private struct LegacyJournalRecord: Codable {
    let id: UUID
    let sequence: UInt64
    let timestamp: Date
    let schemaVersion: Int
    let sessionID: UUID
    let runID: UUID?
    let checkpointID: UUID
    let event: AgentJournalEvent

    init(sequence: UInt64, timestamp: Date, sessionID: UUID, runID: UUID?, checkpointID: UUID,
         event: AgentJournalEvent) {
        id = UUID()
        self.sequence = sequence
        self.timestamp = timestamp
        schemaVersion = 1
        self.sessionID = sessionID
        self.runID = runID
        self.checkpointID = checkpointID
        self.event = event
    }
}

private enum LegacyJournalFrameCodec {
    static func frame(_ payload: Data) -> Data {
        var frame = Data()
        frame.append(contentsOf: bytes(UInt32(payload.count)))
        frame.append(contentsOf: bytes(crc32(payload)))
        frame.append(payload)
        return frame
    }

    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
         UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xffffffff
        for byte in data {
            checksum ^= UInt32(byte)
            for _ in 0..<8 {
                checksum = (checksum & 1) == 0 ? checksum >> 1 : (checksum >> 1) ^ 0xedb88320
            }
        }
        return checksum ^ 0xffffffff
    }
}

private func blockingMutationCall() -> ToolCall {
    .init(id: .init(rawValue: "blocking-call"), name: BlockingMutationTool.name,
          argumentsJSON: "{}", completeness: .complete)
}

private struct BlockingMutationTool: AgentTool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable { let changed: Bool }

    static let name = "blocking_update"
    static let description = "Update a property listing after an external confirmation"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.object(properties: ["changed": .boolean], required: ["changed"])

    let gate: ManualGate
    let entered: XCTestExpectation
    let probe: MutationProbe?
    let policy: ToolPolicy

    init(
        gate: ManualGate,
        entered: XCTestExpectation,
        timeout: Duration = .seconds(2),
        probe: MutationProbe? = nil
    ) throws {
        self.gate = gate
        self.entered = entered
        self.probe = probe
        policy = try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
                                timeout: timeout, authorization: .notRequired)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "property.listing", id: "listing-1"))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "property.listing", id: "listing-1")], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        if let probe {
            await probe.record(journalURL: nil, context: context)
        }
        entered.fulfill()
        await gate.wait()
        let receipt = ToolReceipt(operationID: context.idempotencyKey ?? "missing", status: .succeeded,
                                  confirmedTargets: [.init(namespace: "property.listing", id: "listing-1")], revision: "v2")
        return ToolResult(output: .init(changed: true), receipt: receipt)
    }
}
