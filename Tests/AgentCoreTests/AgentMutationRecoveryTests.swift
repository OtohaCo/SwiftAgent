@testable import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

final class AgentMutationRecoveryTests: XCTestCase {
    func testIntentIsDurableBeforeExecutorAndTrustedSettlementIncludesConversation() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let probe = RecoveryMutationProbe()
        let tool = try RecoveryMutationTool(journal: journal, probe: probe)
        let call = ToolCall(id: .init(rawValue: "write-1"), name: RecoveryMutationTool.name,
                            argumentsJSON: #"{"id":"listing-1"}"#, completeness: .complete)
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "done")
        }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])
        let sessionID = UUID()
        let run = try await agent.makeSession(id: sessionID, journal: journal).run("Update", operationID: "logical-write")
        let result = try await run.wait()
        try await run.waitForDrain()
        #expect(await probe.count == 1)
        #expect(await probe.sawDurableIntent)
        XCTAssertEqual(result.receipts.count, 1)
        #expect(try await journal.pendingMutations().isEmpty)
        let key = try XCTUnwrap(result.receipts.first?.receipt.operationID)
        let status = try #require(try await journal.mutationStatus(identity: key))
        XCTAssertEqual(status.state, .settled)
        XCTAssertEqual(status.receipt, result.receipts.first?.receipt)
        XCTAssertNotNil(status.replayOutput)
        let messages = try await journal.readMessages(sessionID: sessionID, limit: 100).map(\.message)
        XCTAssertTrue(messages.contains { if case .tool(let value) = $0 { return value.callID == call.id }; return false })
        try await journal.close()
        let reopened = try openTestJournal(at: url)
        #expect(try await reopened.mutationStatus(identity: key) == status)
        #expect(try await reopened.readMessages(sessionID: sessionID, limit: 100).map(\.message) == messages)
        try await reopened.close()
    }

    func testMutationRequiresDurableJournalBeforeModelOrExecutor() throws {
        let probe = RecoveryMutationProbe()
        let agent = try Agent(model: fixtureModel,
                              provider: ScriptedProvider { request, _ in textResponse(request, "unused") },
                              tools: [RecoveryMutationTool(journal: nil, probe: probe)])
        XCTAssertThrowsError(try agent.makeSession()) { XCTAssertEqual($0 as? AgentSessionError, .durableJournalRequired) }
        XCTAssertThrowsError(try agent.makeSession(journal: AgentJournal())) {
            XCTAssertEqual($0 as? AgentSessionError, .durableJournalRequired)
        }
    }

    func testRecoveryQuarantinesIntentAndNeverAutomaticallyExecutes() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try makeTestJournal(at: url)
        let session = UUID(), run = UUID()
        let request = try mutationRequest(session: session, run: run, call: "original", key: "operation-1")
        guard case .admitted = try await first.admit(request) else { return XCTFail("admission expected") }
        try await first.close()

        let reopened = try openTestJournal(at: url)
        let pending = try await reopened.recoverPendingMutations(sessionID: session)
        XCTAssertEqual(pending.map(\.state), [.needsReconciliation])
        do {
            _ = try await reopened.admit(try mutationRequest(session: UUID(), run: UUID(), call: "retry", key: "operation-1"))
            XCTFail("unknown external outcome must block retry")
        } catch { XCTAssertEqual(error as? AgentJournalError, .mutationRequiresReconciliation) }
        let receipt = validReceipt(key: "operation-1")
        try await reopened.reconcileMutation(try XCTUnwrap(pending.first), receipt: receipt,
                                              output: .object(["updated": .bool(true)]))
        #expect(try await reopened.pendingMutations().isEmpty)
        let replay = try await reopened.admit(try mutationRequest(session: UUID(), run: UUID(), call: "retry", key: "operation-1"))
        guard case .settled(let replayed, let output) = replay else { return XCTFail("settled replay expected") }
        XCTAssertEqual(replayed, receipt)
        XCTAssertEqual(output, .object(["updated": .bool(true)]))
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history.contains {
            if case .tool(let value) = $0 { return value.callID == request.callID }; return false
        } == true)
        let canonical = try #require(try await reopened.latestCheckpoint(sessionID: session)?.history)
        XCTAssertTrue(canonical.contains {
            if case .assistant(_, let calls) = $0 { return calls.contains { $0.id == request.callID } }
            return false
        })
        try await reopened.close()
    }

    func testReceiptMismatchLeavesDurableIntentUnsettled() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let session = UUID(), run = UUID()
        let request = try mutationRequest(session: session, run: run, call: "receipt", key: "operation-2")
        _ = try await journal.admit(request)
        do {
            try await journal.commitMutation(sessionID: session, runID: run, callID: request.callID,
                                              receipt: validReceipt(key: "wrong-key"),
                                              output: .bool(true), history: [.user([.text("hello")])], steeringIDs: [])
            XCTFail("wrong receipt must not settle")
        } catch { XCTAssertEqual(error as? ToolReceiptError, .operationMismatch) }
        #expect(try await journal.pendingMutations(sessionID: session).map(\.state) == [.intent])
        #expect(try await journal.mutationStatus(identity: "operation-2")?.receipt == nil)
        try await journal.close()
    }

    func testAbortRequiresQuarantineAndExplicitNoEffectConfirmation() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let session = UUID()
        let request = try mutationRequest(session: session, run: UUID(), call: "first", key: "operation-3")
        _ = try await journal.admit(request)
        let confirmation = try AgentNoEffectConfirmation(basis: "verified external transaction was rejected")
        let inFlight = try #require(try await journal.pendingMutations(sessionID: session).first)
        do {
            try await journal.abortMutation(inFlight, confirmedNoEffect: confirmation)
            XCTFail("an in-flight operation cannot be aborted")
        } catch { XCTAssertEqual(error as? AgentJournalError, .mutationRequiresReconciliation) }
        let quarantined = try #require(try await journal.recoverPendingMutations(sessionID: session).first)
        try await journal.abortMutation(quarantined, confirmedNoEffect: confirmation)
        #expect(try await journal.mutationStatus(identity: "operation-3")?.abortConfirmation == confirmation)
        let conflict = ToolMutationAdmissionRequest(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "different"),
                                                     name: "write", argumentsJSON: #"{"id":"other"}"#,
                                                     resources: request.resources, idempotencyKey: request.idempotencyKey,
                                                     receiptExpectation: request.receiptExpectation)
        do { _ = try await journal.admit(conflict); XCTFail("semantic conflict must remain") }
        catch { XCTAssertEqual(error as? AgentJournalError, .mutationIntentConflict) }
        guard case .admitted = try await journal.admit(try mutationRequest(session: UUID(), run: UUID(), call: "new", key: "operation-3"))
        else { return XCTFail("confirmed no-effect permits a matching retry") }
        try await journal.close()
    }

    func testPendingBlocksSameSessionButNotUnrelatedSession() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let session = UUID()
        _ = try await journal.admit(try mutationRequest(session: session, run: UUID(), call: "one", key: "one"))
        do {
            _ = try await journal.admit(try mutationRequest(session: session, run: UUID(), call: "two", key: "two"))
            XCTFail("same Session must be quarantined")
        } catch { XCTAssertEqual(error as? AgentJournalError, .mutationRequiresReconciliation) }
        guard case .admitted = try await journal.admit(try mutationRequest(session: UUID(), run: UUID(), call: "other", key: "other"))
        else { return XCTFail("unrelated Session should continue") }
        try await journal.close()
    }

    func testSameIdentityWithDifferentResourceOrExpectationNeverReusesReceipt() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let first = try mutationRequest(session: UUID(), run: UUID(), call: "original", key: "scoped-key")
        _ = try await journal.admit(first)
        let other = EvidenceReference(namespace: "other-account", id: "listing-1")
        let conflicting = ToolMutationAdmissionRequest(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "retry"),
                                                        name: first.name, argumentsJSON: first.argumentsJSON,
                                                        resources: [.named(other)], idempotencyKey: first.idempotencyKey,
                                                        receiptExpectation: try .init(targets: [other], revision: .present))
        do { _ = try await journal.admit(conflicting); XCTFail("cross-account replay must be rejected") }
        catch { XCTAssertEqual(error as? AgentJournalError, .mutationIntentConflict) }
        #expect(try await journal.pendingMutations().count == 1)
        try await journal.close()
    }

    func testCancellationAfterRealFileEffectKeepsReconciliationAndPhysicalDrain() async throws {
        let url = temporaryURL(), effect = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: effect) }
        try Data().write(to: effect)
        let journal = try makeTestJournal(at: url)
        let gate = ManualGate()
        let entered = expectation(description: "external effect completed")
        let tool = try BlockingRecoveryFileTool(file: effect, gate: gate, entered: entered,
                                                timeout: .seconds(3))
        let call = ToolCall(id: .init(rawValue: "write-file"), name: BlockingRecoveryFileTool.name,
                            argumentsJSON: #"{"id":"listing-1"}"#, completeness: .complete)
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let run = try await session.run("Write once", operationID: "file-side-effect")
        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(enteredResult, .completed)
        XCTAssertEqual(try String(contentsOf: effect, encoding: .utf8), "effect\n")
        await run.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run.wait() }
        #expect(try await journal.pendingMutations(sessionID: sessionID).map(\.state) == [.needsReconciliation])
        let draining = Task { try await run.waitForDrain() }
        #expect(await run.isDrainComplete() == false)
        await gate.open()
        try await draining.value
        try await journal.close()
        let reopened = try openTestJournal(at: url)
        #expect(try await reopened.recoverPendingMutations(sessionID: sessionID).map(\.state) == [.needsReconciliation])
        #expect(try String(contentsOf: effect, encoding: .utf8) == "effect\n")
        try await reopened.close()
    }

    func testTimeoutAfterRealFileEffectDoesNotReplayTheExecutor() async throws {
        let url = temporaryURL(), effect = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: effect) }
        try Data().write(to: effect)
        let journal = try makeTestJournal(at: url)
        let gate = ManualGate()
        let entered = expectation(description: "external effect completed")
        let tool = try BlockingRecoveryFileTool(file: effect, gate: gate, entered: entered,
                                                timeout: .milliseconds(50))
        let call = ToolCall(id: .init(rawValue: "timeout-file"), name: BlockingRecoveryFileTool.name,
                            argumentsJSON: #"{"id":"listing-1"}"#, completeness: .complete)
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [tool])
        let sessionID = UUID()
        let run = try await agent.makeSession(id: sessionID, journal: journal)
            .run("Write once", operationID: "timed-file-effect")
        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(enteredResult, .completed)
        await #expect(throws: AgentLoopError.toolTimedOut(call.id)) { _ = try await run.wait() }
        #expect(try await journal.pendingMutations(sessionID: sessionID).map(\.state) == [.needsReconciliation])
        await gate.open()
        try await run.waitForDrain()
        try await journal.close()
        let reopened = try openTestJournal(at: url)
        #expect(try await reopened.recoverPendingMutations(sessionID: sessionID).map(\.state) == [.needsReconciliation])
        #expect(try String(contentsOf: effect, encoding: .utf8) == "effect\n")
        try await reopened.close()
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mutation-v4-\(UUID().uuidString)")
    }

    private func mutationRequest(session: UUID, run: UUID, call: String, key: String) throws -> ToolMutationAdmissionRequest {
        let target = EvidenceReference(namespace: "property.listing", id: "listing-1")
        return ToolMutationAdmissionRequest(sessionID: session, runID: run, callID: .init(rawValue: call),
                                            name: "write", argumentsJSON: #"{"id":"listing-1"}"#,
                                            resources: [.named(target)], idempotencyKey: key,
                                            receiptExpectation: try .init(targets: [target], revision: .present))
    }

    private func validReceipt(key: String) -> ToolReceipt {
        ToolReceipt(operationID: key, status: .succeeded,
                    confirmedTargets: [.init(namespace: "property.listing", id: "listing-1")], revision: "v2")
    }
}

