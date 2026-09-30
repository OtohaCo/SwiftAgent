import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

// A separate Swift package: only public SDK APIs. No credentials, network or user files.
@main struct EnterpriseAuthorizationFixture {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("enterprise-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("journal")
        let file = root.appendingPathComponent("controlled-output.txt")
        let archive = root.appendingPathComponent("archive.jsonl")
        let probe = FixtureProbe(), versions = FixtureVersions()
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "fixture-file-effects",
            supportsAuthorizationAudit: true)
        let authorizer = FixtureAuthorizer(versions: versions)
        let identity = AgentAuthorizationIdentity(securityDomain: "fixture", tenantID: "tenant-fixture",
            projectID: "project-fixture", subjectID: "user-42", actingSubjectID: "fixture-agent",
            backend: .init(instanceID: "local-fixture", version: "1", accountID: "fixture-account", credentialGeneration: "1"))
        let agent = try Agent(model: .init(provider: "fixture", name: "script"), provider: FixtureProvider(),
            tools: [try FixtureWrite(file: file, probe: probe, versions: versions), FixtureEvidenceWrite(probe: probe)],
            configuration: .init(authorization: .init(mode: .requiredAudit, authorizer: authorizer, identity: identity)))
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let automatic = try await session.run("automatic", operationID: "automatic-write")
        let automaticReceipt = try require(try await automatic.wait().receipts.first?.receipt)
        try await automatic.waitForDrain()
        let human = try await session.run("human", operationID: "human-write")
        _ = try await human.wait(); try await human.waitForDrain()
        let denied = try await expectFailure(session, input: "deny", expected: .authorizationDenied)
        let evidence = try await session.run("evidence", operationID: "evidence-write")
        do { _ = try await evidence.wait(); throw FixtureFailure.assertion("Evidence must reject") }
        catch is EvidenceError { }
        try await evidence.waitForDrain()
        for change in ["material", "revision", "backend"] {
            _ = try await expectFailure(session, input: "change-\(change)", expected: .actionChanged)
            versions.reset()
        }
        // A new recipient is a new exact proposal. Returning an old archived decision fails.
        _ = try await expectFailure(session, input: "old-recipient-approval", expected: .invalidDecision)
        let replay = try await session.run("automatic", operationID: "automatic-write")
        let replayResult = try await replay.wait(); try await replay.waitForDrain()
        try check(replayResult.receipts.first?.receipt == automaticReceipt, "replay must reference original Receipt")
        try check(await probe.executions == 2, "only automatic and human writes execute")
        try check(await probe.effects == 2, "exactly two controlled file effects")
        try check(await authorizer.evidenceDecisions == 0, "runtime Evidence rejection never calls the Host")
        let records = try await allRecords(journal, query: .init(sessionID: sessionID), restricted: true)
        try check(records.contains { if case .authorization(let a) = $0.fact {
            return a.decision?.subject.type == .human && a.decision?.subject.subjectID == "user-42"
        }; return false }, "human identity must be retained")
        try check(records.contains { if case .result(let r) = $0.fact {
            return r.kind == .replay && r.sourceRunID == automatic.id && r.receipt == automaticReceipt
        }; return false }, "replay result reference must be durable")
        // Standard export is a summary; trusted Host query can separately archive selected metadata.
        let regularRecords = try await allRecords(journal, query: .init(sessionID: sessionID), restricted: false)
        let localHuman = try require(regularRecords.first { if case .authorization(let a) = $0.fact {
            return a.decision?.subject.type == .human
        }; return false })
        guard case .authorization(let humanEvaluation) = localHuman.fact else {
            throw FixtureFailure.assertion("missing human evaluation")
        }
        let humanDecision = try require(humanEvaluation.decision)
        try check(humanDecision.subject.issuer == "fixture-host" && humanDecision.subject.subjectID == "user-42"
            && humanDecision.policy.id == "fixture-exact-action" && humanDecision.policy.version == "1"
            && humanDecision.hostDecisionTime != nil, "regular local query retains subject, policy and Host time")
        let selectedArchive = root.appendingPathComponent("host-selected-authorization.jsonl")
        let selectedSink = try ExampleSelectedArchiveSink(file: selectedArchive)
        let selectedCount = try await archiveSelectedAuthorizationMetadata(journal: journal, query: .init(runID: human.id)) {
            try await selectedSink.write($0)
        }
        // A Host adapter can resend its own selected metadata without touching SDK export ACKs.
        let selectedSinkReopened = try ExampleSelectedArchiveSink(file: selectedArchive)
        _ = try await archiveSelectedAuthorizationMetadata(journal: journal, query: .init(runID: human.id)) {
            try await selectedSinkReopened.write($0)
        }
        let selectedLines = try String(contentsOf: selectedArchive, encoding: .utf8).split(separator: "\n")
        let selected = try selectedLines.map { try JSONDecoder().decode(ExampleSelectedAuthorizationArchiveRecord.self, from: Data($0.utf8)) }
        try check(selectedCount == 1 && selected.count == 1, "Host-selected archive paginates to one exact decision")
        try check(selected[0].auditRecordID == localHuman.auditRecordID && selected[0].subject == humanDecision.subject
            && selected[0].policyVersion == humanDecision.policy.version && selected[0].hostDecisionTime == humanDecision.hostDecisionTime
            && selected[0].sdkObservedAt == localHuman.sdkObservedAt, "Host-selected archive preserves explicitly chosen metadata")
        let summaryProof = ExampleSummaryExportProof(localRecords: regularRecords)
        let sink = try FixtureJSONLSink(at: archive, loseFirstAcknowledgement: true)
        let export = AuditExportConfiguration(id: "archive-v1", destinationID: "fixture-jsonl", contentVersion: "1",
            redactionVersion: "conservative-v1", pageSize: 10, retryDelay: .zero)
        let exporter = try await journal.startAuditExporter(configuration: export, sink: sink, redactor: summaryProof)
        try await exporter.waitForDrain()
        let status = await exporter.status()
        try check(status.backlogRecords == 0 && status.lastFailure == nil, "export must acknowledge the backlog")
        try check(await sink.duplicates > 0, "lost ACK must cause a deduplicated resend")
        try check(await sink.recordIDs.count == records.count, "export must include every committed fact once")
        let standardLines = try String(contentsOf: archive, encoding: .utf8).split(separator: "\n")
        let standardRecords = try standardLines.map { try JSONDecoder().decode(AuditExportRecord.self, from: Data($0.utf8)) }
        try check(summaryProof.observedRecords == records.count, "redactor receives every conservative summary")
        for record in standardRecords { try summaryProof.validate(record) }
        try check(standardRecords.contains { $0.auditRecordID == localHuman.auditRecordID }, "sink receives human summary without private metadata")
        print("AuthorizationExportBoundary PASS localSubjectPolicyTimes=retained standardExport=summary redactorInput=summary hostSelectedArchive=1")
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let denials = try await allRecords(reopened, query: .init(runID: denied.id), restricted: true)
        try check(denials.contains { if case .authorization(let a) = $0.fact { return a.decision?.outcome == .deny }; return false },
            "Host denial must survive reopen")
        try check(!denials.contains { if case .disposition(let d) = $0.fact { return d.state == .executorObserved }; return false },
            "denied executor count remains zero")
        try check(try await reopened.pendingMutations().isEmpty, "no pending mutation remains")
        // A changed action after denial has a new proposal/decision, explicitly linked by the Host.
        let deniedProposal = try require(denials.first { if case .proposal = $0.fact { return true }; return false })
        let revisedAgent = try Agent(model: .init(provider: "fixture", name: "script"), provider: FixtureProvider(),
            tools: [try FixtureWrite(file: file, probe: probe, versions: versions)],
            configuration: .init(authorization: .init(mode: .requiredAudit, authorizer: FixtureAuthorizer(versions: versions),
                identity: identity, relatedProposalID: deniedProposal.links.proposalID)))
        let revised = try await revisedAgent.makeSession(id: sessionID, journal: reopened).run("revised-denial", operationID: "deny")
        _ = try await revised.wait(); try await revised.waitForDrain()
        let revisedFacts = try await allRecords(reopened, query: .init(runID: revised.id), restricted: true)
        try check(revisedFacts.allSatisfy { $0.links.relatedProposalID == deniedProposal.links.proposalID }, "changed action keeps original lineage")
        let revisedExecutions = await probe.executions, revisedEffects = await probe.effects
        try check(revisedExecutions == 3 && revisedEffects == 3, "fresh revised approval has exactly one effect")
        let finalRecords = try await allRecords(reopened, query: .init(sessionID: sessionID), restricted: true)
        let restarted = try await reopened.startAuditExporter(configuration: export, sink: sink)
        try await restarted.waitForDrain()
        try check(await restarted.status().acknowledgedThroughSequence == UInt64(finalRecords.count), "checkpoint resumes original prefix and exports the new facts")
        try await reopened.close()

