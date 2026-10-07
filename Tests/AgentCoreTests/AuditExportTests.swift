import AgentJournalFileStore
import Foundation
import AgentModels
import Testing
@testable import AgentCore

struct AuditExportTests {
    @Test func lostAckResendsStableRecordsAndCheckpointSurvivesReopen() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "export", supportsAuthorizationAudit: true)
        try await seedExportFacts(journal, count: 5)
        let sink = ExportTestSink(loseFirstAck: true, partial: true)
        let configuration = AuditExportConfiguration(id: "archive-v1", destinationID: "fixture-file", contentVersion: "1",
            redactionVersion: "safe-v1", pageSize: 3, maximumAttempts: 3, retryDelay: .zero)
        let exporter = try await journal.startAuditExporter(configuration: configuration, sink: sink)
        try await exporter.waitForDrain()
        let status = await exporter.status()
        #expect(status.acknowledgedThroughSequence == 5)
        #expect(await sink.uniqueRecordIDs.count == 5)
        #expect(await sink.writes > 2)
        let batchIDs = await sink.firstBatchIDs
        #expect(batchIDs.prefix(2).allSatisfy { $0 == batchIDs.first })
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restarted = try await reopened.startAuditExporter(configuration: configuration, sink: sink)
        try await restarted.waitForDrain()
        #expect(await restarted.status().acknowledgedThroughSequence == 5)
        await #expect(throws: AgentAuthorizationError.cursorMismatch) {
            try await reopened.startAuditExporter(configuration: .init(id: "archive-v1", destinationID: "other",
                contentVersion: "1", redactionVersion: "safe-v1"), sink: sink)
        }
        try await reopened.close()
    }

    @Test func invalidAckDoesNotAdvanceAndRegularExportOmitsRestrictedPayload() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "export", supportsAuthorizationAudit: true)
        try await seedExportFacts(journal, count: 1)
        let sink = ExportTestSink(invalidAck: true)
        let exporter = try await journal.startAuditExporter(configuration: .init(id: "archive", destinationID: "fixture",
            contentVersion: "1", redactionVersion: "safe-v1", maximumAttempts: 1), sink: sink)
        try await exporter.waitForDrain()
        #expect(await exporter.status().acknowledgedThroughSequence == 0)
        #expect(await exporter.status().lastFailure == .invalidAcknowledgement)
        let payload = try #require(await sink.jsonl.first)
        #expect(!payload.contains("fixture-secret-token"))
        #expect(!payload.contains("rawArgumentsJSON"))
        try await journal.close()
    }
    @Test(arguments: ["exporterID", "batchID", "storeID", "destinationID", "contentVersion", "configurationDigest", "contentDigest"])
    func mismatchedAcknowledgementCannotAdvanceAConfiguration(_ field: String) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "ack", supportsAuthorizationAudit: true)
        try await seedExportFacts(journal, count: 2)
        let exporter = try await journal.startAuditExporter(configuration: .init(id: "ack", destinationID: "fixture",
            contentVersion: "1", redactionVersion: "1", maximumAttempts: 1), sink: MismatchedAuditSink(field: field))
        try await exporter.waitForDrain()
        #expect(await exporter.status().lastFailure == .invalidAcknowledgement)
        #expect(await exporter.status().acknowledgedThroughSequence == 0)
        try await journal.close()
    }

    @Test func repeatedOldAckKeepsOnlyTheConfirmedPrefixAndRestartRedeliversTheRest() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "duplicate-ack", supportsAuthorizationAudit: true)
        try await seedExportFacts(journal, count: 3)
        let configuration = AuditExportConfiguration(id: "ack", destinationID: "fixture", contentVersion: "1", redactionVersion: "1", maximumAttempts: 1)
        let exporter = try await journal.startAuditExporter(configuration: configuration, sink: RepeatedAuditAckSink())
        try await exporter.waitForDrain()
        #expect(await exporter.status().acknowledgedThroughSequence == 1)
        #expect(await exporter.status().lastFailure == .invalidAcknowledgement)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let sink = ExportTestSink()
        let resumed = try await reopened.startAuditExporter(configuration: configuration, sink: sink)
        try await resumed.waitForDrain()
        #expect(await resumed.status().acknowledgedThroughSequence == 3)
        #expect(await sink.uniqueRecordIDs.count == 2)
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func checkpointPublicationFailureReopensTheActualRootWithoutLosingRecords(_ unknown: Bool) async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = AuditExportCommitFault(unknown: unknown)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "export-commit",
            supportsAuthorizationAudit: true, fault: { try fault.check($0) })
        try await seedExportFacts(journal, count: 3)
        let configuration = AuditExportConfiguration(id: "fault", destinationID: "fixture", contentVersion: "1", redactionVersion: "1")
        let exporter = try await journal.startAuditExporter(configuration: configuration, sink: ArmingAuditSink(fault: fault))
        try await exporter.waitForDrain()
        let status = await exporter.status()
        #expect(status.lastFailure == .auditUnavailable)
        if unknown { #expect(status.journalFailure == .commitUnknown) }
        #expect(status.acknowledgedThroughSequence == 0)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let sink = ExportTestSink()
        let resumed = try await reopened.startAuditExporter(configuration: configuration, sink: sink)
        try await resumed.waitForDrain()
        #expect(await resumed.status().acknowledgedThroughSequence == 3)
        #expect(await sink.uniqueRecordIDs.count == (unknown ? 0 : 3))
        #expect(try await reopened.auditRecords().records.count == 3)
        try await reopened.close()
    }

    @Test func redactionFailureSendsNothingAndNeverModifiesRestrictedHistory() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "redaction", supportsAuthorizationAudit: true)
        try await seedExportFacts(journal, count: 1)
        let before = try await journal.auditRecords(includeRestrictedPayload: true)
        let sink = ExportTestSink()
        let exporter = try await journal.startAuditExporter(configuration: .init(id: "redact", destinationID: "fixture",
            contentVersion: "1", redactionVersion: "reject"), sink: sink, redactor: RejectingAuditRedactor())
        try await exporter.waitForDrain()
        #expect(await exporter.status().lastFailure == .redactionFailed)
        #expect(await sink.writes == 0)
        #expect(try await journal.auditRecords(includeRestrictedPayload: true).records == before.records)
        try await journal.close()
    }

}

