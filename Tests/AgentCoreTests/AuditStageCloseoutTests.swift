import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

struct AuditStageCloseoutTests {
    @Test(arguments: ["deny", "cancel", "cancel-after-effect", "deadline", "authorizer-timeout", "read-prefix", "mutation-prefix"])
    func preparedButUnscheduledCallsHaveKnownCloseout(_ scenario: String) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "stage-closeout", supportsAuthorizationAudit: true)
        let probe = AuditStageProbe(), entered = AuditGate(), release = AuditGate()
        let authorizer = AuditStageAuthorizer(probe: probe, stop: scenario, entered: entered, release: release)
        let a = try AuditStageTool(name: "stage_a", probe: probe, directory: directory,
            executorEntered: scenario == "cancel-after-effect" ? entered : nil,
            executorRelease: scenario == "cancel-after-effect" ? release : nil)
        let b = try AuditStageTool(name: "stage_b", probe: probe, directory: directory)
        let prefix = try AuditStageTool(name: "stage_prefix", probe: probe, directory: directory, readOnly: scenario == "read-prefix")
        let calls = (scenario.hasSuffix("prefix") ? [stageCall("prefix", name: "stage_prefix")] : [])
            + [stageCall("A", name: "stage_a"), stageCall("B", name: "stage_b")]
        let provider = ScriptedProvider { request, _ in toolResponse(request, calls) }
        var configuration = auditTestConfiguration(authorizer: authorizer)
        if scenario == "authorizer-timeout" { configuration = .init(mode: .requiredAudit, authorizer: authorizer,
            identity: configuration.identity, authorizerTimeout: .seconds(1)) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [a, b, prefix],
            configuration: .init(authorization: configuration)).makeSession(journal: journal)
        let budget = scenario == "deadline" ? try AgentBudget(maxModelTurns: 3, maxToolCalls: 5, deadline: .now.advanced(by: .seconds(1))) : nil
        let run = try await session.run("batch", budget: budget)
        if ["cancel", "cancel-after-effect", "deadline", "authorizer-timeout"].contains(scenario) {
            await entered.wait()
            if scenario == "cancel" || scenario == "cancel-after-effect" { await run.cancel() }
            await #expect(throws: (any Error).self) { try await run.wait() }
            await release.open()
        } else { await #expect(throws: AgentAuthorizationError.authorizationDenied) { try await run.wait() } }
        try await run.waitForDrain()
        let all = try await journal.auditRecords(matching: .init(runID: run.id), includeRestrictedPayload: true).records
        let bFacts = all.filter { $0.links.modelCallID == "B" }
        #expect(bFacts.filter { if case .proposal = $0.fact { return true }; return false }.count == 2)
        #expect(bFacts.contains { if case .authorization(let a) = $0.fact { return a.layer == .enterprise && a.status == .notEvaluated }; return false })
        #expect(bFacts.contains { if case .disposition(let d) = $0.fact { return d.state == .notExecuted && d.reasonCode != nil }; return false })
        #expect(!bFacts.contains { if case .disposition(let d) = $0.fact { return d.state == .dispatchPrepared || d.state == .runtimeAdmitted || d.state == .executorObserved }; return false })
        #expect(!(await probe.authorized).contains("B"))
        #expect(!(await probe.executed).contains("B"))
        #expect(!(await probe.toolAuthorized).contains("B"))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("B.effect").path))
        #expect(try await journal.pendingMutations().allSatisfy { $0.intent.call.id.rawValue != "B" })
        if scenario == "cancel-after-effect" {
            let aFacts = all.filter { $0.links.modelCallID == "A" }
            #expect(aFacts.contains { if case .disposition(let d) = $0.fact { return d.state == .executorObserved }; return false })
            #expect(aFacts.contains { if case .disposition(let d) = $0.fact { return d.state == .uncertain }; return false })
            #expect(!aFacts.contains { if case .disposition(let d) = $0.fact { return d.state == .notExecuted }; return false })
            #expect(try await journal.pendingMutations().first?.state == .needsReconciliation)
            #expect(try String(contentsOf: directory.appendingPathComponent("A.effect"), encoding: .utf8) == "effect")
        }
        if scenario.hasSuffix("prefix") {
            let prefixFacts = all.filter { $0.links.modelCallID == "prefix" }
            #expect(prefixFacts.contains { if case .result = $0.fact { return true }; return false })
            #expect(!prefixFacts.contains { if case .disposition(let d) = $0.fact { return d.state == .notExecuted }; return false })
            let history = await session.history
            #expect(history.filter { $0.role == .tool }.count == 1)
            #expect(history.flatMap { message -> [ToolCall] in if case .assistant(_, let calls) = message { return calls }; return [] }.map(\.id.rawValue) == ["prefix"])
            if scenario == "mutation-prefix" {
                #expect(prefixFacts.contains { if case .result(let r) = $0.fact { return r.kind == .settlement && r.receipt != nil }; return false })
                #expect(try String(contentsOf: directory.appendingPathComponent("prefix.effect"), encoding: .utf8) == "effect")
            }
        }
        try await journal.close()
    }

    @Test(arguments: ["runtime-evidence", "enterprise-deny", "enterprise-evidence", "enterprise-authorization", "tool-evidence", "tool-authorization", "executor-evidence", "executor-authorization"])
    func publicErrorTypesCannotImpersonateAnotherPhase(_ origin: String) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "stage-source", supportsAuthorizationAudit: true)
        let probe = AuditStageProbe()
        let authorizer = AuditStageAuthorizer(probe: probe, stop: origin)
        let tool = try AuditStageTool(name: "stage_a", probe: probe, directory: directory,
            callbackError: origin, evidence: origin == "runtime-evidence")
        let provider = ScriptedProvider { request, _ in toolResponse(request, [stageCall("A", name: "stage_a")]) }
        let run = try await Agent(model: fixtureModel, provider: provider, tools: [tool],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal).run("write")
        await #expect(throws: (any Error).self) { try await run.wait() }
        try await run.waitForDrain()
        let facts = try await journal.auditRecords(matching: .init(runID: run.id)).records
        let reasons = facts.compactMap { record -> String? in
            if case .disposition(let d) = record.fact { return d.reasonCode }; return nil
        }
        let expected: String
        if origin == "runtime-evidence" { expected = "runtime_evidence_rejected" }
        else if origin == "enterprise-deny" { expected = "host_denied" }
        else if origin.hasPrefix("enterprise") { expected = "authorizer_error" }
        else if origin.hasPrefix("tool") { expected = "tool_authorization_failed" }
        else { expected = "executor_failed" }
        #expect(reasons.contains(expected))
        #expect(reasons.allSatisfy { !$0.contains("private-secret") })
        if origin != "runtime-evidence" { #expect(!reasons.contains("runtime_evidence_rejected")) }
        if origin != "enterprise-deny" { #expect(!reasons.contains("host_denied")) }
        #expect(await probe.authorized.count == (origin == "runtime-evidence" ? 0 : 1))
        #expect(await probe.executed.count == (origin.hasPrefix("executor") ? 1 : 0))
        if origin.hasPrefix("executor") {
            #expect(try String(contentsOf: directory.appendingPathComponent("A.effect"), encoding: .utf8) == "effect")
            #expect(try await journal.pendingMutations().first?.state == .needsReconciliation)
            #expect(facts.contains { if case .disposition(let d) = $0.fact { return d.state == .executorObserved }; return false })
            #expect(facts.contains { if case .disposition(let d) = $0.fact { return d.state == .uncertain }; return false })
            #expect(!facts.contains { if case .disposition(let d) = $0.fact { return d.state == .notExecuted }; return false })
        } else { #expect(try await journal.pendingMutations().isEmpty) }
        try await journal.close()
    }
}

private func stageCall(_ id: String, name: String) -> ToolCall {
    .init(id: .init(rawValue: id), name: name, argumentsJSON: "{}", completeness: .complete)
}

private actor AuditStageProbe {
    private(set) var authorized: [String] = []
    private(set) var executed: [String] = []
    private(set) var toolAuthorized: [String] = []
    func authorization(_ id: String) { authorized.append(id) }
    func execution(_ id: String) { executed.append(id) }
    func toolAuthorization(_ id: String) { toolAuthorized.append(id) }
}

private struct AuditStageAuthorizer: AgentAuthorizer {
    let probe: AuditStageProbe
    let stop: String
    var entered: AuditGate? = nil
    var release: AuditGate? = nil
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        let id = request.modelCallID.rawValue
        await probe.authorization(id)
        if id == "A", stop == "cancel" || stop == "deadline" || stop == "authorizer-timeout" { await entered?.open(); await release?.wait() }
        if stop == "enterprise-evidence" { throw EvidenceError.unavailable(.init(namespace: "private-secret", id: "private-secret")) }
        if stop == "enterprise-authorization" { throw AgentAuthorizationError.authorizationDenied }
        let deny = id == "A" && ["deny", "read-prefix", "mutation-prefix", "enterprise-deny"].contains(stop)
        return .init(request: request, outcome: deny ? .deny : .allow,
            subject: .init(issuer: "fixture", subjectID: "rule", type: .automatedPolicy),
            policy: .init(id: "fixture", version: "1"), validFor: .seconds(30), reasonCode: "fixture")
    }
}

