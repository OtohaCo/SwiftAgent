import AgentCore
import Foundation

// Queue-specific schema-2 DTOs. Old schema-1 readers reject format.json
// before they can misinterpret these records as ordinary Session commits.
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
    let nextQueued: UInt64?

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
        nextQueued = value.nextQueued
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
            guard runID == nil, formalMessageID == nil, nextQueued == nil else {
                throw AgentJournalError.invalidRecord
            }
            state = .withdrawn
        case "admitted":
            guard let runID, let formalMessageID, nextQueued == nil else {
                throw AgentJournalError.invalidRecord
            }
            state = .admitted(runID: runID, formalMessageID: formalMessageID)
        default: throw AgentJournalError.unsupportedFormat
        }
        return JournalStoredFollowUp(sessionID: sessionID, ordinal: ordinal,
                                     input: input, state: state, nextQueued: nextQueued)
    }
}

struct DiskFollowUpHeadV2: Codable {
    let revision: UInt64
    let nextOrdinal: UInt64
    let queuedCount: Int
    let queuedBytes: Int
    let firstQueued: UInt64?
    let lastQueued: UInt64?

    init(_ value: JournalFollowUpHead) {
        revision = value.revision; nextOrdinal = value.nextOrdinal
        queuedCount = value.queuedCount; queuedBytes = value.queuedBytes
        firstQueued = value.firstQueued; lastQueued = value.lastQueued
    }

    func value() throws -> JournalFollowUpHead {
        guard queuedCount >= 0, queuedCount <= 128,
              queuedBytes >= 0, queuedBytes <= 8 * 1024 * 1024,
              (firstQueued == nil) == (queuedCount == 0),
              (lastQueued == nil) == (queuedCount == 0),
              firstQueued.map({ $0 < nextOrdinal }) ?? true,
              lastQueued.map({ $0 < nextOrdinal }) ?? true else {
            throw AgentJournalError.invalidRecord
        }
        return .init(revision: revision, nextOrdinal: nextOrdinal,
                     queuedCount: queuedCount, queuedBytes: queuedBytes,
                     firstQueued: firstQueued, lastQueued: lastQueued)
    }
}
