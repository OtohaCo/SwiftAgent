import AgentModels
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
    public let attachments: [AgentRunInput.Attachment]

    public init(inputID: String, text: String, operationID: String, configurationRef: String) {
        self.init(inputID: inputID, text: text, operationID: operationID, configurationRef: configurationRef, attachments: [])
    }

    public init(inputID: String, text: String, identity: AgentOperationIdentity, configurationRef: String) {
        self.init(inputID: inputID, text: text, identity: identity, configurationRef: configurationRef, attachments: [])
    }

    public init(inputID: String, text: String, operationID: String, configurationRef: String,
                attachments: [AgentRunInput.Attachment]) {
        self.init(inputID: inputID, text: text, identity: .operation(operationID),
                  configurationRef: configurationRef, attachments: attachments)
    }

    public init(inputID: String, text: String, identity: AgentOperationIdentity, configurationRef: String,
                attachments: [AgentRunInput.Attachment]) {
        self.inputID = inputID; self.text = text
        self.identity = identity; self.configurationRef = configurationRef
        self.attachments = attachments
    }

    package static let maxTextBytes = 256 * 1024
    package static let maxQueueBytes = 8 * 1024 * 1024
    package static let ordinaryQueueCapacity = 128
    /// Recovery may need to reinsert work that was already accepted as steering.
    package static let editedQueueCapacity = 2 * ordinaryQueueCapacity

    package var byteCount: Int {
        text.utf8.count + attachments.reduce(0) { sum, part in
            switch part {
            case .image(let image): sum + image.byteCount + image.description.utf8.count
            case .file(let file): sum + file.uri.absoluteString.utf8.count + file.textSubstitute.utf8.count
            }
        }
    }

    package func validate() throws {
        if let operationID, operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || operationID.utf8.count > 256 {
            throw AgentFollowUpError.invalidInput
        }
        guard !inputID.isEmpty, inputID.utf8.count <= 128,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maxTextBytes,
              attachments.count <= 20, byteCount <= Self.maxQueueBytes,
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
            && attachments == other.attachments
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
    /// A resolver can decline a batch and be asked to prepare its first member alone.
    case retryFirstInput
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
    package let replaces: [String]?
    package let replacementGroup: [String]?
    package var sendAlone: Bool

    package init(sessionID: UUID, ordinal: UInt64, input: AgentFollowUpInput,
                 state: AgentFollowUpState, nextQueued: UInt64? = nil, replaces: [String]? = nil,
                 replacementGroup: [String]? = nil, sendAlone: Bool = false) {
        self.sessionID = sessionID; self.ordinal = ordinal; self.input = input
        self.state = state; self.nextQueued = nextQueued
        self.replaces = replaces
        self.replacementGroup = replacementGroup
        self.sendAlone = sendAlone
    }

    package func publicRecord(storeID: UUID) -> AgentFollowUpRecord {
        AgentFollowUpRecord(storeID: storeID, sessionID: sessionID,
                            inputID: input.inputID, ordinal: ordinal, state: state,
                            identity: input.identity, configurationRef: input.configurationRef)
    }
}

package struct JournalFollowUpChange: Sendable {
    package static let maxChanges = 2 * AgentFollowUpInput.editedQueueCapacity
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
    package let inputIDs: [String]
    package var inputID: String { inputIDs[0] }
    package let expectedQueueRevision: UInt64
    package let preparedText: String?

    package init(inputIDs: [String], expectedQueueRevision: UInt64, preparedText: String? = nil) {
        precondition(!inputIDs.isEmpty)
        self.inputIDs = inputIDs; self.expectedQueueRevision = expectedQueueRevision
        self.preparedText = preparedText
    }
}

struct FollowUpBatch {
    let inputs: [AgentFollowUpInput]

    var text: String { inputs.map(\.text).joined(separator: "\n\n") }
    var attachments: [AgentRunInput.Attachment] { inputs.flatMap(\.attachments) }
    func content(preparedText: String? = nil) throws -> [ModelContent] {
        let raw = text
        let supplied = preparedText ?? raw
        let complete = try AgentRunInput(text: supplied, attachments: attachments)
        guard inputs.count > 1, !complete.attachments.isEmpty,
              supplied.utf8.suffix(raw.utf8.count).elementsEqual(raw.utf8) else {
            return complete.content
        }
        let prefix = String(decoding: supplied.utf8.dropLast(raw.utf8.count), as: UTF8.self)
        return try inputs.enumerated().flatMap { offset, input in
            try AgentRunInput(text: (offset == 0 ? prefix : "\n\n") + input.text,
                              attachments: input.attachments).content
        }
    }
}
