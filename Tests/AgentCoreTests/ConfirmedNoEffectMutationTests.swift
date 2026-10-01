import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

struct ConfirmedNoEffectMutationTests {
    @Test func executorConflictIsAtomicallyRecordedBeforeAReauthorizedNewAttempt() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "no-effect", supportsConfirmedNoEffect: true)
        let file = directory.appendingPathComponent("effect.txt")
        let counts = NoEffectCounts()
        let authorizer = AuditTestAuthorizer()
        let provider = ScriptedProvider { request, turn in
            if turn == 1 { return toolResponse(request, [noEffectCall("A")]) }
            if turn == 2 {
                let message = try #require(request.messages.last)
                guard case .tool(let feedback) = message else { throw FixtureError.invalidOperation }
                #expect(feedback.callID.rawValue == "A" && feedback.isError)
                #expect(!FileManager.default.fileExists(atPath: file.path))
                let proof = try #require(await journal.executorNoEffectConfirmation(sessionID: await counts.sessionID!, runID: await counts.runID!, callID: .init(rawValue: "A")))
                #expect(proof.executorProof?.receipt.failure == .conflict)
                #expect(try await journal.pendingMutations().isEmpty)
                return toolResponse(request, [noEffectCall("B")])
            }
            if turn == 4 { return toolResponse(request, [noEffectCall("C")]) }
            return textResponse(request, "done")
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try NoEffectFileTool(file: file, counts: counts)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal)
        let run = try await session.run("Write", budget: testBudget(turns: 3, calls: 2), operationID: "same-operation")
        let result = try await run.wait(); try await run.waitForDrain()
        #expect(result.modelTurns == 3 && result.toolCalls == 2)
        #expect(result.receipts.count == 1)
        #expect(await counts.executions == 2)
        #expect(await counts.authorizations == 2)
        #expect(await counts.confirmations == 1)
        #expect(await counts.effects == 1)
        #expect(await authorizer.requests.count == 2)
        #expect(await provider.log.requests.count == 3)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one effect")
        _ = try await session.conversationSnapshot()
        let page = try await journal.auditRecords(matching: .init(runID: run.id))
        #expect(page.records.filter { if case .disposition(let d) = $0.fact { return d.state == .executorObserved }; return false }.count == 2)
        #expect(page.records.filter { if case .result(let r) = $0.fact { return r.kind == .noEffectConfirmation && r.settlementSource == .executor }; return false }.count == 1)
        #expect(page.records.filter { if case .result(let r) = $0.fact { return r.kind == .settlement }; return false }.count == 1)
        let repair = AgentResolvedReadOnlyToolProjector(spans: [.init(failedCallID: .init(rawValue: "A"), resolvedByCallID: .init(rawValue: "B"), summary: "fixed")])
        let binding = try AgentModelBinding(profileID: "repair", profileRevision: "1", model: fixtureModel, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"), projector: repair)
        await #expect(throws: AgentContextProjectionError.unresolvedReadOnlySpan(.init(rawValue: "A"))) { try await session.run("next", using: binding) }
        #expect(await provider.log.requests.count == 3)
        let replay = try await session.run("Write again", operationID: "same-operation")
        let replayed = try await replay.wait(); try await replay.waitForDrain()
        #expect(replayed.receipts.first?.receipt == result.receipts.first?.receipt)
        #expect(await counts.executions == 2); #expect(await counts.effects == 1)
        #expect(await counts.authorizations == 3); #expect(await authorizer.requests.count == 3)
        let original = try #require(await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")))
        #expect(original.executorProof?.receipt.operationID == result.receipts.first?.receipt.operationID)
        #expect(try JSONDecoder().decode(ToolNoEffectProof.self, from: JSONEncoder().encode(original.executorProof!)) == original.executorProof)
        let sink = ExportTestSink(loseFirstAck: true, partial: true)
        let exporter = try await journal.startAuditExporter(configuration: .init(id: "no-effect", destinationID: "fixture",
            contentVersion: "1", redactionVersion: "1", pageSize: 3, maximumAttempts: 3, retryDelay: .zero), sink: sink)
        try await exporter.waitForDrain()
        #expect(await exporter.status().lastFailure == nil)
        let exported = await sink.jsonl.joined()
        #expect(!exported.contains("version check before any write")); #expect(!exported.contains("executorNoEffectProof"))
        let finalHistory = try await session.conversationSnapshot()
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let proof = try #require(await reopened.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")))
        #expect(proof.executorProof?.receipt.status == .failed)
        let restored = try await Agent(model: fixtureModel, provider: provider, tools: []).makeSession(id: session.id, journal: reopened).conversationSnapshot()
        #expect(restored.messages == finalHistory.messages)
        try await reopened.close()
    }
    @Test(arguments: ["partial", "background", "targets", "status", "unavailable", "ordinary", "default", "wrong_operation", "oversized", "backend_changed", "material_changed", "resource_changed", "account_changed"])
    func insufficientOrDefaultFailuresNeverContinue(_ mode: String) async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "closed", supportsConfirmedNoEffect: true)
        let file = directory.appendingPathComponent("effect.txt"); let counts = NoEffectCounts()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [noEffectCall("A")]) }
        let tool = try NoEffectFileTool(file: file, counts: counts, mode: mode, optIn: mode != "default")
        let session = try Agent(model: fixtureModel, provider: provider, tools: [tool]).makeSession(journal: journal)
        let run = try await session.run("write", operationID: "operation")
        await #expect(throws: (any Error).self) { try await run.wait() }; try await run.waitForDrain()
        #expect(await provider.log.requests.count == 1); #expect(await counts.executions == 1)
        #expect(await counts.effects == (mode == "partial" ? 1 : 0))
        #expect(try await journal.pendingMutations().map(\.state) == [.needsReconciliation])
        #expect(try await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")) == nil)
        #expect(!(await session.history).contains { if case .tool(let r) = $0 { return r.isError }; return false })
        try await journal.close()
    }

    @Test(arguments: ["old_proof", "tool_authorize", "duplicate"])
    func oldProofAndOldCallCannotBecomeANewConfirmedAttempt(_ mode: String) async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "old-proof", supportsConfirmedNoEffect: true)
        let counts = NoEffectCounts(); let authorizer = AuditTestAuthorizer()
        let provider = ScriptedProvider { request, turn in toolResponse(request, [noEffectCall(turn == 1 || mode == "duplicate" ? "A" : "B")]) }
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts, mode: mode)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal)
        let run = try await session.run("write", operationID: "same")
        await #expect(throws: (any Error).self) { try await run.wait() }; try await run.waitForDrain()
        #expect(await provider.log.requests.count == 2)
        #expect(await counts.executions == (mode == "old_proof" ? 2 : 1)); #expect(await counts.effects == 0)
        #expect(await authorizer.requests.count == (mode == "duplicate" ? 1 : 2))
        let page = try await journal.auditRecords(matching: .init(runID: run.id))
        #expect(page.records.filter { if case .result(let r) = $0.fact { return r.kind == .noEffectConfirmation }; return false }.count == 1)
        if mode == "tool_authorize" {
            #expect(page.records.contains { if case .disposition(let d) = $0.fact { return d.reasonCode == "tool_authorization_failed" }; return false })
        }
        try await journal.close()
    }

    @Test(arguments: [1, 2], [false, true])
    func repeatedConflictConsumesOriginalToolAndModelBudgets(_ calls: Int, _ toolLimit: Bool) async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "budgets", supportsConfirmedNoEffect: true)
        let counts = NoEffectCounts()
        let provider = ScriptedProvider { request, turn in toolResponse(request, [noEffectCall("attempt-\(turn)")]) }
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts, mode: "repeat")]).makeSession(journal: journal)
        let run = try await session.run("write", budget: testBudget(turns: toolLimit ? calls + 3 : calls + 1, calls: calls), operationID: "same")
        await #expect(throws: (any Error).self) { try await run.wait() }; try await run.waitForDrain()
        #expect(await counts.executions == calls); #expect(await counts.confirmations == calls); #expect(await counts.effects == 0)
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()
    }

    @Test func optInRequiresAnExplicitCapableStoreBeforeInputOrProvider() async throws {
        for schema in [3, 4, 5] {
            let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "format",
                supportsAdmissionRejections: schema == 4, supportsAuthorizationAudit: schema == 5)
            let counts = NoEffectCounts(); let provider = ScriptedProvider { request, _ in toolResponse(request, [noEffectCall("A")]) }
            let session = try Agent(model: fixtureModel, provider: provider,
                tools: [try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts)]).makeSession(journal: journal)
            await #expect(throws: AgentSessionError.confirmedNoEffectJournalRequired) { try await session.run("input") }
            #expect(await provider.log.requests.isEmpty); #expect(await counts.executions == 0)
            #expect(try await journal.latestCheckpoint(sessionID: session.id) == nil)
            try await journal.close()
        }
    }

    @Test func memoryCannotAcquireMutationOrNoEffectEligibility() throws {
        let counts = NoEffectCounts(), provider = ScriptedProvider { request, _ in toolResponse(request, [noEffectCall("A")]) }
        let agent = try Agent(model: fixtureModel, provider: provider,
            tools: [try NoEffectFileTool(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), counts: counts)])
        #expect(throws: AgentSessionError.durableJournalRequired) { try agent.makeSession(journal: AgentJournal()) }
    }

    @Test(arguments: ["rejected", "conflict"])
    func bothLegalKindsPreserveSuccessfulSiblingsAndTheWholeFormalGroup(_ mode: String) async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "mixed", policy: try .init(segmentBytes: 1024, maxWorkBytes: 1 << 20, maxUnreclaimedBytes: 1 << 24, maxSegmentBatches: 2), supportsConfirmedNoEffect: true)
        let success = NoEffectCounts(), conflict = NoEffectCounts()
        let first = ToolCall(id: .init(rawValue: "success"), name: "success_file", argumentsJSON: "{}", completeness: .complete)
        let provider = ScriptedProvider { request, turn in
            if turn == 1 { return toolResponse(request, [first, noEffectCall("A")]) }
            let results = request.messages.compactMap { if case .tool(let r) = $0 { return r }; return nil }
            #expect(results.map(\.callID.rawValue) == ["success", "A"])
            #expect(results.map(\.isError) == [false, true])
            return textResponse(request, "done")
        }
        let file = directory.appendingPathComponent("success.txt")
        let session = try Agent(model: fixtureModel, provider: provider, tools: [
            try NoEffectFileTool(file: file, counts: success, mode: "success", name: "success_file"),
            try NoEffectFileTool(file: directory.appendingPathComponent("no-effect.txt"), counts: conflict, mode: mode),
        ], configuration: .init(authorization: auditTestConfiguration())).makeSession(journal: journal)
        let run = try await session.run("mixed"); let result = try await run.wait(); try await run.waitForDrain()
        #expect(result.receipts.count == 1); #expect(result.receipts.first?.callID.rawValue == "success")
        #expect(await success.effects == 1); #expect(await conflict.effects == 0)
        let proof = try #require(await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")))
        #expect(proof.executorProof?.receipt.failure == (mode == "rejected" ? .rejected : .conflict))
        for _ in 0..<32 { if try await journal.requestMaintenance()?.sealedSegments == 0 { break } }
        #expect(try await (journal.storeStatus()?.layoutGeneration ?? 0) > 0)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")) == proof)
        #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.history == result.history)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one effect")
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func enterpriseSameNamedErrorOrDenyCannotRecoverOrRevivePermission(_ throwOld: Bool) async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "enterprise", supportsConfirmedNoEffect: true)
        let counts = NoEffectCounts(); let authorizer = NoEffectSecondAuthorizer(counts: counts, throwOld: throwOld)
        let provider = ScriptedProvider { request, turn in toolResponse(request, [noEffectCall(turn == 1 ? "A" : "B")]) }
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal)
        let run = try await session.run("write", operationID: "same")
        await #expect(throws: (any Error).self) { try await run.wait() }; try await run.waitForDrain()
        #expect(await authorizer.calls == 2); #expect(await counts.executions == 1); #expect(await counts.effects == 0)
        let page = try await journal.auditRecords(matching: .init(runID: run.id))
        #expect(page.records.contains { if case .disposition(let d) = $0.fact { return d.reasonCode == (throwOld ? "authorizer_error" : "host_denied") }; return false })
        #expect(page.records.filter { if case .result(let r) = $0.fact { return r.kind == .noEffectConfirmation }; return false }.count == 1)
        try await journal.close()
    }

    @Test(arguments: ["index", "witness"])
    func missingInvocationIndexOrWitnessCannotBeReadAsNoConfirmation(_ missing: String) async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "witness", policy: try .init(segmentBytes: 1024, maxWorkBytes: 1 << 20, maxUnreclaimedBytes: 1 << 24, maxSegmentBatches: 2), supportsConfirmedNoEffect: true)
        let counts = NoEffectCounts()
        let provider = ScriptedProvider { request, turn in turn == 1 ? toolResponse(request, [noEffectCall("A")]) : textResponse(request, "done") }
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts)]).makeSession(journal: journal)
        let run = try await session.run("write"); _ = try await run.wait(); try await run.waitForDrain()
        for _ in 0..<32 { if try await journal.requestMaintenance()?.sealedSegments == 0 { break } }
        #expect(try await (journal.storeStatus()?.layoutGeneration ?? 0) > 0)
        let proof = try #require(await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")))
        #expect(proof.executorProof?.version == 1)
        try await journal.close()
        let family = directory.appendingPathComponent(missing == "index" ? "calls" : "witnesses")
        let entries = try #require(FileManager.default.enumerator(at: family, includingPropertiesForKeys: nil))
        let candidates = entries.compactMap { $0 as? URL }.filter { missing == "index" ? $0.pathExtension == "json" : $0.lastPathComponent.contains("_calls_") }
        #expect(candidates.count == 1); try FileManager.default.removeItem(at: #require(candidates.first))
        let reopened = try AgentIncrementalJournal.open(at: directory)
        await #expect(throws: AgentJournalError.invalidRecord) { try await reopened.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")) }
        try await reopened.close()
    }

    @Test func oldProofCannotCrossSessionOrRunEvenWithTheSameOperationIdentity() async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "cross", supportsConfirmedNoEffect: true)
        let counts = NoEffectCounts()
        let provider = ScriptedProvider { request, turn in request.messages.last?.role == .tool ? textResponse(request, "done") : toolResponse(request, [noEffectCall("A")]) }
        let agent = try Agent(model: fixtureModel, provider: provider,
            tools: [try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts, mode: "old_proof")])
        let first = try agent.makeSession(journal: journal), second = try agent.makeSession(journal: journal)
        let a = try await first.run("write", operationID: "stable"); _ = try await a.wait(); try await a.waitForDrain()
        let b = try await second.run("write", operationID: "stable")
        await #expect(throws: ToolNoEffectError.invalidBinding) { try await b.wait() }; try await b.waitForDrain()
        #expect(await counts.executions == 2); #expect(await counts.effects == 0)
        #expect(try await journal.executorNoEffectConfirmation(sessionID: first.id, runID: a.id, callID: .init(rawValue: "A")) != nil)
        #expect(try await journal.executorNoEffectConfirmation(sessionID: second.id, runID: b.id, callID: .init(rawValue: "A")) == nil)
        #expect(try await journal.pendingMutations(sessionID: second.id).map(\.state) == [.needsReconciliation])
        let old = try #require(await journal.executorNoEffectConfirmation(sessionID: first.id, runID: a.id, callID: .init(rawValue: "A")))
        let archived = try JSONDecoder().decode(AgentNoEffectConfirmation.self, from: JSONEncoder().encode(old))
        let pending = try #require(await journal.pendingMutations(sessionID: second.id).first)
        await #expect(throws: AgentJournalError.invalidRecord) { try await journal.abortMutation(pending, confirmedNoEffect: archived) }
        #expect(try await journal.pendingMutations(sessionID: second.id).map(\.state) == [.needsReconciliation])
        try await journal.close()
    }

    @Test func preparationThrowingAnOldExecutorErrorDoesNotAcquireExecutorOrigin() async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "prepare-origin", supportsConfirmedNoEffect: true)
        let counts = NoEffectCounts(), authorizer = AuditTestAuthorizer()
        let provider = ScriptedProvider { request, turn in
            if turn > 1 { counts.bindingState.failPreparation() }
            return toolResponse(request, [noEffectCall(turn == 1 ? "A" : "B")])
        }
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal)
        let run = try await session.run("write")
        await #expect(throws: (any Error).self) { try await run.wait() }; try await run.waitForDrain()
        #expect(await counts.executions == 1); #expect(await authorizer.requests.count == 1)
        #expect(try await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")) != nil)
        #expect(try await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "B")) == nil)
        let facts = try await journal.auditRecords(matching: .init(runID: run.id))
        #expect(facts.records.contains { if case .authorization(let a) = $0.fact { return $0.links.modelCallID == "B" && a.status == .notEvaluated }; return false })
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()
    }

    @Test func reconciliationConfirmationIsDistinctFromExecutorConfirmation() async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "reconciliation", supportsConfirmedNoEffect: true)
        let counts = NoEffectCounts(), provider = ScriptedProvider { request, _ in toolResponse(request, [noEffectCall("A")]) }
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts, mode: "ordinary")],
            configuration: .init(authorization: auditTestConfiguration())).makeSession(journal: journal)
        let run = try await session.run("write")
        await #expect(throws: (any Error).self) { try await run.wait() }; try await run.waitForDrain()
        let pending = try #require(await journal.pendingMutations().first)
        try await journal.abortMutation(pending, confirmedNoEffect: .init(basis: "Host independently reconciled backend no effect"))
        #expect(try await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")) == nil)
        let facts = try await journal.auditRecords(matching: .init(runID: run.id))
        let refs = facts.records.compactMap { if case .result(let r) = $0.fact { return r }; return nil }
        #expect(refs.count == 1); #expect(refs.first?.settlementSource == .reconciliation)
        try await journal.close()
    }

}