func seedExportFacts(_ journal: AgentJournal, count: Int) async throws {
    let identity = try #require(await journal.storeIdentity())
    var drafts: [JournalAuditDraft] = []
    for _ in 0..<count {
        let links = AuditRecordLinks(storeID: identity.storeID, operationDomain: identity.operationDomain,
            sessionID: UUID(), runID: UUID(), invocationID: UUID(), modelCallID: "call", proposalID: UUID())
        let proposal = AuditProposal(stage: .received, toolName: "fixture", rawArgumentsJSON: #"{"token":"fixture-secret-token"}"#,
            normalizedArguments: nil, originalUTF8Bytes: 32, payloadTruncated: false, reconstructable: true,
            definition: nil, policy: nil, binding: nil, resources: nil, receiptExpectation: nil, actionDigest: nil,
            identity: nil, scope: nil)
        drafts.append(.init(links: links, fact: .proposal(proposal)))
    }
    // These fixtures need a populated backlog, not one disk transaction per fact.
    // Keep every record while avoiding timeout races at a paused application hook.
    if !drafts.isEmpty { try await journal.appendAudit(drafts) }
}

actor ExportTestSink: AuditExportSink {
    let loseFirstAck: Bool
    let partial: Bool
    let invalidAck: Bool
    private(set) var writes = 0
    private(set) var uniqueRecordIDs: Set<UUID> = []
    private(set) var firstBatchIDs: [UUID] = []
    private(set) var jsonl: [String] = []
    init(loseFirstAck: Bool = false, partial: Bool = false, invalidAck: Bool = false) {
        self.loseFirstAck = loseFirstAck; self.partial = partial; self.invalidAck = invalidAck
    }
    func write(_ batch: AuditExportBatch) async throws -> AuditExportAcknowledgement {
        writes += 1; firstBatchIDs.append(batch.batchID)
        jsonl.append(String(decoding: try batch.jsonlData(), as: UTF8.self))
        for record in batch.records { uniqueRecordIDs.insert(record.auditRecordID) }
        if loseFirstAck, writes == 1 { throw FixtureError.invalidOperation }
        if invalidAck { return .init(batch: batch, throughSequence: batch.throughSequence + 1) }
        return .init(batch: batch, throughSequence: partial ? batch.firstSequence : batch.throughSequence)
    }
}

private struct MismatchedAuditSink: AuditExportSink {
    let field: String
    func write(_ batch: AuditExportBatch) async throws -> AuditExportAcknowledgement {
        let data = try JSONEncoder().encode(AuditExportAcknowledgement(batch: batch))
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object[field] = field.hasSuffix("ID") && field != "destinationID" ? UUID().uuidString : "wrong"
        return try JSONDecoder().decode(AuditExportAcknowledgement.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
private actor RepeatedAuditAckSink: AuditExportSink {
    private var first: AuditExportAcknowledgement?
    func write(_ batch: AuditExportBatch) async throws -> AuditExportAcknowledgement {
        if let first { return first }
        let ack = AuditExportAcknowledgement(batch: batch, throughSequence: batch.firstSequence)
        first = ack; return ack
    }
}
private struct RejectingAuditRedactor: AuditExportRedactor {
    func redact(_ record: AuditExportRecord) throws -> JSONValue { throw FixtureError.invalidOperation }
}

private final class AuditExportCommitFault: @unchecked Sendable {
    let unknown: Bool
    private let lock = NSLock(); private var armed = false
    init(unknown: Bool) { self.unknown = unknown }
    func arm() { lock.withLock { armed = true } }
    func check(_ stage: JournalFileFaultStage) throws {
        let eligible: Bool
        if unknown { if case .afterCurrentReplace = stage { eligible = true } else { eligible = false } }
        else { if case .beforeAppend = stage { eligible = true } else { eligible = false } }
        guard eligible else { return }
        if lock.withLock({ let value = armed; armed = false; return value }) {
            throw AgentJournalError.persistenceUnavailable("controlled export checkpoint failure")
        }
    }
}
private struct ArmingAuditSink: AuditExportSink {
    let fault: AuditExportCommitFault
    func write(_ batch: AuditExportBatch) async throws -> AuditExportAcknowledgement { fault.arm(); return .init(batch: batch) }
}
