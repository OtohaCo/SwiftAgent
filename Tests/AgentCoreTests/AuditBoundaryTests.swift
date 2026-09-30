import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

struct AuditBoundaryTests {
    @Test(arguments: [false, true])
    func revocationAfterIntentOrFinalAdmissionNeverErasesTheIntent(_ final: Bool) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "boundaries", supportsAuthorizationAudit: true)
        let entered = AuditGate(), release = AuditGate(), probe = AuditExecutionProbe(), scope = AgentAuthorizationScope()
        var configuration = AgentAuthorizationConfiguration(mode: .requiredAudit, authorizer: AuditTestAuthorizer(),
            identity: auditTestConfiguration().identity, scope: scope)
        let barrier: @Sendable () async -> Void = { await entered.open(); await release.wait() }
        configuration.testingHooks = final ? .init(finalAdmitted: barrier) : .init(applicationCommitted: barrier)
        let session = try Agent(model: fixtureModel, provider: AuditExecutionProvider(), tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(authorization: configuration)).makeSession(journal: journal)
        let run = try await session.run("write", operationID: "intent-boundary")
        await entered.wait()
        let before = try await journal.auditRecords(matching: .init(runID: run.id)).records
        #expect(before.contains { if case .disposition(let d) = $0.fact { return d.state == .dispatchPrepared }; return false })
        #expect(before.contains { if case .disposition(let d) = $0.fact { return d.state == .runtimeAdmitted }; return false } == final)
        #expect(try await journal.pendingMutations().count == 1)
        await scope.revoke()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        await release.open(); try await run.waitForDrain(); try await scope.waitForDrain()
        #expect(await probe.executorEntered == 0)
        let pending = try #require(try await journal.pendingMutations().first)
        #expect(pending.state == .needsReconciliation)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.pendingMutations().first?.state == .needsReconciliation)
        let records = try await reopened.auditRecords(matching: .init(runID: run.id)).records
        #expect(records.contains { if case .disposition(let d) = $0.fact { return d.state == .uncertain }; return false })
        // Only this controlled fixture's independent no-entry counter supplies a trusted no-effect basis.
        try await reopened.abortMutation(pending, confirmedNoEffect: .init(basis: "controlled fixture executor count is zero"))
        try await reopened.close()
    }

    @Test func authorizerTimeoutHasAnOwnerUntilLateCallbackActuallyExits() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "timeout", supportsAuthorizationAudit: true)
        let entered = AuditGate(), release = AuditGate(), probe = AuditExecutionProbe()
        let configuration = AgentAuthorizationConfiguration(mode: .requiredAudit,
            authorizer: BlockingAuditAuthorizer(entered: entered, release: release),
            identity: auditTestConfiguration().identity, authorizerTimeout: .seconds(1))
        let run = try await Agent(model: fixtureModel, provider: AuditExecutionProvider(), tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(authorization: configuration)).makeSession(journal: journal).run("write")
        await entered.wait()
        await #expect(throws: AgentAuthorizationError.authorizerTimedOut) { try await run.wait() }
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        #expect(await probe.executorEntered == 0)
        await release.open(); try await run.waitForDrain()
        let records = try await journal.auditRecords(matching: .init(runID: run.id)).records
        #expect(records.contains { if case .authorization(let a) = $0.fact { return a.status == .incomplete }; return false })
        #expect(!records.contains { if case .disposition(let d) = $0.fact { return d.state == .dispatchPrepared }; return false })
        try await journal.close()
    }

    @Test func expiredAllowIsRetainedButCannotProduceAnIntent() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "expiry", supportsAuthorizationAudit: true)
        let probe = AuditExecutionProbe()
        let run = try await Agent(model: fixtureModel, provider: AuditExecutionProvider(), tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: ExpiredAuditAuthorizer())))
            .makeSession(journal: journal).run("write")
        await #expect(throws: AgentAuthorizationError.expired) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await probe.executorEntered == 0)
        #expect(try await journal.pendingMutations().isEmpty)
        #expect(try await journal.auditRecords(matching: .init(runID: run.id)).records.contains {
            if case .authorization(let a) = $0.fact { return a.decision?.outcome == .allow }; return false
        })
        try await journal.close()
    }

    @Test func liveDecisionFromAnotherRunSessionOrStoreIsRejected() async throws {
        let cached = CachedAuditAuthorizer(), probe = AuditExecutionProbe()
        let directories = (0..<2).map { _ in auditTestDirectory() }
        defer { for directory in directories { try? FileManager.default.removeItem(at: directory) } }
        let firstJournal = try AgentIncrementalJournal.create(at: directories[0], operationDomain: "scope", supportsAuthorizationAudit: true)
        let otherJournal = try AgentIncrementalJournal.create(at: directories[1], operationDomain: "scope", supportsAuthorizationAudit: true)
        let agent = try Agent(model: fixtureModel, provider: AuditExecutionProvider(), tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: cached)))
        let firstSession = try agent.makeSession(journal: firstJournal)
        let first = try await firstSession.run("write")
        _ = try await first.wait(); try await first.waitForDrain()
        for session in [firstSession, try agent.makeSession(journal: firstJournal), try agent.makeSession(journal: otherJournal)] {
            let run = try await session.run("write")
            await #expect(throws: AgentAuthorizationError.invalidDecision) { try await run.wait() }
            try await run.waitForDrain()
        }
        #expect(await probe.executorEntered == 1)
        try await firstJournal.close(); try await otherJournal.close()
    }

    @Test func oversizeAndReusedModelIDsProduceBoundedDistinctProposals() async throws {
        for oversized in [false, true] {
            let directory = auditTestDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "limits", supportsAuthorizationAudit: true)
            let log = EffectLog(), authorizer = AuditTestAuthorizer()
            let provider = ScriptedProvider { request, _ in
                let arguments = oversized ? "{\"lhs\":1,\"rhs\":2,\"oversize\":\"" + String(repeating: "x", count: 70000) + "\"}" : #"{"lhs":1,"rhs":2}"#
                return toolResponse(request, [.init(id: .init(rawValue: "same-model-id"), name: "add", argumentsJSON: arguments, completeness: .complete)])
            }
            let run = try await Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: log)],
                configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal).run("add")
            await #expect(throws: (any Error).self) { try await run.wait() }
            try await run.waitForDrain()
            let records = try await journal.auditRecords(matching: .init(runID: run.id), includeRestrictedPayload: true).records
            let received = records.filter { if case .proposal(let p) = $0.fact { return p.stage == .received }; return false }
            if oversized {
                #expect(await log.names.isEmpty)
                #expect(await authorizer.requests.isEmpty)
                #expect(received.contains { if case .proposal(let p) = $0.fact { return p.payloadTruncated && !p.reconstructable && (p.rawArgumentsJSON?.utf8.count ?? 0) <= 4096 }; return false })
            } else {
                #expect(received.count == 2)
                #expect(Set(received.map(\.links.invocationID)).count == 2)
                #expect(await log.names.count == 1)
                #expect(await authorizer.requests.count == 1)
            }
            try await journal.close()
        }
    }

    @Test(arguments: ["id", "name"])
    func oversizeStreamingIdentityIsBoundedBeforeAccumulatorCopy(_ field: String) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "stream-limit", supportsAuthorizationAudit: true)
        let authorizer = AuditTestAuthorizer(), log = EffectLog()
        let enormous = String(repeating: "界", count: 1024)
        let call = ToolCall(id: .init(rawValue: field == "id" ? enormous : "call"), name: field == "name" ? enormous : "add",
            argumentsJSON: #"{"lhs":1,"rhs":2}"#, completeness: .complete)
        let run = try await Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in toolResponse(request, [call]) },
            tools: [try AddTool(log: log)], configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer)))
            .makeSession(journal: journal).run("test")
        await #expect(throws: AgentAuthorizationError.proposalTooLarge) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await authorizer.requests.isEmpty)
        #expect(await log.names.isEmpty)
        let facts = try await journal.auditRecords(includeRestrictedPayload: true).records
        #expect(facts.allSatisfy { $0.links.modelCallID.utf8.count <= 512 })
        #expect(facts.contains { if case .proposal(let p) = $0.fact { return p.payloadTruncated && !p.reconstructable && p.toolName.utf8.count <= 512 }; return false })
        try await journal.close()
    }

    @Test func rawRepresentationsUseExistingCanonicalSemanticsInAConcurrentBatch() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "canonical", supportsAuthorizationAudit: true)
        let authorizer = AuditTestAuthorizer(), log = EffectLog()
        let raw = [#"{"lhs":1,"rhs":2}"#, "{ \"rhs\": 2, \"lhs\": 1 }"]
        let provider = ScriptedProvider { request, _ in
            if request.messages.last?.role == .tool { return textResponse(request, "done") }
            return toolResponse(request, raw.enumerated().map { .init(id: .init(rawValue: "call-\($0.offset)"), name: "add", argumentsJSON: $0.element, completeness: .complete) })
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: log)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal)
        let run = try await session.run("add twice")
        _ = try await run.wait(); try await run.waitForDrain()
        let requests = await authorizer.requests
        #expect(requests.count == 2)
        #expect(requests.first?.normalizedArguments == requests.last?.normalizedArguments)
        // Lineage is an additional bound field; canonical parameter equality does not erase it.
        #expect(requests.first?.relatedProposalID == nil)
        #expect(requests.last?.relatedProposalID == requests.first?.proposalID)
        #expect(requests.first?.actionDigest != requests.last?.actionDigest)
        #expect(requests.first?.requestID != requests.last?.requestID)
        #expect(await log.names.count == 2)
        #expect(try await journal.pendingMutations().isEmpty)
        let facts = try await journal.auditRecords(matching: .init(runID: run.id), includeRestrictedPayload: true).records
        let saved = facts.compactMap { if case .proposal(let p) = $0.fact { return p.rawArgumentsJSON }; return nil }
        #expect(Set(saved) == Set(raw))
        let history = await session.history
        #expect(history.filter { $0.role == .tool }.count == 2)
        #expect(facts.filter { if case .result(let r) = $0.fact { return r.kind == .readOnlyOutput && r.receipt == nil }; return false }.count == 2)
        try await journal.close()
    }

    @Test func capturedProposalCleanupHasAnOwnerUntilTheAuditWorkerExits() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "capture-drain", supportsAuthorizationAudit: true)
        let entered = AuditGate(), release = AuditGate(), scope = AgentAuthorizationScope(), authorizer = AuditTestAuthorizer(), log = EffectLog()
        var authorization = AgentAuthorizationConfiguration(mode: .requiredAudit, authorizer: authorizer,
            identity: auditTestConfiguration().identity, scope: scope)
        authorization.testingHooks = .init(receivedCommitted: { await entered.open(); await release.wait() })
        let run = try await Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in toolResponse(request, [
            .init(id: .init(rawValue: "received"), name: "add", argumentsJSON: #"{"lhs":1,"rhs":2}"#, completeness: .complete)
        ]) }, tools: [try AddTool(log: log)], configuration: .init(authorization: authorization))
            .makeSession(journal: journal).run("add")
        await entered.wait(); await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        #expect(await authorizer.requests.isEmpty)
        await release.open(); try await run.waitForDrain(); try await scope.waitForDrain()
        let facts = try await journal.auditRecords(matching: .init(runID: run.id)).records
        #expect(facts.contains { if case .authorization(let a) = $0.fact { return a.status == .notEvaluated }; return false })
        #expect(facts.contains { if case .disposition(let d) = $0.fact { return d.state == .notExecuted }; return false })
        #expect(await log.names.isEmpty)
        try await journal.close()
    }

    @Test(arguments: ["budget", "batch"])
    func completedUndispatchedProposalsRecordNotEvaluatedForEveryInstance(_ reason: String) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "not-dispatched", supportsAuthorizationAudit: true)
        let log = EffectLog(), authorizer = AuditTestAuthorizer()
        let calls = [ToolCall(id: .init(rawValue: "first"), name: "add", argumentsJSON: #"{"lhs":1,"rhs":2}"#, completeness: .complete),
            .init(id: .init(rawValue: "second"), name: "unknown", argumentsJSON: "{}", completeness: .complete)]
        let run = try await Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in toolResponse(request, calls) },
            tools: [try AddTool(log: log)], configuration: .init(maxToolCalls: reason == "budget" ? 0 : 8,
                authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal).run("test")
        await #expect(throws: (any Error).self) { try await run.wait() }
        try await run.waitForDrain()
        let facts = try await journal.auditRecords(matching: .init(runID: run.id)).records
        #expect(facts.filter { if case .authorization(let a) = $0.fact { return a.status == .notEvaluated }; return false }.count == 2)
        #expect(facts.filter { if case .disposition(let d) = $0.fact { return d.state == .notExecuted }; return false }.count == 2)
        #expect(await authorizer.requests.isEmpty)
        #expect(await log.names.isEmpty)
        try await journal.close()
    }

    @Test func missingLatestAuditPayloadRefusesInputBeforeProviderContact() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "missing-payload", supportsAuthorizationAudit: true)
        try await seedExportFacts(journal, count: 1)
        try await journal.close()
        let folder = directory.appendingPathComponent("audit-records")
        let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])).allObjects.compactMap { $0 as? URL }
        for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            try FileManager.default.removeItem(at: file)
        }
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let provider = ScriptedProvider { request, _ in textResponse(request, "unused") }
        let session = try Agent(model: fixtureModel, provider: provider,
            configuration: .init(authorization: auditTestConfiguration())).makeSession(journal: reopened)
        await #expect(throws: (any Error).self) { try await session.run("blocked") }
        #expect(await provider.log.requests.isEmpty)
        #expect(await session.history.isEmpty)
        try await reopened.close()
    }

    @Test func correctedRedispatchLinksTheOriginalProposalWithoutReusingItsDecision() async throws {
        let directory = auditTestDirectory(), otherDirectory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: otherDirectory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "lineage", supportsAuthorizationAudit: true)
        let waiting = AuditTestAuthorizer(outcome: .requiresUserAction), probe = AuditExecutionProbe()
        let firstSession = try Agent(model: fixtureModel, provider: AuditExecutionProvider(), tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: waiting))).makeSession(journal: journal)
        let first = try await firstSession.run("write", operationID: "same-business")
        await #expect(throws: AgentAuthorizationError.requiresUserAction) { try await first.wait() }
        try await first.waitForDrain()
        let original = try #require(await waiting.requests.first)
        let current = AuditTestAuthorizer()
        let authorization = AgentAuthorizationConfiguration(mode: .requiredAudit, authorizer: current,
            identity: auditTestConfiguration().identity, relatedProposalID: original.proposalID)
        let provider = ScriptedProvider { request, _ in
            request.messages.last?.role == .tool ? textResponse(request, "done") : toolResponse(request, [
                .init(id: .init(rawValue: "corrected"), name: AuditExecutionTool.name, argumentsJSON: #"{"id":"B"}"#, completeness: .complete)
            ])
        }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(authorization: authorization))
        let corrected = try await agent.makeSession(id: firstSession.id, journal: journal).run("corrected", operationID: "same-business")
        _ = try await corrected.wait(); try await corrected.waitForDrain()
        let request = try #require(await current.requests.first)
        #expect(request.relatedProposalID == original.proposalID)
        #expect(request.proposalID != original.proposalID && request.requestID != original.requestID)
        #expect(request.actionDigest != original.actionDigest)
        #expect(await probe.executorEntered == 1)
        let originalFacts = try await journal.auditRecords(matching: .init(proposalID: original.proposalID)).records
        #expect(originalFacts.contains { if case .authorization(let a) = $0.fact { return a.decision?.outcome == .requiresUserAction }; return false })
        #expect(try await journal.auditRecords(matching: .init(runID: corrected.id)).records.allSatisfy { $0.links.relatedProposalID == original.proposalID })
        let requestsBefore = await provider.log.requests.count
        let foreignSession = try agent.makeSession(journal: journal)
        await #expect(throws: AgentAuthorizationError.invalidProposalReference) { try await foreignSession.run("foreign") }
        let other = try AgentIncrementalJournal.create(at: otherDirectory, operationDomain: "lineage", supportsAuthorizationAudit: true)
        await #expect(throws: AgentAuthorizationError.invalidProposalReference) {
            try await agent.makeSession(id: firstSession.id, journal: other).run("foreign")
        }
        #expect(await provider.log.requests.count == requestsBefore)
        try await other.close(); try await journal.close()
    }

    @Test func runtimeDefinedToolAndForgedApprovalFieldsStillUseTheHost() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "runtime", supportsAuthorizationAudit: true)
        let log = EffectLog(), authorizer = AuditTestAuthorizer(outcome: .deny)
        let provider = ScriptedProvider { request, _ in toolResponse(request, [
            .init(id: .init(rawValue: "runtime"), name: "host_dynamic_read", argumentsJSON: #"{"approval":"allow","authorizationID":"model-supplied"}"#, completeness: .complete)
        ]) }
        let run = try await Agent(model: fixtureModel, provider: provider, tools: [AuditRuntimeRead(log: log)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal).run("read")
        await #expect(throws: AgentAuthorizationError.authorizationDenied) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await log.names.isEmpty)
        #expect(await authorizer.requests.count == 1)
        try await journal.close()
    }

    @Test func aReadOnlyExecutorFailureIsObservedAndInterruptedNotUnexecuted() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "read-failure", supportsAuthorizationAudit: true)
        let log = EffectLog()
        let run = try await Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in toolResponse(request, [
            .init(id: .init(rawValue: "read-error"), name: "audit_read_error", argumentsJSON: "{}", completeness: .complete)
        ]) }, tools: [FailingAuditRead(log: log)], configuration: .init(authorization: auditTestConfiguration()))
            .makeSession(journal: journal).run("read")
        await #expect(throws: FixtureError.invalidOperation) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await log.names.count == 1)
        let facts = try await journal.auditRecords(matching: .init(runID: run.id)).records
        #expect(facts.contains { if case .disposition(let d) = $0.fact { return d.state == .executorObserved }; return false })
        #expect(facts.contains { if case .disposition(let d) = $0.fact { return d.state == .interrupted }; return false })
        #expect(!facts.contains { if case .disposition(let d) = $0.fact { return d.state == .notExecuted }; return false })
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()
    }

    @Test func exporterStopRetainsNoncooperativeSinkAndCancelledWaiterDoesNotReleaseIt() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "slow-sink", supportsAuthorizationAudit: true)
        try await seedExportFacts(journal, count: 1)
        let entered = AuditGate(), release = AuditGate()
        let exporter = try await journal.startAuditExporter(configuration: .init(id: "slow", destinationID: "fixture",
            contentVersion: "1", redactionVersion: "1"), sink: BlockingAuditSink(entered: entered, release: release))
        await entered.wait(); await exporter.stop()
        let waiting = AuditGate()
        let cancelled = Task { await waiting.open(); try await exporter.waitForDrain() }
        await waiting.wait(); cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        #expect(await exporter.status().physicallyDrained == false)
        await release.open(); try await exporter.waitForDrain()
        #expect(await exporter.status().acknowledgedThroughSequence == 0)
        try await journal.close()
    }

    @Test(arguments: [false, true])
    func backlogIsRecheckedInTheApplicationTransaction(_ mutation: Bool) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "atomic-backlog", supportsAuthorizationAudit: true)
        let entered = AuditGate(), release = AuditGate(), probe = AuditExecutionProbe(), log = EffectLog(), authorizer = AuditTestAuthorizer()
        var authorization = AgentAuthorizationConfiguration(mode: .requiredAudit, authorizer: authorizer,
            identity: auditTestConfiguration().identity, backlog: .init(exportConfigurationID: "offline", maximumUnacknowledgedRecords: 16))
        authorization.testingHooks = .init(beforeApplication: { await entered.open(); await release.wait() })
        let provider = ScriptedProvider { request, _ in toolResponse(request, [
            .init(id: .init(rawValue: "call"), name: mutation ? AuditExecutionTool.name : "add",
                argumentsJSON: mutation ? #"{"id":"A"}"# : #"{"lhs":1,"rhs":2}"#, completeness: .complete)
        ]) }
        let tools: [any AgentTool] = mutation ? [try AuditExecutionTool(probe: probe)] : [try AddTool(log: log)]
        let run = try await Agent(model: fixtureModel, provider: provider, tools: tools,
            configuration: .init(authorization: authorization)).makeSession(journal: journal).run("execute")
        await entered.wait()
        try await seedExportFacts(journal, count: 16)
        await release.open()
        await #expect(throws: AgentAuthorizationError.backlogExceeded) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await authorizer.requests.count == 1)
        #expect(await probe.executorEntered == 0)
        #expect(await log.names.isEmpty)
        #expect(try await journal.pendingMutations().isEmpty)
        #expect(!((try await journal.auditRecords(matching: .init(runID: run.id))).records.contains {
            if case .disposition(let d) = $0.fact { return d.state == .dispatchPrepared }; return false
        }))
        try await journal.close()
    }

    @Test func backlogPressureRejectsNewWorkButAllowsAdmittedMutationSettlement() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "backlog", supportsAuthorizationAudit: true)
        let entered = AuditGate(), release = AuditGate(), probe = AuditExecutionProbe()
        var configuration = AgentAuthorizationConfiguration(mode: .requiredAudit, authorizer: AuditTestAuthorizer(),
            identity: auditTestConfiguration().identity, backlog: .init(exportConfigurationID: "offline", maximumUnacknowledgedRecords: 16))
        configuration.testingHooks = .init(finalAdmitted: { await entered.open(); await release.wait() })
        let agent = try Agent(model: fixtureModel, provider: AuditExecutionProvider(), tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(authorization: configuration))
        let first = try await agent.makeSession(journal: journal).run("write")
        await entered.wait()
        try await seedExportFacts(journal, count: 16)
        let other = try agent.makeSession(journal: journal)
        await #expect(throws: AgentAuthorizationError.backlogExceeded) { try await other.run("blocked") }
        #expect(await other.history.isEmpty)
        await release.open(); _ = try await first.wait(); try await first.waitForDrain()
        #expect(await probe.effects == 1)
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()
    }
}

