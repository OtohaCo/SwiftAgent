import AgentModels
import AgentTools
import Foundation

public struct JournalConversationMessage: Equatable, Sendable {
    public let id: UUID
    public let message: ModelMessage
    public init(id: UUID, message: ModelMessage) {
        self.id = id
        self.message = message
    }
}

public struct JournalMutationStatus: Equatable, Sendable {
    public let state: AgentMutationState
    public let receipt: ToolReceipt?
    public let replayOutput: JSONValue?
    public let abortConfirmation: AgentNoEffectConfirmation?
    public init(state: AgentMutationState, receipt: ToolReceipt?, replayOutput: JSONValue?,
                abortConfirmation: AgentNoEffectConfirmation? = nil) {
        self.state = state
        self.receipt = receipt
        self.replayOutput = replayOutput
        self.abortConfirmation = abortConfirmation
    }
}

// This package-only seam has one durable implementation. The Host receives an
// AgentJournal and cannot directly write a trusted mutation transition.
package protocol JournalStore: Sendable {
    var directoryURL: URL { get }
    var storeID: UUID { get }
    var operationDomain: String { get }
    func read<T>(_ body: (any JournalStoreView) throws -> T) throws -> T
    func write<T>(_ body: (any JournalStoreView) throws -> T) throws -> T
    func close() throws
    func maintenanceStatus() throws -> JournalMaintenanceStatus
    func maintain() async throws -> JournalMaintenanceStatus
    func metrics() -> JournalStorageMetrics
    func status() throws -> JournalStoreStatus
}

public struct JournalStorageMetrics: Sendable, Equatable {
    public let bytesRead: UInt64
    public let decodedBatches: UInt64
    public let bytesWritten: UInt64
    public let committedBatches: UInt64
    public let writeLockNanoseconds: UInt64
    public let maintenanceNanoseconds: UInt64
    public init(bytesRead: UInt64, decodedBatches: UInt64, bytesWritten: UInt64,
                committedBatches: UInt64, writeLockNanoseconds: UInt64, maintenanceNanoseconds: UInt64) {
        self.bytesRead = bytesRead
        self.decodedBatches = decodedBatches
        self.bytesWritten = bytesWritten
        self.committedBatches = committedBatches
        self.writeLockNanoseconds = writeLockNanoseconds
        self.maintenanceNanoseconds = maintenanceNanoseconds
    }
}

public struct JournalStoreIdentity: Sendable, Equatable {
    public let storeID: UUID
    public let operationDomain: String
    public init(storeID: UUID, operationDomain: String) {
        self.storeID = storeID
        self.operationDomain = operationDomain
    }
}

public struct JournalStoreStatus: Sendable, Equatable {
    public let identity: JournalStoreIdentity
    public let logicalSequence: UInt64
    public let layoutGeneration: UInt64
    public let activeSegmentBytes: UInt64
    public let sealedSegments: Int
    public let pendingGarbageSegments: Int
    public init(identity: JournalStoreIdentity, logicalSequence: UInt64,
                layoutGeneration: UInt64, activeSegmentBytes: UInt64,
                sealedSegments: Int, pendingGarbageSegments: Int) {
        self.identity = identity
        self.logicalSequence = logicalSequence
        self.layoutGeneration = layoutGeneration
        self.activeSegmentBytes = activeSegmentBytes
        self.sealedSegments = sealedSegments
        self.pendingGarbageSegments = pendingGarbageSegments
    }
}

package protocol JournalStoreView: AnyObject {
    func session(_ id: UUID) throws -> JournalStoredSession?
    func header(_ id: UUID) throws -> JournalSessionHeader?
    func identity(_ key: String) throws -> JournalStoredMutation?
    func mutation(sessionID: UUID, runID: UUID, callID: ToolCallID) throws -> JournalStoredMutation?
    func pending(sessionID: UUID?) throws -> [JournalStoredMutation]
    func nextRecordSequence() throws -> UInt64
    func publish(_ change: JournalStoreChange) throws
    func messages(sessionID: UUID, after ordinal: UInt64, limit: Int) throws -> [JournalMessage]
}

package struct JournalSessionHeader: Codable, Equatable, Sendable {
    package var revision: UInt64
    package var created: Bool
    package var lastRunID: UUID?
    package var steeringIDs: [UUID]
    package var historyHead: UInt64?
    package var messageCount: UInt64
    package var pendingIdentity: String?

    package init(revision: UInt64 = 0, created: Bool = false, lastRunID: UUID? = nil,
                 steeringIDs: [UUID] = [], historyHead: UInt64? = nil,
                 messageCount: UInt64 = 0, pendingIdentity: String? = nil) {
        self.revision = revision
        self.created = created
        self.lastRunID = lastRunID
        self.steeringIDs = steeringIDs
        self.historyHead = historyHead
        self.messageCount = messageCount
        self.pendingIdentity = pendingIdentity
    }
}

package struct JournalStoredSession: Sendable {
    package let header: JournalSessionHeader
    package let history: [ModelMessage]
    package init(header: JournalSessionHeader, history: [ModelMessage]) {
        self.header = header
        self.history = history
    }
}

package struct JournalStoredMutation: Codable, Equatable, Sendable {
    package var sessionID: UUID
    package var runID: UUID
    package var intent: PendingMutationIntent
    package var sequence: UInt64
    package var state: AgentMutationState
    package var receipt: ToolReceipt?
    package var output: JSONValue?
    package var abortConfirmation: AgentNoEffectConfirmation?

    package init(sessionID: UUID, runID: UUID, intent: PendingMutationIntent, sequence: UInt64,
                 state: AgentMutationState, receipt: ToolReceipt? = nil, output: JSONValue? = nil,
                 abortConfirmation: AgentNoEffectConfirmation? = nil) {
        self.sessionID = sessionID
        self.runID = runID
        self.intent = intent
        self.sequence = sequence
        self.state = state
        self.receipt = receipt
        self.output = output
        self.abortConfirmation = abortConfirmation
    }
}

package struct JournalMessage: Codable, Equatable, Sendable {
    package let id: UUID
    package let value: ModelMessage
    package init(value: ModelMessage) { id = UUID(); self.value = value }
    package init(id: UUID, value: ModelMessage) { self.id = id; self.value = value }
}

package struct JournalStoreChange: Sendable {
    package let sessionID: UUID
    package let expectedRevision: UInt64
    package let header: JournalSessionHeader
    package let messages: [JournalMessage]
    package let mutation: JournalStoredMutation?
    package let records: [AgentJournalRecord]

    package init(sessionID: UUID, expectedRevision: UInt64, header: JournalSessionHeader,
                 messages: [JournalMessage], mutation: JournalStoredMutation?, records: [AgentJournalRecord]) {
        self.sessionID = sessionID
        self.expectedRevision = expectedRevision
        self.header = header
        self.messages = messages
        self.mutation = mutation
        self.records = records
    }
}

public struct JournalMaintenanceStatus: Sendable, Equatable {
    public let sealedSegments: Int
    public let reclaimedBytes: UInt64
    public let lastError: String?
    public init(sealedSegments: Int, reclaimedBytes: UInt64, lastError: String?) {
        self.sealedSegments = sealedSegments
        self.reclaimedBytes = reclaimedBytes
        self.lastError = lastError
    }
}
