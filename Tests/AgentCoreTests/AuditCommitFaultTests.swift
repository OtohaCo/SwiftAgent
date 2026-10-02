import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

struct AuditCommitFaultTests {
    @Test(arguments: ["proposal", "decision", "application", "settlement"], [false, true])
    func failedPublicationNeverGrantsPermissionOrRepeatsAnEffect(_ point: String, runRecords: Bool) async throws {
        for uncertain in [false, true] {
            let directory = auditTestDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fault = AuditRuntimePublicationFault(uncertain: uncertain)
            let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "audit-fault",
                supportsAuthorizationAudit: true, supportsRunRecords: runRecords, fault: { try fault.check($0) })
            let probe = AuditExecutionProbe(), hostCalls = AuditFaultCounter()
            var configuration = auditTestConfiguration(authorizer: FaultAuditAuthorizer(point: point, fault: fault, calls: hostCalls))
            if point == "application" { configuration.testingHooks = .init(beforeApplication: { fault.arm() }) }
            let provider = ScriptedProvider { request, _ in
                if point == "proposal" { fault.arm() }
                return toolResponse(request, [.init(id: .init(rawValue: "fault"), name: AuditFaultTool.name,
                    argumentsJSON: #"{"id":"A"}"#, completeness: .complete)])
            }
            let run = try await Agent(model: fixtureModel, provider: provider,
                tools: [AuditFaultTool(point: point, fault: fault, probe: probe)],
                configuration: .init(authorization: configuration)).makeSession(journal: journal).run("write", operationID: "fault-once")
            await #expect(throws: (any Error).self) { try await run.wait() }
            try await run.waitForDrain()
            #expect(await hostCalls.value == (point == "proposal" ? 0 : 1))
            #expect(await probe.executorEntered == (point == "settlement" ? 1 : 0))
            #expect(await probe.effects == (point == "settlement" ? 1 : 0))
            try await journal.close()
            let reopened = try AgentIncrementalJournal.open(at: directory)
            if runRecords {
                let lookup = try await reopened.runRecord(sessionID: run.sessionID, runID: run.id)
                if uncertain { guard case .admitted = lookup else { Issue.record("poisoned audit forged terminal"); return } }
                else { guard case .terminal(_, .failed) = lookup else { Issue.record("audit failure lost terminal distinction"); return } }
            }
            let records = try await reopened.auditRecords(matching: .init(runID: run.id)).records
            let applied = records.contains { if case .disposition(let value) = $0.fact { return value.state == .dispatchPrepared }; return false }
            let result = records.contains { if case .result(let value) = $0.fact { return value.kind == .settlement }; return false }
            if point == "proposal" || point == "decision" { #expect(!applied) }
            if point == "application" { #expect(applied == uncertain) }
            if point == "settlement" { #expect(applied); #expect(result == uncertain) }
            let pending = try await reopened.recoverPendingMutations()
            #expect(pending.count == ((point == "application" && uncertain) || (point == "settlement" && !uncertain) ? 1 : 0))
            // No recovery code calls execute. A settled root links its authoritative result atomically;
            // an unsettled root retains the original intent for existing reconciliation.
            #expect(await probe.effects == (point == "settlement" ? 1 : 0))
            try await reopened.close()
        }
    }
}

private actor AuditFaultCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class AuditRuntimePublicationFault: @unchecked Sendable {
    let uncertain: Bool
    private let lock = NSLock()
    private var armed = false
    init(uncertain: Bool) { self.uncertain = uncertain }
    func arm() { lock.withLock { armed = true } }
    func check(_ stage: JournalFileFaultStage) throws {
        let eligible: Bool
        if uncertain { if case .afterCurrentReplace = stage { eligible = true } else { eligible = false } }
        else { if case .beforeAppend = stage { eligible = true } else { eligible = false } }
        guard eligible else { return }
        if lock.withLock({ let value = armed; armed = false; return value }) {
            throw AgentJournalError.persistenceUnavailable("controlled audit publication failure")
        }
    }
}

private struct FaultAuditAuthorizer: AgentAuthorizer {
    let point: String; let fault: AuditRuntimePublicationFault; let calls: AuditFaultCounter
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        await calls.increment()
        if point == "decision" { fault.arm() }
        return .init(request: request, outcome: .allow, subject: .init(issuer: "fixture", subjectID: "rule", type: .automatedPolicy),
            policy: .init(id: "fault", version: "1"), validFor: .seconds(30), reasonCode: "fixture")
    }
}

private struct AuditFaultTool: AgentTool {
    typealias Input = AuditExecutionTool.Input
    typealias Output = String
    static let name = "audit_fault", description = "Controlled fault mutation"
    static let inputSchema = AuditExecutionTool.inputSchema, outputSchema = ToolSchema.string
    let policy = try! ToolPolicy.mutation(authorization: .notRequired, evidence: .none)
    let point: String; let fault: AuditRuntimePublicationFault; let probe: AuditExecutionProbe
    func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "audit.fixture", id: input.id))] }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "audit.fixture", id: input.id)], revision: .present) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        let receipt = await probe.execute(context, id: input.id)
        if point == "settlement" { fault.arm() }
        return .init(output: "written", receipt: receipt)
    }
}