        // Public legacy comparison: the same tool contract keeps its existing domain check.
        let legacy = try AgentIncrementalJournal.create(at: root.appendingPathComponent("legacy"), operationDomain: "legacy-fixture")
        let legacyProbe = FixtureProbe()
        let legacyRun = try await Agent(model: .init(provider: "fixture", name: "script"), provider: FixtureProvider(),
            tools: [try FixtureWrite(file: root.appendingPathComponent("legacy-output"), probe: legacyProbe, versions: .init())])
            .makeSession(journal: legacy).run("automatic", operationID: "legacy")
        _ = try await legacyRun.wait(); try await legacyRun.waitForDrain()
        try check(await legacyProbe.executions == 1 && !legacy.supportsAuthorizationAudit, "legacy remains unchanged")
        try await legacy.close()
        print("EnterpriseAuthorizationFixture PASS proposals=\(finalRecords.filter { if case .proposal = $0.fact { return true }; return false }.count) audit=\(finalRecords.count) executor=\(await probe.executions) effects=\(await probe.effects) exportACK=\(await restarted.status().acknowledgedThroughSequence) duplicates=\(await sink.duplicates) deniedExecutor=0 legacyExecutor=1")
    }
}

private func expectFailure(_ session: AgentSession, input: String, expected: AgentAuthorizationError) async throws -> AgentRun {
    let run = try await session.run(input, operationID: input)
    do { _ = try await run.wait(); throw FixtureFailure.assertion("expected \(expected)") }
    catch let error as AgentAuthorizationError { try check(error == expected, "unexpected authorization failure: \(error)") }
    try await run.waitForDrain()
    return run
}