func noEffectCall(_ id: String) -> ToolCall {
    .init(id: .init(rawValue: id), name: "no_effect_file", argumentsJSON: "{}", completeness: .complete)
}
actor NoEffectCounts {
    let bindingState = NoEffectBindingState()
    var executions = 0; var authorizations = 0; var confirmations = 0; var effects = 0
    var sessionID: UUID?; var runID: UUID?
    var saved: ConfirmedNoEffectToolError?
    func save(_ e: ConfirmedNoEffectToolError) { saved = e; bindingState.save(e) }
    func authorize() { authorizations += 1 }
    func entered(_ c: ToolContext) -> Int { executions += 1; sessionID = c.sessionID; runID = c.runID; return executions }
    func confirmed() { confirmations += 1 }
    func effected() { effects += 1 }
}
struct NoEffectFileTool: RuntimeAgentTool {
    let runtimeDefinition: ModelToolDefinition
    let policy: ToolPolicy
    let file: URL; let counts: NoEffectCounts
    let mode: String
    let beforeReturn: (@Sendable () async -> Void)?
    init(file: URL, counts: NoEffectCounts, mode: String = "conflict", optIn: Bool = true, name: String = "no_effect_file", timeout: Duration = .seconds(5), beforeReturn: (@Sendable () async -> Void)? = nil) throws {
        self.file = file; self.counts = counts; self.mode = mode; self.beforeReturn = beforeReturn
        runtimeDefinition = .init(name: name, description: "Controlled temporary file", inputSchema: ToolSchema.object(properties: [:]).json, outputSchema: ToolSchema.string.json)
        policy = try .mutation(timeout: timeout, evidence: .none, recoverableErrors: optIn ? .confirmedNoEffect : .failClosed)
    }
    func resourceRequirements(for input: JSONValue) throws -> [ToolResource] {
        if let error = counts.bindingState.preparationError { throw error }
        return mode == "resource_changed" && counts.bindingState.version == "2" ? [.named(.init(namespace: "fixture", id: "changed"))] : [.global]
    }
    func receiptExpectation(for input: JSONValue) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "fixture", id: "file")])
    }
    func authorizationBinding(for input: JSONValue) throws -> ToolAuthorizationBinding {
        .init(implementationVersion: "fixture-v1", backend: .init(instanceID: "fixture-backend", version: mode == "backend_changed" ? counts.bindingState.version : "1", accountID: mode == "account_changed" ? counts.bindingState.version : "fixture", credentialGeneration: "1"),
            materials: [.init(id: "controlled-material", version: mode == "material_changed" ? counts.bindingState.version : "1", contentDigest: "fixture-content-v1")])
    }
    func authorize(_ input: JSONValue, context: ToolContext) async throws -> ToolAuthorization {
        await counts.authorize()
        if mode == "tool_authorize", let old = await counts.saved { throw old }
        return .allowed
    }
    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        let entered = await counts.entered(context)
        if mode == "old_proof", entered > 1, let old = await counts.saved { throw old }
        if (entered == 1 && mode != "success") || mode == "repeat" {
            if mode == "partial" { try Data("partial effect".utf8).write(to: file); await counts.effected() }
            if mode == "ordinary" { throw ToolInvocationError.authorizationDenied }
            let error = try context.confirmNoEffect(receipt: .init(operationID: mode == "wrong_operation" ? "another-operation" : context.idempotencyKey!, status: mode == "status" ? .indeterminate : .failed,
                confirmedTargets: mode == "targets" ? [.init(namespace: "fixture", id: "file")] : [], failure: mode == "rejected" ? .rejected : mode == "unavailable" ? .unavailable : .conflict), error: .init(code: "conflict", message: mode == "oversized" ? String(repeating: "x", count: 9000) : "Retry the controlled revision."),
                wholeOperationHadNoEffect: mode != "partial", noOutstandingEffects: mode != "background", basis: "version check before any write")
            await counts.save(error)
            await counts.confirmed()
            if ["backend_changed", "material_changed", "resource_changed", "account_changed"].contains(mode) { counts.bindingState.change() }
            await beforeReturn?()
            throw error
        }
        try Data("one effect".utf8).write(to: file)
        await counts.effected()
        return .init(output: .string("written"), receipt: .init(operationID: context.idempotencyKey!, status: .succeeded,
            confirmedTargets: [.init(namespace: "fixture", id: "file")]))
    }
}

actor NoEffectSecondAuthorizer: AgentAuthorizer {
    let counts: NoEffectCounts; let throwOld: Bool
    var calls = 0
    init(counts: NoEffectCounts, throwOld: Bool) { self.counts = counts; self.throwOld = throwOld }
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        calls += 1
        if calls > 1, throwOld, let old = await counts.saved { throw old }
        return .init(request: request, outcome: calls == 1 ? .allow : .deny,
            subject: .init(issuer: "fixture", subjectID: "rule", type: .automatedPolicy),
            policy: .init(id: "fixture", version: "1"), validFor: .seconds(30), reasonCode: "fixture")
    }
}

final class NoEffectBindingState: @unchecked Sendable {
    private let lock = NSLock(); private var value = "1"
    private var saved: ConfirmedNoEffectToolError?; private var preparation = false
    func save(_ e: ConfirmedNoEffectToolError) { lock.withLock { saved = e } }
    func failPreparation() { lock.withLock { preparation = true } }
    var preparationError: ConfirmedNoEffectToolError? { lock.withLock { preparation ? saved : nil } }
    var version: String { lock.withLock { value } }
    func change() { lock.withLock { value = "2" } }
}
