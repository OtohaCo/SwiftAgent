import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

struct AuditExecutionRegressionTests {
    @Test func runtimeEvidenceRejectionIsNotAHostDeny() async throws {
        let setup = try auditExecutionSetup(evidence: true)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let run = try await setup.session.run("write")
        await #expect(throws: (any Error).self) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await setup.authorizer.requests.isEmpty)
        #expect(await setup.probe.executorEntered == 0)
        let page = try await setup.journal.auditRecords(matching: .init(runID: run.id))
        #expect(page.records.contains { if case .authorization(let value) = $0.fact { return value.status == .notEvaluated }; return false })
        #expect(try await setup.journal.pendingMutations().isEmpty)
        try await setup.journal.close()
    }

    @Test func enterpriseAllowAndDomainDenyAreDistinctAndCreateNoIntent() async throws {
        let setup = try auditExecutionSetup(domainDeny: true)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let run = try await setup.session.run("write")
        await #expect(throws: ToolInvocationError.authorizationDenied) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await setup.probe.domainChecks == 1)
        #expect(await setup.probe.executorEntered == 0)
        let records = try await setup.journal.auditRecords(matching: .init(runID: run.id)).records
        #expect(records.contains { if case .authorization(let value) = $0.fact { return value.layer == .enterprise && value.status == .allowed }; return false })
        #expect(records.contains { if case .authorization(let value) = $0.fact { return value.layer == .tool && value.status == .denied }; return false })
        #expect(try await setup.journal.pendingMutations().isEmpty)
        try await setup.journal.close()
    }