private func allRecords(_ journal: AgentJournal, query: AuditQuery, restricted: Bool) async throws -> [AuditRecord] {
    var records: [AuditRecord] = [], cursor: AuditCursor?
    repeat {
        let page = try await journal.auditRecords(matching: query, limit: 20, cursor: cursor, includeRestrictedPayload: restricted)
        records += page.records; cursor = page.nextCursor
    } while cursor != nil
    return records
}

private enum FixtureFailure: Error { case assertion(String), disconnected }
private func check(_ value: Bool, _ message: String) throws { if !value { throw FixtureFailure.assertion(message) } }
private func require<T>(_ value: T?) throws -> T { guard let value else { throw FixtureFailure.assertion("missing value") }; return value }

private struct FixtureProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.multiTurn, .tools])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "fixture", model: request.model)
            try emit(.responseStarted(info))
            if request.messages.last?.role == .tool {
                try emit(.textDelta("done")); try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
                return
            }
            let input: String
            if case .user(let parts)? = request.messages.last, case .text(let value)? = parts.first { input = value }
            else { throw FixtureFailure.assertion("missing fixture input") }
            let name = input == "evidence" ? FixtureEvidenceWrite.name : FixtureWrite.name
            let arguments: JSONValue = .object(["id": .string("controlled"), "contents": .string(input),
                "recipient": .string(input == "old-recipient-approval" ? "recipient-v2" : "recipient-v1")])
            let call = ToolCall(id: .init(rawValue: "fixture-\(request.runID?.uuidString ?? "missing-run")"), name: name,
                argumentsJSON: String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self), completeness: .complete)
            try emit(.toolCallStarted(call.id, name: name)); try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
            try emit(.toolCallCompleted(call)); try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
        }
    }
}

