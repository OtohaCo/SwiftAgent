import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

struct AuditFailureRecoveryTests {
    @Test(arguments: [false, true])
    func failureAuditCannotShortCircuitRecovery(_ commitUnknown: Bool) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let effect = directory.appendingPathComponent("effect.txt")
        let fault = FailureAuditFault(commitUnknown: commitUnknown)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "failure-audit",
            supportsAuthorizationAudit: true, fault: { try fault.check($0) })
        let counter = FailureEffectCounter()
        let provider = ScriptedProvider { request, _ in
            toolResponse(request, [.init(id: .init(rawValue: "effect-then-error"), name: FailureAuditFileTool.name,
                argumentsJSON: #"{"id":"A"}"#, completeness: .complete)])
        }
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [FailureAuditFileTool(file: effect, fault: fault, counter: counter)],
            configuration: .init(authorization: auditTestConfiguration())).makeSession(journal: journal)
        let run = try await session.run("write once", operationID: "failure-effect")
        let events = Task { var values: [AgentEvent] = []; for await event in run.events { values.append(event) }; return values }
        let failure: AgentFailure
        do { _ = try await run.wait(); Issue.record("effect error must fail"); return }
        catch { failure = AgentFailure(error) }
        try await run.waitForDrain()
        let auditFailure = AgentAuditPersistenceError(
            original: .toolInvocation(.authorizationDenied),
            audit: .journal(commitUnknown ? .commitUnknown : .persistenceUnavailable("controlled failure audit")))
        if commitUnknown {
            #expect(failure == .mutationPersistence(.init(
                settlement: .auditPersistence(auditFailure), quarantine: .journal(.commitUnknown))))
        } else {
            #expect(failure == .auditPersistence(auditFailure))
        }
        #expect(await counter.entered == 1)
        #expect(try String(contentsOf: effect, encoding: .utf8) == "effect\n")
        let observed = await events.value
        #expect(observed.contains { if case .toolFailed(_, let value) = $0 { return value == failure }; return false })
        if !commitUnknown {
            #expect(try await journal.pendingMutations().map(\.state) == [.needsReconciliation])
            // A definite noncommit leaves the store writable but does not permit blind replay.
            let retry = try await session.run("retry", operationID: "failure-effect")
            await #expect(throws: AgentJournalError.mutationRequiresReconciliation) { try await retry.wait() }
            try await retry.waitForDrain()
            #expect(await counter.entered == 1)
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let pending = try await reopened.pendingMutations()
        #expect(pending.map(\.state) == [commitUnknown ? .intent : .needsReconciliation])
        #expect(try await reopened.recoverPendingMutations().map(\.state) == [.needsReconciliation])
        #expect(await counter.entered == 1)
        try await reopened.close()
    }
}

private final class FailureAuditFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let commitUnknown: Bool
    init(commitUnknown: Bool) { self.commitUnknown = commitUnknown }
    func arm() { lock.withLock { armed = true } }
    func check(_ stage: JournalFileFaultStage) throws {
        let eligible: Bool
        if commitUnknown { if case .afterCurrentReplace = stage { eligible = true } else { eligible = false } }
        else { if case .beforeAppend = stage { eligible = true } else { eligible = false } }
        if eligible && lock.withLock({ let v = armed; armed = false; return v }) {
            throw AgentJournalError.persistenceUnavailable("controlled failure audit")
        }
    }
}
private actor FailureEffectCounter { private(set) var entered = 0; func enter() { entered += 1 } }
private struct FailureAuditFileTool: AgentTool {
    typealias Input = AuditExecutionTool.Input
    typealias Output = String
    static let name = "failure_audit_file", description = "Controlled file effect then typed error"
    static let inputSchema = AuditExecutionTool.inputSchema, outputSchema = ToolSchema.string
    let policy = try! ToolPolicy.mutation(authorization: .notRequired, evidence: .none)
    let file: URL; let fault: FailureAuditFault; let counter: FailureEffectCounter
    func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "audit.fixture", id: input.id))] }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "audit.fixture", id: input.id)], revision: .present) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        await counter.enter()
        try Data("effect\n".utf8).write(to: file)
        fault.arm()
        throw ToolInvocationError.authorizationDenied
    }
}
