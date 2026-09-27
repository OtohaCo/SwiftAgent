import Foundation

/// Stable caller identity and exact request payload; never an authorization.
public struct AgentFollowUpInput: Equatable, Sendable {
    public let inputID: String
    public let text: String
    public let operationID: String
    public let configurationRef: String

    public init(inputID: String, text: String, operationID: String, configurationRef: String) {
        self.inputID = inputID
        self.text = text
        self.operationID = operationID
        self.configurationRef = configurationRef
    }

    package func validate() throws {
        guard !inputID.isEmpty, inputID.utf8.count <= 128,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 256 * 1024,
              !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              operationID.utf8.count <= 256,
              !configurationRef.isEmpty, configurationRef.utf8.count <= 128,
              !inputID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !configurationRef.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentFollowUpError.invalidInput
        }
    }

    package func matches(_ other: Self) -> Bool {
        inputID.utf8.elementsEqual(other.inputID.utf8)
            && text.utf8.elementsEqual(other.text.utf8)
            && operationID.utf8.elementsEqual(other.operationID.utf8)
            && configurationRef.utf8.elementsEqual(other.configurationRef.utf8)
    }
}

public enum AgentFollowUpState: Equatable, Sendable {
    case queued
    case admitted(runID: UUID, formalMessageID: UUID)
    case withdrawn
}

public struct AgentFollowUpRecord: Equatable, Sendable {
    public let storeID: UUID
    public let sessionID: UUID
    public let inputID: String
    public let ordinal: UInt64
    public let state: AgentFollowUpState
    public let operationID: String
    public let configurationRef: String

    public init(storeID: UUID, sessionID: UUID, inputID: String, ordinal: UInt64,
                state: AgentFollowUpState, operationID: String, configurationRef: String) {
        self.storeID = storeID
        self.sessionID = sessionID
        self.inputID = inputID
        self.ordinal = ordinal
        self.state = state
        self.operationID = operationID
        self.configurationRef = configurationRef
    }
}

public enum AgentFollowUpWithdrawal: Equatable, Sendable {
    case withdrawn
    case alreadyAdmitted(runID: UUID, formalMessageID: UUID)
}

public enum AgentFollowUpError: Error, Equatable, Sendable {
    case durableJournalRequired
    case invalidInput
    case inputConflict
    case queueFull
    case missingInput
    case dispatchOwned
    case alreadyDispatching
    case dispatcherStopped
    case staleDispatch
}

package struct JournalFollowUpHead: Codable, Equatable, Sendable {
    package var revision: UInt64
    package var nextOrdinal: UInt64
    package var queuedCount: Int
    package var queuedBytes: Int
    package var firstQueued: UInt64?
    package var lastQueued: UInt64?

    package init(revision: UInt64 = 0, nextOrdinal: UInt64 = 0,
                 queuedCount: Int = 0, queuedBytes: Int = 0,
                 firstQueued: UInt64? = nil, lastQueued: UInt64? = nil) {
        self.revision = revision; self.nextOrdinal = nextOrdinal
        self.queuedCount = queuedCount; self.queuedBytes = queuedBytes
        self.firstQueued = firstQueued; self.lastQueued = lastQueued
    }
}

package struct JournalStoredFollowUp: Equatable, Sendable {
    package var sessionID: UUID
    package var ordinal: UInt64
    package var input: AgentFollowUpInput
    package var state: AgentFollowUpState
    package var nextQueued: UInt64?

    package init(sessionID: UUID, ordinal: UInt64, input: AgentFollowUpInput,
                 state: AgentFollowUpState, nextQueued: UInt64? = nil) {
        self.sessionID = sessionID; self.ordinal = ordinal; self.input = input
        self.state = state; self.nextQueued = nextQueued
    }

    package func publicRecord(storeID: UUID) -> AgentFollowUpRecord {
        AgentFollowUpRecord(storeID: storeID, sessionID: sessionID,
                            inputID: input.inputID, ordinal: ordinal, state: state,
                            operationID: input.operationID, configurationRef: input.configurationRef)
    }
}

package struct JournalFollowUpChange: Sendable {
    package let sessionID: UUID
    package let expectedRevision: UInt64
    package let head: JournalFollowUpHead
    package let records: [JournalStoredFollowUp]

    package init(sessionID: UUID, expectedRevision: UInt64, head: JournalFollowUpHead,
                 records: [JournalStoredFollowUp]) {
        self.sessionID = sessionID; self.expectedRevision = expectedRevision
        self.head = head; self.records = records
    }
}

package struct JournalFollowUpAdmission: Sendable {
    package let inputID: String
    package let expectedQueueRevision: UInt64

    package init(inputID: String, expectedQueueRevision: UInt64) {
        self.inputID = inputID; self.expectedQueueRevision = expectedQueueRevision
    }
}
