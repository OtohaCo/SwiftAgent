import AgentCore
import Foundation

/// Explicit disk DTOs, independent of public Codable synthesis.
struct DiskRunAdmissionV1: Codable {
    let storeID: UUID
    let sessionID: UUID
    let runID: UUID
    let formalMessageID: UUID
    let formalMessageOrdinal: UInt64
    let correlationKey: String?
    let hostPayloadDigest: String?
    let followUpInputID: String?
    let payloadFingerprint: String

    init(storeID: UUID, sessionID: UUID, runID: UUID, formalMessageID: UUID, formalMessageOrdinal: UInt64,
         admission: JournalRunAdmission, followUpInputID: String?) {
        self.storeID = storeID; self.sessionID = sessionID; self.runID = runID
        self.formalMessageOrdinal = formalMessageOrdinal
        self.formalMessageID = formalMessageID; self.followUpInputID = followUpInputID
        correlationKey = admission.correlation?.key; hostPayloadDigest = admission.correlation?.payloadDigest
        payloadFingerprint = admission.payloadFingerprint
    }

    func value() throws -> JournalStoredRun {
        guard payloadFingerprint.utf8.count == 64, payloadFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (correlationKey == nil) == (hostPayloadDigest == nil) else { throw AgentJournalError.invalidRecord }
        let correlation: AgentRunCorrelation?
        if let key = correlationKey, let digest = hostPayloadDigest {
            do { correlation = try AgentRunCorrelation(key: key, payloadDigest: digest) }
            catch { throw AgentJournalError.invalidRecord }
        } else {
            correlation = nil
        }
        return .init(record: .init(storeID: storeID, sessionID: sessionID, runID: runID, formalMessageID: formalMessageID,
                                  correlation: correlation, followUpInputID: followUpInputID), payloadFingerprint: payloadFingerprint)
    }
}

struct DiskRunTerminalV1: Codable {
    let runID: UUID
    let kind: String
    let reason: String?

    init(runID: UUID, terminal: AgentRunTerminal) {
        self.runID = runID
        switch terminal {
        case .completed: kind = "completed"; reason = nil
        case .refused: kind = "refused"; reason = nil
        case .cancelled: kind = "cancelled"; reason = nil
        case .incomplete(let value): kind = "incomplete"; reason = value.rawValue
        case .failed(let value): kind = "failed"; reason = value.rawValue
        }
    }

    func value() throws -> AgentRunTerminal {
        switch (kind, reason) {
        case ("completed", nil): return .completed
        case ("refused", nil): return .refused
        case ("cancelled", nil): return .cancelled
        case ("incomplete", let reason?):
            guard let reason = AgentRunTerminal.IncompleteReason(rawValue: reason) else { throw AgentJournalError.unsupportedFormat }
            return .incomplete(reason)
        case ("failed", let reason?):
            guard let reason = AgentRunTerminal.FailureCategory(rawValue: reason) else { throw AgentJournalError.unsupportedFormat }
            return .failed(reason)
        default: throw AgentJournalError.invalidRecord
        }
    }
}
