import AgentCore
import Foundation

// Queue payload DTOs introduced with the unreleased schema-2 candidate.
// Format schema 3 retains them and adds per-key index witnesses; older
// readers reject format.json before decoding these records.
struct DiskFollowUpV2: Codable {
    let sessionID: UUID
    let ordinal: UInt64
    let inputID: String
    let text: String
    let operationID: String
    let configurationRef: String
    let status: String
    let runID: UUID?
    let formalMessageID: UUID?

    init(_ value: JournalStoredFollowUp) {
        sessionID = value.sessionID
        ordinal = value.ordinal
        inputID = value.input.inputID
        text = value.input.text
        operationID = value.input.operationID
        configurationRef = value.input.configurationRef
        switch value.state {
        case .queued: status = "queued"; runID = nil; formalMessageID = nil
        case .withdrawn: status = "withdrawn"; runID = nil; formalMessageID = nil
        case .admitted(let run, let message):
            status = "admitted"; runID = run; formalMessageID = message
        }
    }

    func value() throws -> JournalStoredFollowUp {
        let input = AgentFollowUpInput(inputID: inputID, text: text,
                                      operationID: operationID, configurationRef: configurationRef)
        try input.validate()
        let state: AgentFollowUpState
        switch status {
        case "queued":
            guard runID == nil, formalMessageID == nil else { throw AgentJournalError.invalidRecord }
            state = .queued
        case "withdrawn":
            guard runID == nil, formalMessageID == nil else {
                throw AgentJournalError.invalidRecord
            }
            state = .withdrawn
        case "admitted":
            guard let runID, let formalMessageID else {
                throw AgentJournalError.invalidRecord
            }
            state = .admitted(runID: runID, formalMessageID: formalMessageID)
        default: throw AgentJournalError.unsupportedFormat
        }
        return JournalStoredFollowUp(sessionID: sessionID, ordinal: ordinal,
                                     input: input, state: state)
    }
}

struct DiskFollowUpLinkV2: Codable {
    let ordinal: UInt64
    let next: UInt64?
    init(_ value: JournalFollowUpLink) { ordinal = value.ordinal; next = value.next }
    func value() throws -> JournalFollowUpLink {
        guard next.map({ $0 > ordinal }) ?? true else { throw AgentJournalError.invalidRecord }
        return .init(ordinal: ordinal, next: next)
    }
}

struct DiskFollowUpHeadV2: Codable {
    let revision: UInt64
    let nextOrdinal: UInt64
    let queuedCount: Int
    let queuedBytes: Int
    let firstQueued: UInt64?
    let lastQueued: UInt64?
    let lastAdmitted: UInt64?
    let lastReleased: UInt64?

    init(_ value: JournalFollowUpHead) {
        revision = value.revision; nextOrdinal = value.nextOrdinal
        queuedCount = value.queuedCount; queuedBytes = value.queuedBytes
        firstQueued = value.firstQueued; lastQueued = value.lastQueued
        lastAdmitted = value.lastAdmitted; lastReleased = value.lastReleased
    }

    func value() throws -> JournalFollowUpHead {
        guard queuedCount >= 0, queuedCount <= 128,
              queuedBytes >= 0, queuedBytes <= 8 * 1024 * 1024,
              (firstQueued == nil) == (queuedCount == 0),
              (lastQueued == nil) == (queuedCount == 0),
              firstQueued.map({ $0 < nextOrdinal }) ?? true,
              lastQueued.map({ $0 < nextOrdinal }) ?? true,
              lastAdmitted.map({ $0 < nextOrdinal }) ?? true,
              lastReleased.map({ $0 < nextOrdinal }) ?? true,
              lastReleased == nil || lastAdmitted != nil,
              lastReleased.map({ released in lastAdmitted.map { released <= $0 } ?? false }) ?? true else {
            throw AgentJournalError.invalidRecord
        }
        return .init(revision: revision, nextOrdinal: nextOrdinal,
                     queuedCount: queuedCount, queuedBytes: queuedBytes,
                     firstQueued: firstQueued, lastQueued: lastQueued,
                     lastAdmitted: lastAdmitted, lastReleased: lastReleased)
    }
}