private struct ExpiredAuditAuthorizer: AgentAuthorizer {
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        .init(request: request, outcome: .allow, subject: .init(issuer: "fixture", subjectID: "rule", type: .automatedPolicy),
            policy: .init(id: "expired", version: "1"), validFor: .seconds(30), notAfter: .distantPast, reasonCode: "expired")
    }
}

private actor CachedAuditAuthorizer: AgentAuthorizer {
    private var cached: AuthorizationDecision?
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        if let cached { return cached }
        let decision = AuthorizationDecision(request: request, outcome: .allow,
            subject: .init(issuer: "fixture", subjectID: "rule", type: .automatedPolicy),
            policy: .init(id: "scope", version: "1"), validFor: .seconds(30), reasonCode: "fixture")
        cached = decision; return decision
    }
}

private struct AuditRuntimeRead: RuntimeAgentTool {
    let runtimeDefinition = ModelToolDefinition(name: "host_dynamic_read", description: "Fixture runtime read",
        inputSchema: ToolSchema.object(properties: ["approval": .string, "authorizationID": .string]).json, outputSchema: ToolSchema.string.json)
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired)
    let log: EffectLog
    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> { await log.record("dynamic", context); return .init(output: .string("read")) }
}

private struct BlockingAuditSink: AuditExportSink {
    let entered: AuditGate; let release: AuditGate
    func write(_ batch: AuditExportBatch) async throws -> AuditExportAcknowledgement { await entered.open(); await release.wait(); return .init(batch: batch) }
}

private struct FailingAuditRead: RuntimeAgentTool {
    let runtimeDefinition = ModelToolDefinition(name: "audit_read_error", description: "Controlled read failure",
        inputSchema: ToolSchema.object(properties: [:]).json, outputSchema: ToolSchema.string.json)
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired)
    let log: EffectLog
    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        await log.record("read", context); throw FixtureError.invalidOperation
    }
}
