import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest
@testable import AgentCore

struct ConfirmedNoEffectFaultTests {
    @Test(arguments: [false, true])
    func publicationFailureOrUnknownNeverContinuesOrExposesHalfAFact(_ unknown: Bool) async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fault = NoEffectPublicationFault(unknown: unknown)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "no-effect-fault",
            supportsConfirmedNoEffect: true, fault: { try fault.check($0) })
        let counts = NoEffectCounts()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [noEffectCall("A")]) }
        let tool = try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts,
                                      beforeReturn: { fault.arm() })
        let session = try Agent(model: fixtureModel, provider: provider, tools: [tool],
            configuration: .init(authorization: auditTestConfiguration())).makeSession(journal: journal)
        let run = try await session.run("write", operationID: "same")
        await #expect(throws: (any Error).self) { try await run.wait() }; try await run.waitForDrain()
        #expect(await provider.log.requests.count == 1); #expect(await counts.effects == 0); #expect(await counts.executions == 1)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let proof = try await reopened.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A"))
        let history = try await reopened.latestCheckpoint(sessionID: session.id)?.history ?? []
        let error = history.contains { if case .tool(let r) = $0 { return r.isError && r.callID.rawValue == "A" }; return false }
        let page = try await reopened.auditRecords(matching: .init(runID: run.id))
        let reference = page.records.contains { if case .result(let r) = $0.fact { return r.kind == .noEffectConfirmation && r.settlementSource == .executor }; return false }
        #expect((proof != nil) == unknown); #expect(error == unknown); #expect(reference == unknown)
        #expect(try await reopened.pendingMutations().map(\.state) == (unknown ? [] : [.needsReconciliation]))
        try await reopened.close()
    }

    @Test func cancelledLateProofDoesNotReleaseTheOwnerOrStartAnotherTurn() async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "late", supportsConfirmedNoEffect: true)
        let gate = NoEffectReturnGate(); let counts = NoEffectCounts()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [noEffectCall("A")]) }
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts,
                beforeReturn: { await gate.enterAndWait() })]).makeSession(journal: journal)
        let run = try await session.run("write")
        try await gate.waitUntilEntered(); await run.cancel()
        await #expect(throws: (any Error).self) { try await session.run("must not overlap") }
        #expect(await counts.effects == 0); #expect(await provider.log.requests.count == 1)
        await gate.release()
        await #expect(throws: (any Error).self) { try await run.wait() }; try await run.waitForDrain()
        #expect(await provider.log.requests.count == 1)
        #expect(try await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")) == nil)
        #expect(try await journal.pendingMutations().map(\.state) == [.needsReconciliation])
        try await journal.close()
    }
    @Test(arguments: ["deadline", "revoke"])
    func lateProofCannotContinuePastDeadlineOrScopeRevoke(_ stop: String) async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "stopped", supportsConfirmedNoEffect: true)
        let gate = NoEffectReturnGate(), counts = NoEffectCounts()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [noEffectCall("A")]) }
        let tool = try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts,
            beforeReturn: { await gate.enterAndWait() })
        let session = try Agent(model: fixtureModel, provider: provider, tools: []).makeSession(journal: journal)
        let scope = try await session.bindCapabilities(identity: "controlled", version: "1", backendInstanceID: "fixture-backend",
            backendVersion: "1", allowedResources: [.global], tools: [.init(id: "write", version: "1", tool: tool)])
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let run = try await session.run("write", capabilities: scope,
            budget: AgentBudget(maxModelTurns: 4, maxToolCalls: 4, deadline: stop == "deadline" ? deadline : .now.advanced(by: .seconds(30))))
        try await gate.waitUntilEntered()
        if stop == "revoke" { await scope.revoke() }
        else { try await ContinuousClock().sleep(until: deadline) } // Absolute budget trigger, never stage hunting.
        #expect(await scope.status().activeRuns == 1)
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        await gate.release()
        await #expect(throws: (any Error).self) { try await run.wait() }; try await run.waitForDrain(); try await scope.waitForDrain()
        #expect(await scope.status().activeRuns == 0)
        #expect(await provider.log.requests.count == 1); #expect(await counts.effects == 0)
        #expect(try await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")) == nil)
        #expect(try await journal.pendingMutations().map(\.state) == [.needsReconciliation])
        try await journal.close()
    }

    @Test func auditAndQuarantineFailuresRemainObservableAndIntentRemainsRecoverable() async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fault = NoEffectPublicationFault(unknown: false, failures: 3)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "combined-errors",
            supportsConfirmedNoEffect: true, fault: { try fault.check($0) })
        let counts = NoEffectCounts(), provider = ScriptedProvider { request, _ in toolResponse(request, [noEffectCall("A")]) }
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts, beforeReturn: { fault.arm() })],
            configuration: .init(authorization: auditTestConfiguration())).makeSession(journal: journal)
        let run = try await session.run("write")
        let failure: AgentFailure
        do { _ = try await run.wait(); Issue.record("combined failure must remain closed"); return }
        catch { failure = AgentFailure(error) }
        try await run.waitForDrain()
        guard case .mutationPersistence(let mutation) = failure else { Issue.record("missing quarantine failure: \(failure)"); return }
        guard case .auditPersistence(let audit) = mutation.settlement else { Issue.record("missing audit failure"); return }
        #expect(audit.original == .journal(.persistenceUnavailable("controlled no-effect publication failure")))
        #expect(audit.audit == .journal(.persistenceUnavailable("controlled no-effect publication failure")))
        #expect(mutation.quarantine == .journal(.persistenceUnavailable("controlled no-effect publication failure")))
        #expect(fault.failuresObserved == 3)
        // Failed quarantine is not reported as durable success. The original intent remains
        // closed to replay until the existing recovery API can reliably quarantine it.
        #expect(try await journal.pendingMutations().map(\.state) == [.intent])
        #expect(try await journal.recoverPendingMutations().map(\.state) == [.needsReconciliation])
        #expect(try await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")) == nil)
        #expect(await counts.effects == 0); #expect(await provider.log.requests.count == 1)
        try await journal.close()
    }

}
final class NoEffectPublicationFault: @unchecked Sendable {
    private let lock = NSLock(); private var remaining = 0; private var failed = 0
    let unknown: Bool; let failures: Int
    var failuresObserved: Int { lock.withLock { failed } }
    init(unknown: Bool, failures: Int = 1) { self.unknown = unknown; self.failures = failures }
    func arm() { lock.withLock { remaining = failures } }
    func check(_ stage: JournalFileFaultStage) throws {
        let eligible: Bool
        if unknown { if case .afterCurrentReplace = stage { eligible = true } else { eligible = false } }
        else { if case .beforeAppend = stage { eligible = true } else { eligible = false } }
        if eligible && lock.withLock({ guard remaining > 0 else { return false }; remaining -= 1; failed += 1; return true }) {
            throw AgentJournalError.persistenceUnavailable("controlled no-effect publication failure")
        }
    }
}
actor NoEffectReturnGate {
    private var entered = false; private var released = false
    private let entrance = XCTestExpectation(description: "actual executor entered")
    private var exits: [CheckedContinuation<Void, Never>] = []
    func enterAndWait() async {
        entered = true; entrance.fulfill()
        if !released { await withCheckedContinuation { exits.append($0) } }
    }
    func waitUntilEntered() async throws {
        guard await XCTWaiter.fulfillment(of: [entrance], timeout: 10) == .completed else { throw ToolNoEffectError.unavailable }
    }
    func release() { released = true; exits.forEach { $0.resume() }; exits.removeAll() }
}