private actor RecoveryMutationProbe {
    private(set) var count = 0
    private(set) var sawDurableIntent = false
    func record(journal: AgentJournal?, callID: ToolCallID) async {
        count += 1
        guard let journal else { return }
        sawDurableIntent = (try? await journal.pendingMutations().contains {
            $0.intent.call.id == callID && $0.state == .intent
        }) == true
    }
}

private struct RecoveryMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = "write"
    static let description = "Update a fixture listing"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let journal: AgentJournal?
    let probe: RecoveryMutationProbe
    let policy: ToolPolicy

    init(journal: AgentJournal?, probe: RecoveryMutationProbe) throws {
        self.journal = journal
        self.probe = probe
        policy = try .mutation(authorization: .notRequired, evidence: .none)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "property.listing", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "property.listing", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.record(journal: journal, callID: context.callID)
        return ToolResult(output: .init(updated: true),
                          receipt: ToolReceipt(operationID: context.idempotencyKey ?? "",
                                               status: .succeeded,
                                               confirmedTargets: [.init(namespace: "property.listing", id: input.id)],
                                               revision: "v2"))
    }
}

private struct BlockingRecoveryFileTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = "blocking_file_write"
    static let description = "Write a temporary fixture file"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let file: URL
    let gate: ManualGate
    let entered: XCTestExpectation
    let policy: ToolPolicy
    init(file: URL, gate: ManualGate, entered: XCTestExpectation, timeout: Duration) throws {
        self.file = file; self.gate = gate; self.entered = entered
        policy = try .mutation(timeout: timeout, authorization: .notRequired, evidence: .none)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "property.listing", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "property.listing", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("effect\n".utf8))
        try handle.synchronize()
        try handle.close()
        entered.fulfill()
        await gate.wait()
        return ToolResult(output: .init(updated: true),
                          receipt: ToolReceipt(operationID: context.idempotencyKey ?? "",
                                               status: .succeeded,
                                               confirmedTargets: [.init(namespace: "property.listing", id: input.id)],
                                               revision: "v1"))
    }
}
