import AgentModels
import Foundation

/// Host-declared stable payload identity. It is not a frozen runtime binding or authority.
public struct AgentRunCorrelation: Hashable, Sendable {
    public let key: String
    public let payloadDigest: String

    /// ASCII letters/digits and `._:/-`; key 1...128 bytes, digest 1...256 bytes.
    public init(key: String, payloadDigest: String) throws {
        guard Self.valid(key, limit: 128), Self.valid(payloadDigest, limit: 256) else {
            throw AgentRunAdmissionError.invalidCorrelation
        }
        self.key = key; self.payloadDigest = payloadDigest
    }

    package static func valid(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [46, 95, 58, 47, 45].contains($0)
        }
    }
}

public struct AgentRunRecord: Equatable, Sendable {
    public let storeID: UUID
    public let sessionID: UUID
    public let runID: UUID
    public let formalMessageID: UUID
    public let correlation: AgentRunCorrelation?
    public let followUpInputID: String?
    package init(storeID: UUID, sessionID: UUID, runID: UUID, formalMessageID: UUID,
                 correlation: AgentRunCorrelation?, followUpInputID: String?) {
        self.storeID = storeID; self.sessionID = sessionID; self.runID = runID
        self.formalMessageID = formalMessageID; self.correlation = correlation; self.followUpInputID = followUpInputID
    }
}

/// Bounded, sanitized logical facts; none asserts physical drain or business fulfillment.
public enum AgentRunTerminal: Equatable, Codable, Sendable {
    public enum IncompleteReason: String, Codable, Sendable {
        case modelTurnLimit, toolCallLimit, deadline, maxOutputTokens, stopSequence, other
    }
    public enum FailureCategory: String, Codable, Sendable {
        case provider, modelProtocol, tool, journal, authorization, auditPersistence, context, runtime, other
    }
    case completed
    case refused
    case incomplete(IncompleteReason)
    case cancelled
    case failed(FailureCategory)

    package static func from(_ result: Result<AgentLoopResult, any Error>) -> Self {
        switch result {
        case .success(let result):
            switch result.outcome {
            case .completed: return .completed
            case .refused: return .refused
            case .incomplete(let reason):
                switch reason {
                case .maxOutputTokens: return .incomplete(.maxOutputTokens)
                case .stopSequence: return .incomplete(.stopSequence)
                case .cancelled: return .cancelled
                case .refusal: return .refused
                default: return .incomplete(.other)
                }
            }
        case .failure(let error):
            switch AgentFailure(error) {
            case .cancelled: return .cancelled
            case .loop(.modelTurnLimitReached): return .incomplete(.modelTurnLimit)
            case .loop(.toolCallLimitReached): return .incomplete(.toolCallLimit)
            case .loop(.deadlineExceeded): return .incomplete(.deadline)
            case .provider: return .failed(.provider)
            case .modelStream: return .failed(.modelProtocol)
            case .journal, .mutationPersistence: return .failed(.journal)
            case .authorization: return .failed(.authorization)
            case .auditPersistence: return .failed(.auditPersistence)
            case .context, .contextPipeline, .contextProjection: return .failed(.context)
            case .toolRegistry, .toolInvocation, .receipt, .evidence, .noEffect, .resource, .scheduler: return .failed(.tool)
            case .loop, .session, .modelBinding, .capability: return .failed(.runtime)
            case .unclassified: return .failed(.other)
            }
        }
    }
}

public enum AgentRunLookup: Equatable, Sendable {
    case notAdmitted
    case admitted(AgentRunRecord)
    case terminal(AgentRunRecord, AgentRunTerminal)
}

public enum AgentRunAdmissionError: Error, Equatable, Sendable {
    case invalidCorrelation
    case alreadyAdmitted(AgentRunRecord)
    case conflict(AgentRunRecord)
    /// No committed record is being claimed; retry/query after the current startup resolves.
    case admissionInProgress
}

package struct JournalRunAdmission: Sendable {
    package let correlation: AgentRunCorrelation?
    package let payloadFingerprint: String
}

package struct JournalStoredRun: Sendable {
    package let record: AgentRunRecord
    package let payloadFingerprint: String
    package init(record: AgentRunRecord, payloadFingerprint: String) {
        self.record = record; self.payloadFingerprint = payloadFingerprint
    }
}
extension AgentJournal {
    private func runRecordStore() throws -> any JournalStore {
        guard let store, supportsRunRecords else { throw AgentJournalError.unsupportedFormat }
        guard !closing else { throw AgentJournalError.storeClosed }
        return store
    }

    public func runRecord(sessionID: UUID, correlationKey: String) throws -> AgentRunLookup {
        guard AgentRunCorrelation.valid(correlationKey, limit: 128) else { throw AgentRunAdmissionError.invalidCorrelation }
        let store = try runRecordStore()
        return try store.read { view in
            guard let stored = try view.runRecord(sessionID: sessionID, correlationKey: correlationKey) else { return .notAdmitted }
            if let terminal = try view.runTerminal(sessionID: sessionID, runID: stored.record.runID) {
                return .terminal(stored.record, terminal)
            }
            return .admitted(stored.record)
        }
    }

    public func runRecord(sessionID: UUID, runID: UUID) throws -> AgentRunLookup {
        let store = try runRecordStore()
        return try store.read { view in
            guard let stored = try view.runRecord(sessionID: sessionID, runID: runID) else { return .notAdmitted }
            if let terminal = try view.runTerminal(sessionID: sessionID, runID: runID) {
                return .terminal(stored.record, terminal)
            }
            return .admitted(stored.record)
        }
    }

    package func prepareRunAdmission(sessionID: UUID, text: String, operationID: String?, correlation: AgentRunCorrelation?) throws -> JournalRunAdmission? {
        guard supportsRunRecords else {
            if correlation != nil { throw AgentJournalError.unsupportedFormat }
            return nil
        }
        let store = try runRecordStore()
        // JSON is unambiguous and binds the actual exact formal text independently of Host assertions.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload: [String: String] = ["text": text, "operation": operationID ?? "", "hasOperation": operationID == nil ? "false" : "true", "hostDigest": correlation?.payloadDigest ?? ""]
        let fingerprint = store.auditDigest(try encoder.encode(payload))
        if let correlation {
            try store.read { view in
                if let prior = try view.runRecord(sessionID: sessionID, correlationKey: correlation.key) {
                    guard prior.payloadFingerprint == fingerprint, prior.record.correlation == correlation else { throw AgentRunAdmissionError.conflict(prior.record) }
                    throw AgentRunAdmissionError.alreadyAdmitted(prior.record)
                }
            }
        }
        return .init(correlation: correlation, payloadFingerprint: fingerprint)
    }
}

extension AgentJournal {
    package func commitRunTerminal(history: [ModelMessage], sessionID: UUID, runID: UUID, terminal: AgentRunTerminal) throws {
        let store = try runRecordStore()
        let steeringIDs = try store.read { try $0.header(sessionID)?.steeringIDs ?? [] }
        try appendCheckpointForCurrentRun([.checkpoint(history: history, steeringIDs: steeringIDs), .runTerminated(terminal)],
            sessionID: sessionID, runID: runID, durability: .durable, runTerminal: terminal)
    }
}
