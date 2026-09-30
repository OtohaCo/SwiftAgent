import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

struct AuditedAuthorizationTests {
    @Test func requiredModeRejectsMissingPrerequisitesBeforeInputAndProvider() async throws {
        let log = EffectLog()
        let provider = ScriptedProvider { request, _ in textResponse(request, "unused") }
        for configuration in [
            AgentAuthorizationConfiguration(mode: .requiredAudit),
            AgentAuthorizationConfiguration(mode: .requiredAudit, authorizer: AuditTestAuthorizer()),
        ] {
            let agent = try Agent(model: fixtureModel, provider: provider,
                tools: [try AddTool(log: log)], configuration: .init(authorization: configuration))
            #expect(throws: (any Error).self) { try agent.makeSession() }
        }
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try AgentIncrementalJournal.create(at: directory, operationDomain: "audit-tests")
        let agent = try Agent(model: fixtureModel, provider: provider,
            configuration: .init(authorization: auditTestConfiguration()))
        #expect(throws: AgentAuthorizationError.auditStoreRequired) { try agent.makeSession(journal: old) }
        #expect(await provider.log.requests.isEmpty)
        #expect(try await old.latestCheckpoint(sessionID: UUID()) == nil)
        try await old.close()
    }

    @Test(arguments: [AuthorizationDecision.Outcome.allow, .deny, .requiresUserAction])
    func everyToolIncludingNotRequiredUsesEnterpriseAuthorizer(_ outcome: AuthorizationDecision.Outcome) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "audit-tests", supportsAuthorizationAudit: true)
        let log = EffectLog()
        let authorizer = AuditTestAuthorizer(outcome: outcome)
        let provider = auditAddProvider()
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: log)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal)
        let run = try await session.run("Add")
        if outcome == .allow { #expect(try await run.wait().outcome == .completed) }
        else { await #expect(throws: (any Error).self) { try await run.wait() } }
        try await run.waitForDrain()
        #expect(await authorizer.requests.count == 1)
        #expect(await log.names.count == (outcome == .allow ? 1 : 0))
        let page = try await journal.auditRecords(matching: .init(runID: run.id), includeRestrictedPayload: true)
        let evaluation = try #require(page.records.compactMap { record -> AuditAuthorizationEvaluation? in
            if case .authorization(let value) = record.fact, value.layer == .enterprise { return value }
            return nil
        }.first)
        #expect(evaluation.decision?.outcome == outcome)
        #expect(evaluation.decision?.subject.type == .automatedPolicy)
        if outcome != .allow {
            #expect(!page.records.contains { if case .disposition(let value) = $0.fact { return value.state == .dispatchPrepared }; return false })
        }
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()
    }

    @Test func archivedAllowCannotRegainPermissionEvenFromTheHostCallback() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "audit-tests", supportsAuthorizationAudit: true)
        let log = EffectLog()
        let authorizer = AuditTestAuthorizer(roundTrip: true)
        let run = try await Agent(model: fixtureModel, provider: auditAddProvider(), tools: [try AddTool(log: log)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer)))
            .makeSession(journal: journal).run("Add")
        await #expect(throws: AgentAuthorizationError.invalidDecision) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await log.names.isEmpty)
        #expect(await authorizer.requests.count == 1)
        try await journal.close()
    }

    @Test func denySurvivesReopenWithRestrictedOriginalProposalAndNoExecution() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "audit-tests", supportsAuthorizationAudit: true)
        let log = EffectLog()
        let authorizer = AuditTestAuthorizer(outcome: .deny, human: true)
        let run = try await Agent(model: fixtureModel, provider: auditAddProvider(), tools: [try AddTool(log: log)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer)))
            .makeSession(journal: journal).run("Add")
        await #expect(throws: AgentAuthorizationError.authorizationDenied) { try await run.wait() }
        try await run.waitForDrain()
        let request = try #require(await authorizer.requests.first)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let page = try await reopened.auditRecords(matching: .init(authorizationID: request.authorizationID), includeRestrictedPayload: true)
        #expect(page.records.contains { if case .authorization(let value) = $0.fact { return value.decision?.subject.subjectID == "user-1" }; return false })
        let proposals = try await reopened.auditRecords(matching: .init(invocationID: request.invocationID), includeRestrictedPayload: true)
        #expect(proposals.records.contains { if case .proposal(let value) = $0.fact { return value.rawArgumentsJSON == #"{ "rhs": 2, "lhs": 1 }"# }; return false })
        #expect(await log.names.isEmpty)
        #expect(try await reopened.latestCheckpoint(sessionID: request.scope.sessionID)?.history.contains { if case .tool = $0 { return true }; return false } == false)
        try await reopened.close()
    }

    @Test func queriesBindFilterAndHighWaterWithoutChangingConversationRevision() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "audit-tests", supportsAuthorizationAudit: true)
        let log = EffectLog()
        let session = try Agent(model: fixtureModel, provider: auditAddProvider(), tools: [try AddTool(log: log)],
            configuration: .init(authorization: auditTestConfiguration())).makeSession(journal: journal)
        let run = try await session.run("Add")
        _ = try await run.wait()
        try await run.waitForDrain()
        let snapshot = try await session.conversationSnapshot()
        let first = try await journal.auditRecords(limit: 1)
        let cursor = try #require(first.nextCursor)
        await #expect(throws: AgentAuthorizationError.cursorMismatch) {
            try await journal.auditRecords(matching: .init(runID: run.id), cursor: cursor)
        }
        let next = try await journal.auditRecords(limit: 1, cursor: cursor)
        #expect(next.highWaterSequence == first.highWaterSequence)
        #expect(next.records.first!.sequence > first.records.first!.sequence)
        #expect(try await session.conversationSnapshot() == snapshot)
        try await journal.close()
    }

    @Test func legacyNeedsNoAuditAndKeepsNotRequiredBehavior() async throws {
        let log = EffectLog()
        let run = try await Agent(model: fixtureModel, provider: auditAddProvider(), tools: [try AddTool(log: log)])
            .makeSession().run("Add")
        _ = try await run.wait()
        try await run.waitForDrain()
        #expect(await log.names.count == 1)
    }
}

func auditTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("SwiftAgent-audit-test-\(UUID())")
}

func auditTestConfiguration(authorizer: any AgentAuthorizer = AuditTestAuthorizer()) -> AgentAuthorizationConfiguration {
    .init(mode: .requiredAudit, authorizer: authorizer,
          identity: .init(securityDomain: "fixture", subjectID: "user-1", actingSubjectID: "agent-1",
                          backend: .init(instanceID: "fixture-backend", version: "1", accountID: "fixture-account", credentialGeneration: "1")))
}

func auditAddProvider() -> ScriptedProvider {
    ScriptedProvider { request, turn in
        turn == 1 ? toolResponse(request, [.init(id: .init(rawValue: "add-1"), name: "add",
            argumentsJSON: #"{ "rhs": 2, "lhs": 1 }"#, completeness: .complete)]) : textResponse(request, "done")
    }
}

actor AuditTestAuthorizer: AgentAuthorizer {
    let outcome: AuthorizationDecision.Outcome
    let human: Bool
    let roundTrip: Bool
    private(set) var requests: [AuthorizationRequest] = []
    init(outcome: AuthorizationDecision.Outcome = .allow, human: Bool = false, roundTrip: Bool = false) {
        self.outcome = outcome; self.human = human; self.roundTrip = roundTrip
    }
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        requests.append(request)
        let decision = AuthorizationDecision(request: request, outcome: outcome,
            subject: .init(issuer: "fixture-host", subjectID: human ? "user-1" : "rule-service", type: human ? .human : .automatedPolicy),
            policy: .init(id: "fixture-policy", version: "1", ruleReferences: ["exact-action"]),
            validFor: .seconds(30), reasonCode: "fixture")
        if roundTrip { return try JSONDecoder().decode(AuthorizationDecision.self, from: JSONEncoder().encode(decision)) }
        return decision
    }
}
