import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

// Compiled by the separate client package. Replace this controlled rule with Host policy.
struct ExampleEnterpriseAuthorizer: AgentAuthorizer {
    let allowedToolNames: Set<String>
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        AuthorizationDecision(request: request,
            outcome: allowedToolNames.contains(request.toolDefinition.name) ? .allow : .deny,
            subject: .init(issuer: "example-host", subjectID: "local-rule", type: .automatedPolicy),
            policy: .init(id: "controlled-tools", version: "1", ruleReferences: ["exact-current-request"]),
            validFor: .seconds(30), reasonCode: "host_rule")
    }
}

func makeAuditedSession(directory: URL, operationDomain: String, model: ModelID,
                        provider: any ModelProvider, tools: [any AgentTool],
                        authorizer: any AgentAuthorizer,
                        identity: AgentAuthorizationIdentity) throws -> (AgentSession, AgentJournal) {
    let journal = try AgentIncrementalJournal.create(at: directory,
        operationDomain: operationDomain, supportsAuthorizationAudit: true)
    let agent = try Agent(model: model, provider: provider, tools: tools,
        configuration: .init(authorization: .init(mode: .requiredAudit,
            authorizer: authorizer, identity: identity)))
    return (try agent.makeSession(journal: journal), journal)
}

// Host destination adapter: the closure authenticates and durably deduplicates by
// (storeID, auditRecordID) before returning. No default destination or credentials.
struct ExampleEnterpriseSink: AuditExportSink {
    let acceptDurably: @Sendable (AuditExportBatch) async throws -> Void
    func write(_ batch: AuditExportBatch) async throws -> AuditExportAcknowledgement {
        try await acceptDurably(batch)
        return .init(batch: batch)
    }
}

func exportOnePass(journal: AgentJournal, sink: any AuditExportSink) async throws -> AuditExportStatus {
    let exporter = try await journal.startAuditExporter(configuration: .init(
        id: "enterprise-archive-v1", destinationID: "host-receiver",
        contentVersion: "1", redactionVersion: "conservative-v1"), sink: sink)
    try await exporter.waitForDrain()
    return await exporter.status()
}

// This is a Host-selected archive schema, independent of AuditExportBatch and its ACK.
// It intentionally excludes parameters, outputs, materials, policy rules and identity context.
struct ExampleSelectedAuthorizationArchiveRecord: Codable, Equatable, Sendable {
    let version: Int
    let storeID: UUID
    let auditRecordID: UUID
    let sequence: UInt64
    let committedDigest: String
    let subject: AuthorizationSubject
    let policyID: String
    let policyVersion: String
    let hostDecisionTime: Date?
    let sdkObservedAt: Date
}

// Only trusted Host management code calls this read-only path. A production adapter must
// authenticate access, durably deduplicate, version its selection/destination, and keep
// its own confirmed cursor/sequence after durable receipt. It never manufactures SDK ACKs.
func archiveSelectedAuthorizationMetadata(
    journal: AgentJournal, query: AuditQuery,
    acceptDurably: @Sendable ([ExampleSelectedAuthorizationArchiveRecord]) async throws -> Void
) async throws -> Int {
    var cursor: AuditCursor?, count = 0
    repeat {
        let page = try await journal.auditRecords(matching: query, limit: 2, cursor: cursor)
        let selected = page.records.compactMap { record -> ExampleSelectedAuthorizationArchiveRecord? in
            guard case .authorization(let evaluation) = record.fact,
                  evaluation.layer == .enterprise, let decision = evaluation.decision else { return nil }
            return .init(version: 1, storeID: record.links.storeID, auditRecordID: record.auditRecordID,
                sequence: record.sequence, committedDigest: record.digest, subject: decision.subject,
                policyID: decision.policy.id, policyVersion: decision.policy.version,
                hostDecisionTime: decision.hostDecisionTime, sdkObservedAt: record.sdkObservedAt)
        }
        if !selected.isEmpty { try await acceptDurably(selected); count += selected.count }
        cursor = page.nextCursor
    } while cursor != nil
    return count
}

// A pass-through redactor proves its input has already lost the fields below. It is
// not a hook that retrieves private Journal payloads or adds authenticated metadata.
final class ExampleSummaryExportProof: @unchecked Sendable, AuditExportRedactor {
    private let lock = NSLock()
    private let humanRecords: Set<UUID>
    private var observations = 0
    init(localRecords: [AuditRecord]) {
        humanRecords = Set(localRecords.compactMap { record in
            if case .authorization(let evaluation) = record.fact,
               evaluation.decision?.subject.type == .human { return record.auditRecordID }
            return nil
        })
    }
    func redact(_ record: AuditExportRecord) throws -> JSONValue {
        try validate(record)
        lock.withLock { observations += 1 }
        return record.view
    }
    func validate(_ record: AuditExportRecord) throws {
        let allowedKeys: Set<String> = ["sessionID", "runID", "invocationID", "proposalID",
            "authorizationID", "relatedProposalID", "kind", "stage", "reconstructable",
            "actionDigest", "layer", "status", "outcome", "subjectType", "state",
            "referenceKind", "sourceRunID", "outputDigest"]
        guard case .object(let view) = record.view, Set(view.keys).isSubset(of: allowedKeys) else {
            throw ExampleArchiveProofError.unexpectedExportFields
        }
        if humanRecords.contains(record.auditRecordID) {
            guard view["subjectType"] == .string("human"), view["outcome"] == .string("allow") else {
                throw ExampleArchiveProofError.missingHumanSummary
            }
        }
    }
    var observedRecords: Int { lock.withLock { observations } }
}

enum ExampleArchiveProofError: Error { case unexpectedExportFields, missingHumanSummary }

actor ExampleSelectedArchiveSink {
    private struct Key: Hashable { let storeID: UUID; let auditRecordID: UUID }
    private let file: URL
    private var accepted: Set<Key> = []
    init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                let record = try JSONDecoder().decode(ExampleSelectedAuthorizationArchiveRecord.self, from: Data(line.utf8))
                accepted.insert(Key(storeID: record.storeID, auditRecordID: record.auditRecordID))
            }
        } else { try Data().write(to: file) }
    }
    func write(_ records: [ExampleSelectedAuthorizationArchiveRecord]) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var newKeys: Set<Key> = []
        for record in records {
            let key = Key(storeID: record.storeID, auditRecordID: record.auditRecordID)
            guard !accepted.contains(key), newKeys.insert(key).inserted else { continue }
            try handle.write(contentsOf: JSONEncoder().encode(record) + Data([0x0A]))
        }
        try handle.synchronize()
        accepted.formUnion(newKeys)
    }
}