    @Test func settledRetryReauthorizesAndReferencesOriginalReceiptWithoutReexecution() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "execution", supportsAuthorizationAudit: true)
        let probe = AuditExecutionProbe()
        let authorizer = AuditTestAuthorizer()
        let agent = try Agent(model: fixtureModel, provider: AuditExecutionProvider(), tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer)))
        let first = try await agent.makeSession(journal: journal).run("write", operationID: "same-operation")
        let receipt = try #require(try await first.wait().receipts.first?.receipt)
        try await first.waitForDrain()
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let retry = try await agent.makeSession(journal: reopened).run("write", operationID: "same-operation")
        let replay = try await retry.wait()
        try await retry.waitForDrain()
        #expect(await probe.executorEntered == 1)
        #expect(await probe.effects == 1)
        #expect(await probe.domainChecks == 2)
        #expect(await authorizer.requests.count == 2)
        #expect(replay.receipts.first?.receipt == receipt)
        let records = try await reopened.auditRecords(matching: .init(runID: retry.id), includeRestrictedPayload: true).records
        #expect(records.contains { if case .result(let r) = $0.fact { return r.kind == .replay && r.sourceRunID == first.id && r.receipt == receipt }; return false })
        #expect(!records.contains { if case .disposition(let d) = $0.fact { return d.state == .executorObserved }; return false })
        try await reopened.close()
    }

    @Test(arguments: ["material", "revision", "backend", "account", "definition", "resources"])
    func aChangedPreparedActionInvalidatesTheApproval(_ change: String) async throws {
        let versions = AuditMutableVersions()
        let authorizer = ChangingAuditAuthorizer(versions: versions, change: change)
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "changes", supportsAuthorizationAudit: true)
        let probe = AuditExecutionProbe()
        let tool = try AuditExecutionTool(probe: probe, versions: versions)
        let run = try await Agent(model: fixtureModel, provider: AuditExecutionProvider(), tools: [tool],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer)))
            .makeSession(journal: journal).run("write", operationID: "change")
        await #expect(throws: AgentAuthorizationError.actionChanged) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await probe.executorEntered == 0)
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()
    }

    @Test func authorizerFailureRecordsIncompleteInsteadOfDeny() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "error", supportsAuthorizationAudit: true)
        let probe = AuditExecutionProbe()
        let run = try await Agent(model: fixtureModel, provider: AuditExecutionProvider(), tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: FailingAuditAuthorizer())))
            .makeSession(journal: journal).run("write")
        await #expect(throws: AgentAuthorizationError.authorizerFailed) { try await run.wait() }
        try await run.waitForDrain()
        let records = try await journal.auditRecords(matching: .init(runID: run.id)).records
        #expect(records.contains { if case .authorization(let a) = $0.fact { return a.layer == .enterprise && a.status == .incomplete && a.decision == nil }; return false })
        #expect(await probe.executorEntered == 0)
        try await journal.close()
    }

    @Test(arguments: [false, true])
    func cancelledOrRevokedSlowAuthorizerCannotReviveTheRun(_ revoke: Bool) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "cancel", supportsAuthorizationAudit: true)
        let entered = AuditGate(), release = AuditGate(), scope = AgentAuthorizationScope()
        let authorizer = BlockingAuditAuthorizer(entered: entered, release: release)
        let probe = AuditExecutionProbe()
        let configuration = AgentAuthorizationConfiguration(mode: .requiredAudit, authorizer: authorizer,
            identity: auditTestConfiguration().identity, scope: scope)
        let run = try await Agent(model: fixtureModel, provider: AuditExecutionProvider(), tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(authorization: configuration)).makeSession(journal: journal).run("write")
        await entered.wait()
        if revoke { await scope.revoke() } else { await run.cancel() }
        await #expect(throws: CancellationError.self) { try await run.wait() }
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        let waiting = AuditGate()
        let waiter = Task { await waiting.open(); try await run.waitForDrain() }
        await waiting.wait(); waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await release.open()
        try await run.waitForDrain()
        try await withOperationDeadline(ContinuousClock.now.advanced(by: .seconds(2)),
            timeoutError: FixtureError.invalidOperation) { try await scope.waitForDrain() }
        #expect(await probe.executorEntered == 0)
        #expect(try await journal.pendingMutations().isEmpty)
        let records = try await journal.auditRecords(matching: .init(runID: run.id)).records
        #expect(records.contains { if case .authorization(let a) = $0.fact { return a.decision?.outcome == .allow }; return false })
        #expect(!records.contains { if case .disposition(let d) = $0.fact { return d.state == .dispatchPrepared }; return false })
        try await journal.close()
    }

    @Test func slowAuthorizerDoesNotHoldTheSharedToolResourceLease() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "concurrency", supportsAuthorizationAudit: true)
        let entered = AuditGate(), release = AuditGate(), scheduler = ToolScheduler(), probe = AuditExecutionProbe()
        let first = try await Agent(model: fixtureModel, provider: AuditExecutionProvider(), tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(scheduler: scheduler, authorization: auditTestConfiguration(authorizer: BlockingAuditAuthorizer(entered: entered, release: release))))
            .makeSession(journal: journal).run("write", operationID: "first")
        await entered.wait()
        let second = try await Agent(model: fixtureModel, provider: AuditExecutionProvider(), tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(scheduler: scheduler, authorization: auditTestConfiguration()))
            .makeSession(journal: journal).run("write", operationID: "second")
        _ = try await second.wait(); try await second.waitForDrain()
        #expect(await probe.executorEntered == 1)
        await release.open()
        _ = try await first.wait(); try await first.waitForDrain()
        #expect(await probe.executorEntered == 2)
        try await journal.close()
    }

    @Test func unknownToolAndSchemaRejectionRetainIndependentOriginalProposal() async throws {
        for call in [ToolCall(id: .init(rawValue: "unknown"), name: "does_not_exist", argumentsJSON: "{}", completeness: .complete),
                     .init(id: .init(rawValue: "bad-schema"), name: AuditExecutionTool.name, argumentsJSON: #"{"id":123}"#, completeness: .complete)] {
            let directory = auditTestDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "rejected", supportsAuthorizationAudit: true)
            let authorizer = AuditTestAuthorizer(), probe = AuditExecutionProbe()
            let run = try await Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in toolResponse(request, [call]) },
                tools: [try AuditExecutionTool(probe: probe)], configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer)))
                .makeSession(journal: journal).run("write")
            await #expect(throws: (any Error).self) { try await run.wait() }
            try await run.waitForDrain()
            let records = try await journal.auditRecords(matching: .init(runID: run.id), includeRestrictedPayload: true).records
            #expect(records.contains { if case .proposal(let p) = $0.fact { return p.rawArgumentsJSON == call.argumentsJSON && p.reconstructable }; return false })
            #expect(await authorizer.requests.isEmpty)
            #expect(await probe.executorEntered == 0)
            try await journal.close()
        }
    }
}

struct AuditExecutionProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.multiTurn, .tools])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let events = request.messages.last?.role == .tool ? textResponse(request, "done") : toolResponse(request, [
                .init(id: .init(rawValue: "write-\(request.runID)"), name: AuditExecutionTool.name, argumentsJSON: #"{"id":"A"}"#, completeness: .complete)
            ])
            for event in events { try emit(event) }
        }
    }
}