private actor FixtureAuthorizer: AgentAuthorizer {
    let versions: FixtureVersions
    private var archivedApproval: Data?
    private(set) var evidenceDecisions = 0
    init(versions: FixtureVersions) { self.versions = versions }
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        if request.toolDefinition.name == FixtureEvidenceWrite.name { evidenceDecisions += 1 }
        let input: String
        if case .object(let object) = request.normalizedArguments, case .string(let value)? = object["contents"] { input = value }
        else { throw FixtureFailure.assertion("missing prepared contents") }
        if input == "old-recipient-approval" {
            return try JSONDecoder().decode(AuthorizationDecision.self, from: require(archivedApproval))
        }
        // Product confirmation belongs here once; tool.authorize below is a domain check.
        let human = input == "human"
        let decision = AuthorizationDecision(request: request, outcome: input == "deny" ? .deny : .allow,
            subject: .init(issuer: "fixture-host", subjectID: human ? "user-42" : "fixture-policy", type: human ? .human : .automatedPolicy),
            policy: .init(id: "fixture-exact-action", version: "1", ruleReferences: [human ? "simulated-confirmation" : "controlled-local-file"]),
            validFor: .seconds(30), hostDecisionTime: Date(), reasonCode: human ? "user_confirmed_action_version" : "fixture_rule",
            externalApprovalReference: human ? "fixture-confirmation-\(request.actionDigest)" : nil)
        if input == "automatic" { archivedApproval = try JSONEncoder().encode(decision) }
        if input.hasPrefix("change-") { versions.change(String(input.dropFirst("change-".count))) }
        return decision
    }
}

private final class FixtureVersions: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: String] = [:]
    func get(_ key: String) -> String { lock.withLock { values[key] ?? "1" } }
    func change(_ key: String) { lock.withLock { values[key] = "2" } }
    // Actual immutable attachment contents, with precomputed SHA-256 identifiers.
    // The fixture changes which version is selected while approval is outstanding.
    func materialSnapshot() -> (version: String, contents: String, digest: String) {
        get("material") == "1"
            ? ("1", "attachment-v1", "sha256:11d7cd861c56441e0c3c08eb53ac022a0edea166600cb93e5b6be219e387b985")
            : ("2", "attachment-v2", "sha256:e3f2d85d577cf0ffefef8f6dd57f773a3adc9faac5eafa75ddc87aba0cd95f59")
    }
    func reset() { lock.withLock { values.removeAll() } }
}

private actor FixtureProbe {
    private(set) var executions = 0; private(set) var effects = 0
    func execute(file: URL, input: FixtureWrite.Input, attachment: String, context: ToolContext) throws -> ToolReceipt {
        executions += 1
        let previous = (try? Data(contentsOf: file)) ?? Data()
        try (previous + Data("\(input.contents):\(input.recipient):\(attachment)\n".utf8)).write(to: file, options: .atomic)
        effects += 1
        return .init(operationID: context.idempotencyKey!, status: .succeeded,
            confirmedTargets: [.init(namespace: "fixture.file", id: input.id)], revision: "effect-\(effects)")
    }
}

