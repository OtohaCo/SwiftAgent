import AgentCore
import Foundation

/// Schema-5 disk contract: typed facts, never inferred from ordinary tool output or events.
struct DiskAuditRecordV1: Codable {
    let version: Int
    let recordID: UUID
    let sequence: UInt64
    let journalRecordSequence: UInt64
    let sdkObservedAt: Date
    let links: AuditRecordLinks
    let kind: String
    let proposal: AuditProposal?
    let authorization: AuditAuthorizationEvaluation?
    let disposition: AuditExecutionDisposition?
    let result: AuditResultReference?
    let digest: String

    init(_ value: AuditRecord) {
        version = value.version; recordID = value.auditRecordID; sequence = value.sequence
        journalRecordSequence = value.journalRecordSequence; sdkObservedAt = value.sdkObservedAt
        links = value.links; digest = value.digest
        switch value.fact {
        case .proposal(let value): kind = "proposal"; proposal = value; authorization = nil; disposition = nil; result = nil
        case .authorization(let value): kind = "authorization"; proposal = nil; authorization = value; disposition = nil; result = nil
        case .disposition(let value): kind = "disposition"; proposal = nil; authorization = nil; disposition = value; result = nil
        case .result(let value): kind = "result"; proposal = nil; authorization = nil; disposition = nil; result = value
        }
    }

    func value() throws -> AuditRecord {
        let fact: AuditFact
        switch kind {
        case "proposal" where authorization == nil && disposition == nil && result == nil:
            guard let proposal else { throw AgentJournalError.invalidRecord }; fact = .proposal(proposal)
        case "authorization" where proposal == nil && disposition == nil && result == nil:
            guard let authorization else { throw AgentJournalError.invalidRecord }; fact = .authorization(authorization)
        case "disposition" where proposal == nil && authorization == nil && result == nil:
            guard let disposition else { throw AgentJournalError.invalidRecord }; fact = .disposition(disposition)
        case "result" where proposal == nil && authorization == nil && disposition == nil:
            guard let result else { throw AgentJournalError.invalidRecord }; fact = .result(result)
        default: throw AgentJournalError.invalidRecord
        }
        let record = AuditRecord(version: version, auditRecordID: recordID, sequence: sequence,
            journalRecordSequence: journalRecordSequence, sdkObservedAt: sdkObservedAt, links: links, fact: fact, digest: digest)
        try record.validate()
        return record
    }
}

struct AuditRecordPointer: Codable {
    let batchSequence: UInt64
    let offset: Int
}

struct AuditIndexSummary: Codable {
    let count: UInt64
    let lastSequence: UInt64
}