actor AuditExecutionProbe {
    private(set) var executorEntered = 0
    private(set) var effects = 0
    private(set) var domainChecks = 0
    func authorize(deny: Bool) -> ToolAuthorization { domainChecks += 1; return deny ? .denied : .allowed }
    func execute(_ context: ToolContext, id: String) -> ToolReceipt {
        executorEntered += 1; effects += 1
        return .init(operationID: context.idempotencyKey!, status: .succeeded,
            confirmedTargets: [.init(namespace: "audit.fixture", id: id)], revision: "1")
    }
}

struct AuditExecutionTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    typealias Output = String
    static let name = "audit_write"
    static let description = "Controlled mutation"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.string
    let probe: AuditExecutionProbe
    let policy: ToolPolicy
    let domainDeny: Bool
    let versions: AuditMutableVersions
    init(probe: AuditExecutionProbe, evidence: Bool = false, domainDeny: Bool = false, versions: AuditMutableVersions = .init()) throws {
        self.probe = probe; self.domainDeny = domainDeny; self.versions = versions
        policy = try .mutation(timeout: .seconds(10), authorization: .required, evidence: evidence ? .required : .none)
    }
    var definition: ModelToolDefinition {
        .init(name: Self.name, description: versions.get("definition"), inputSchema: Self.inputSchema.json, outputSchema: Self.outputSchema.json)
    }
    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] { [.init(reference: .init(namespace: "audit.fixture", id: input.id))] }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "audit.fixture", id: versions.get("resources") == "1" ? input.id : "changed"))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "audit.fixture", id: input.id)], revision: .present) }
    func authorizationBinding(for input: Input) throws -> ToolAuthorizationBinding {
        .init(definitionVersion: "1", implementationVersion: "1",
            backend: .init(instanceID: versions.get("backend"), version: "1", accountID: "fixture", credentialGeneration: versions.get("account")),
            resourceRevisions: [.init(resource: .named(.init(namespace: "audit.fixture", id: input.id)), revision: versions.get("revision"))],
            materials: [.init(id: "attachment", version: versions.get("material"), contentDigest: versions.get("material"))])
    }
    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization { await probe.authorize(deny: domainDeny) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> { .init(output: "written", receipt: await probe.execute(context, id: input.id)) }
}

final class AuditMutableVersions: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: String] = [:]
    func get(_ key: String) -> String { lock.withLock { values[key] ?? "1" } }
    func change(_ key: String) { lock.withLock { values[key] = "2" } }
}

struct ChangingAuditAuthorizer: AgentAuthorizer {
    let versions: AuditMutableVersions; let change: String
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        let result = AuthorizationDecision(request: request, outcome: .allow,
            subject: .init(issuer: "fixture", subjectID: "policy", type: .automatedPolicy),
            policy: .init(id: "exact", version: "1"), validFor: .seconds(30), reasonCode: "fixture")
        versions.change(change); return result
    }
}

struct FailingAuditAuthorizer: AgentAuthorizer {
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision { throw FixtureError.invalidOperation }
}

actor AuditGate {
    private var opened = false; private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { opened = true; let ready = waiters; waiters.removeAll(); ready.forEach { $0.resume() } }
}

struct BlockingAuditAuthorizer: AgentAuthorizer {
    let entered: AuditGate; let release: AuditGate
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        await entered.open(); await release.wait()
        return AuthorizationDecision(request: request, outcome: .allow,
            subject: .init(issuer: "fixture", subjectID: "user", type: .human),
            policy: .init(id: "exact", version: "1"), validFor: .seconds(30), reasonCode: "confirmed")
    }
}

private func auditExecutionSetup(evidence: Bool = false, domainDeny: Bool = false) throws -> (directory: URL, journal: AgentJournal, session: AgentSession, authorizer: AuditTestAuthorizer, probe: AuditExecutionProbe) {
    let directory = auditTestDirectory()
    let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "execution", supportsAuthorizationAudit: true)
    let authorizer = AuditTestAuthorizer(), probe = AuditExecutionProbe()
    let session = try Agent(model: fixtureModel, provider: AuditExecutionProvider(),
        tools: [try AuditExecutionTool(probe: probe, evidence: evidence, domainDeny: domainDeny)],
        configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal)
    return (directory, journal, session, authorizer, probe)
}