private struct FixtureWrite: AgentTool {
    struct Input: Codable, Sendable { let id: String; let contents: String; let recipient: String }
    typealias Output = String
    static let name = "controlled_write"
    static let description = "Append to a disposable fixture file"
    static let inputSchema = ToolSchema.object(properties: ["id": .string, "contents": .string, "recipient": .string], required: ["id", "contents", "recipient"])
    static let outputSchema = ToolSchema.string
    let file: URL; let probe: FixtureProbe; let versions: FixtureVersions; let policy: ToolPolicy
    init(file: URL, probe: FixtureProbe, versions: FixtureVersions) throws {
        self.file = file; self.probe = probe; self.versions = versions
        policy = try .mutation(authorization: .required, evidence: .none)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "fixture.file", id: input.id))] }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "fixture.file", id: input.id)], revision: .present) }
    func authorizationBinding(for input: Input) throws -> ToolAuthorizationBinding {
        .init(definitionVersion: "1", implementationVersion: "fixture-1",
            backend: .init(instanceID: "fixture-\(versions.get("backend"))", version: "1", accountID: "fixture-account", credentialGeneration: "1"),
            resourceRevisions: [.init(resource: .named(.init(namespace: "fixture.file", id: input.id)), revision: versions.get("revision"))],
            materials: [.init(id: "immutable-attachment", version: versions.materialSnapshot().version, contentDigest: versions.materialSnapshot().digest)])
    }
    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization { input.id == "controlled" ? .allowed : .denied }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        // Real backends must verify versioned reads / conditional writes here, too.
        .init(output: "written", receipt: try await probe.execute(file: file, input: input, attachment: versions.materialSnapshot().contents, context: context))
    }
}

private struct FixtureEvidenceWrite: AgentTool {
    typealias Input = FixtureWrite.Input; typealias Output = String
    static let name = "evidence_write"; static let description = "Reject undiscovered fixture target"
    static let inputSchema = FixtureWrite.inputSchema; static let outputSchema = ToolSchema.string
    let probe: FixtureProbe; let policy = try! ToolPolicy.mutation(authorization: .notRequired)
    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] { [.init(reference: .init(namespace: "fixture.file", id: input.id))] }
    func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "fixture.file", id: input.id))] }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "fixture.file", id: input.id)], revision: .present) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> { throw FixtureFailure.assertion("Evidence must stop executor") }
}

/// Receiver example: owns destination and durable deduplication. No SDK-selected network service.
private struct FixtureAuditKey: Hashable, Sendable {
    let storeID: UUID; let recordID: UUID
    init(_ record: AuditExportRecord) { storeID = record.storeID; recordID = record.auditRecordID }
}

private actor FixtureJSONLSink: AuditExportSink {
    let file: URL; let loseFirstAcknowledgement: Bool
    private var lost = false
    private(set) var recordIDs: Set<FixtureAuditKey> = []
    private(set) var duplicates = 0
    init(at file: URL, loseFirstAcknowledgement: Bool) throws {
        self.file = file; self.loseFirstAcknowledgement = loseFirstAcknowledgement
        if FileManager.default.fileExists(atPath: file.path) {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                recordIDs.insert(FixtureAuditKey(try JSONDecoder().decode(AuditExportRecord.self, from: Data(line.utf8))))
            }
        } else { try Data().write(to: file) }
    }
    func write(_ batch: AuditExportBatch) async throws -> AuditExportAcknowledgement {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd()
        var accepted: [FixtureAuditKey] = []
        for record in batch.records {
            if recordIDs.contains(FixtureAuditKey(record)) { duplicates += 1; continue }
            try handle.write(contentsOf: JSONEncoder().encode(record) + Data([0x0A]))
            accepted.append(FixtureAuditKey(record))
        }
        try handle.synchronize(); recordIDs.formUnion(accepted)
        if loseFirstAcknowledgement, !lost { lost = true; throw FixtureFailure.disconnected }
        return .init(batch: batch)
    }
}