private struct AuditStageTool: RuntimeAgentTool {
    let runtimeDefinition: ModelToolDefinition
    let policy: ToolPolicy
    let probe: AuditStageProbe
    let directory: URL
    let callbackError: String
    let executorEntered: AuditGate?
    let executorRelease: AuditGate?
    init(name: String, probe: AuditStageProbe, directory: URL, readOnly: Bool = false,
         callbackError: String = "none", evidence: Bool = false,
         executorEntered: AuditGate? = nil, executorRelease: AuditGate? = nil) throws {
        runtimeDefinition = .init(name: name, description: "Controlled stage fixture",
            inputSchema: ToolSchema.object(properties: [:]).json, outputSchema: ToolSchema.string.json)
        policy = readOnly ? try .readOnly(authorization: .required) : try .mutation(authorization: .required, evidence: evidence ? .required : .none)
        self.probe = probe; self.directory = directory; self.callbackError = callbackError
        self.executorEntered = executorEntered; self.executorRelease = executorRelease
    }
    func evidenceRequirements(for input: JSONValue) throws -> [EvidenceRequirement] {
        [.init(reference: .init(namespace: "stage", id: "absent"))]
    }
    func receiptExpectation(for input: JSONValue) throws -> ToolReceiptExpectation? {
        policy.effect == .mutation ? try .init(targets: [.init(namespace: "stage", id: runtimeDefinition.name)], revision: .present) : nil
    }
    func authorize(_ input: JSONValue, context: ToolContext) async throws -> ToolAuthorization {
        await probe.toolAuthorization(context.callID.rawValue)
        if callbackError == "tool-evidence" { throw EvidenceError.unavailable(.init(namespace: "private-secret", id: "private-secret")) }
        if callbackError == "tool-authorization" { throw AgentAuthorizationError.authorizationDenied }
        return .allowed
    }
    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        await probe.execution(context.callID.rawValue)
        if policy.effect == .readOnly { return .init(output: .string("observed")) }
        try Data("effect".utf8).write(to: directory.appendingPathComponent("\(context.callID.rawValue).effect"))
        await executorEntered?.open(); await executorRelease?.wait()
        if callbackError == "executor-evidence" { throw EvidenceError.unavailable(.init(namespace: "private-secret", id: "private-secret")) }
        if callbackError == "executor-authorization" { throw AgentAuthorizationError.authorizationDenied }
        return .init(output: .string("written"), receipt: .init(operationID: context.idempotencyKey!, status: .succeeded,
            confirmedTargets: [.init(namespace: "stage", id: runtimeDefinition.name)], revision: "1"))
    }
}
