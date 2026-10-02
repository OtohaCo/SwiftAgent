import Foundation

/// Mutation identity for one Run. This is not authorization or automatic recovery.
public enum AgentOperationIdentity: Equatable, Sendable {
    /// Each new call uses the existing Run ID / call ID identity.
    case perCall
    /// Equal semantic calls in this store reuse the same logical operation receipt.
    case operation(String)

    public var operationID: String? {
        if case .operation(let id) = self { return id }
        return nil
    }

    package func matches(_ other: Self) -> Bool {
        switch (self, other) {
        case (.perCall, .perCall): return true
        case (.operation(let a), .operation(let b)): return a.utf8.elementsEqual(b.utf8)
        default: return false
        }
    }
}

/// Stable caller identity and exact request payload; never an authorization.
public struct AgentFollowUpInput: Equatable, Sendable {
    public let inputID: String
    public let text: String
    public let identity: AgentOperationIdentity
    /// nil for perCall; the exact caller ID for operation mode.
    public var operationID: String? { identity.operationID }
    public let configurationRef: String

    public init(inputID: String, text: String, operationID: String, configurationRef: String) {
        self.inputID = inputID
        self.text = text
        self.identity = .operation(operationID)
        self.configurationRef = configurationRef
    }

    public init(inputID: String, text: String, identity: AgentOperationIdentity, configurationRef: String) {
        self.inputID = inputID; self.text = text
        self.identity = identity; self.configurationRef = configurationRef
    }

    package func validate() throws {
        if let operationID, operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || operationID.utf8.count > 256 {
            throw AgentFollowUpError.invalidInput
        }
        guard !inputID.isEmpty, inputID.utf8.count <= 128,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 256 * 1024,
              !configurationRef.isEmpty, configurationRef.utf8.count <= 128,
              !inputID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !configurationRef.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentFollowUpError.invalidInput
        }
    }

    package func matches(_ other: Self) -> Bool {
        inputID.utf8.elementsEqual(other.inputID.utf8)
            && text.utf8.elementsEqual(other.text.utf8)
            && identity.matches(other.identity)
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
    public let identity: AgentOperationIdentity
    /// nil for perCall; the exact caller ID for operation mode.
    public var operationID: String? { identity.operationID }
    public let configurationRef: String

    public init(storeID: UUID, sessionID: UUID, inputID: String, ordinal: UInt64,
                state: AgentFollowUpState, operationID: String, configurationRef: String) {
        self.storeID = storeID
        self.sessionID = sessionID
        self.inputID = inputID
        self.ordinal = ordinal
        self.state = state
        self.identity = .operation(operationID)
        self.configurationRef = configurationRef
    }
    public init(storeID: UUID, sessionID: UUID, inputID: String, ordinal: UInt64,
                state: AgentFollowUpState, identity: AgentOperationIdentity, configurationRef: String) {
        self.storeID = storeID; self.sessionID = sessionID; self.inputID = inputID
        self.ordinal = ordinal; self.state = state; self.identity = identity
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
    case needsInspection
}

/// Produced only by the atomic startup publication after reading the actual
/// selected input. It is not a general concurrent-writer escape hatch.
package enum JournalFollowUpAdmissionError: Error, Equatable, Sendable {
    case withdrawn(storeID: UUID, sessionID: UUID, inputID: String, ordinal: UInt64)
}

package struct JournalFollowUpHead: Codable, Equatable, Sendable {
    package var revision: UInt64
    package var nextOrdinal: UInt64
    package var queuedCount: Int
    package var queuedBytes: Int
    package var firstQueued: UInt64?
    package var lastQueued: UInt64?
    package var lastAdmitted: UInt64?
    package var lastReleased: UInt64?

    package init(revision: UInt64 = 0, nextOrdinal: UInt64 = 0,
                 queuedCount: Int = 0, queuedBytes: Int = 0,
                 firstQueued: UInt64? = nil, lastQueued: UInt64? = nil,
                 lastAdmitted: UInt64? = nil, lastReleased: UInt64? = nil) {
        self.revision = revision; self.nextOrdinal = nextOrdinal
        self.queuedCount = queuedCount; self.queuedBytes = queuedBytes
        self.firstQueued = firstQueued; self.lastQueued = lastQueued
        self.lastAdmitted = lastAdmitted; self.lastReleased = lastReleased
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
                            identity: input.identity, configurationRef: input.configurationRef)
    }
}

package struct JournalFollowUpChange: Sendable {
    package let sessionID: UUID
    package let expectedRevision: UInt64
    package let head: JournalFollowUpHead
    package let records: [JournalStoredFollowUp]
    package let links: [JournalFollowUpLink]
    /// Enqueues new input rather than updating inputs already accepted.
    package let admitsNewWork: Bool

    package init(sessionID: UUID, expectedRevision: UInt64, head: JournalFollowUpHead,
                 records: [JournalStoredFollowUp], links: [JournalFollowUpLink] = [],
                 admitsNewWork: Bool = false) {
        self.sessionID = sessionID; self.expectedRevision = expectedRevision
        self.head = head; self.records = records
        self.links = links
        self.admitsNewWork = admitsNewWork
    }
}

package struct JournalFollowUpLink: Sendable {
    package let ordinal: UInt64
    package let next: UInt64?
    package init(ordinal: UInt64, next: UInt64?) {
        self.ordinal = ordinal; self.next = next
    }
}

package struct JournalFollowUpAdmission: Sendable {
    package let inputID: String
    package let expectedQueueRevision: UInt64

    package init(inputID: String, expectedQueueRevision: UInt64) {
        self.inputID = inputID; self.expectedQueueRevision = expectedQueueRevision
    }
}
