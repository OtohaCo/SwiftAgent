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
    var supportsAdmissionRejections: Bool { get }
    var supportsAuthorizationAudit: Bool { get }
    var supportsConfirmedNoEffect: Bool { get }
    var noEffectProofVersion: Int { get }
    func auditDigest(_ bytes: Data) -> String
    func read<T>(_ body: (any JournalStoreView) throws -> T) throws -> T
    func write<T>(_ body: (any JournalStoreView) throws -> T) throws -> T
    func close() throws
    func maintenanceStatus() throws -> JournalMaintenanceStatus
    func maintain() async throws -> JournalMaintenanceStatus
    func metrics() -> JournalStorageMetrics
    func status() throws -> JournalStoreStatus
    /// A rotation failed and the active segment is past its target size; maintenance retries it.
    func rotationOverdue() -> Bool
}

public struct JournalStorageMetrics: Sendable, Equatable {
    /// Payload, index and manifest bytes read by this handle; excludes OS
    /// metadata operations and bytes served internally by the page cache.
    public let bytesRead: UInt64
    public let decodedBatches: UInt64
    public let bytesWritten: UInt64
    public let committedBatches: UInt64
    public let writeLockNanoseconds: UInt64
    public let maintenanceNanoseconds: UInt64
    /// Number of disk batch encodings; excludes Host input/output encoders and index envelopes.
    public let encodedBatches: UInt64
    public init(bytesRead: UInt64, decodedBatches: UInt64, bytesWritten: UInt64,
                committedBatches: UInt64, writeLockNanoseconds: UInt64, maintenanceNanoseconds: UInt64,
                encodedBatches: UInt64 = 0) {
        self.bytesRead = bytesRead
        self.decodedBatches = decodedBatches
        self.bytesWritten = bytesWritten
        self.committedBatches = committedBatches
        self.writeLockNanoseconds = writeLockNanoseconds
        self.maintenanceNanoseconds = maintenanceNanoseconds
        self.encodedBatches = encodedBatches
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
    public let pendingGarbagePacks: Int
    public init(identity: JournalStoreIdentity, logicalSequence: UInt64,
                layoutGeneration: UInt64, activeSegmentBytes: UInt64,
                sealedSegments: Int, pendingGarbageSegments: Int,
                pendingGarbagePacks: Int) {
        self.identity = identity
        self.logicalSequence = logicalSequence
        self.layoutGeneration = layoutGeneration
        self.activeSegmentBytes = activeSegmentBytes
        self.sealedSegments = sealedSegments
        self.pendingGarbageSegments = pendingGarbageSegments
        self.pendingGarbagePacks = pendingGarbagePacks
    }
}

package protocol JournalStoreView: AnyObject {
    func session(_ id: UUID) throws -> JournalStoredSession?
    func header(_ id: UUID) throws -> JournalSessionHeader?
    func identity(_ key: String) throws -> JournalStoredMutation?
    func mutation(sessionID: UUID, runID: UUID, callID: ToolCallID) throws -> JournalStoredMutation?
    func pending(sessionID: UUID?) throws -> [JournalStoredMutation]
    func hasPending(operationID: String) throws -> Bool
    func admissionRejection(sessionID: UUID, runID: UUID, callID: ToolCallID) throws -> JournalAdmissionRejection?
    func nextRecordSequence() throws -> UInt64
    func publish(_ change: JournalStoreChange) throws
    func messages(sessionID: UUID, after ordinal: UInt64, limit: Int) throws -> [JournalMessage]
    func followUpHead(sessionID: UUID) throws -> JournalFollowUpHead
    func followUp(sessionID: UUID, inputID: String) throws -> JournalStoredFollowUp?
    func followUps(sessionID: UUID, after ordinal: UInt64, limit: Int) throws -> [JournalStoredFollowUp]
    func publishFollowUp(_ change: JournalFollowUpChange) throws
    func auditHighWater() throws -> UInt64
    func auditRecord(sequence: UInt64) throws -> AuditRecord
    func auditGroupCount(_ key: String) throws -> UInt64
    func auditGroupMember(_ key: String, ordinal: UInt64) throws -> UInt64
    func publishAudit(_ change: JournalAuditChange) throws
    func auditExportCheckpoint(_ configurationID: String) throws -> JournalAuditExportCheckpoint?
    func publishAuditExport(_ change: JournalAuditExportChange) throws
}

package struct JournalAdmissionRejection: Equatable, Sendable {
    package let sessionID: UUID
    package let runID: UUID
    package let callID: ToolCallID
    package let toolName: String
    package init(sessionID: UUID, runID: UUID, callID: ToolCallID, toolName: String) {
        self.sessionID = sessionID; self.runID = runID
        self.callID = callID; self.toolName = toolName
    }
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
    package var auditLinks: AuditRecordLinks?

    package init(sessionID: UUID, runID: UUID, intent: PendingMutationIntent, sequence: UInt64,
                 state: AgentMutationState, receipt: ToolReceipt? = nil, output: JSONValue? = nil,
                 abortConfirmation: AgentNoEffectConfirmation? = nil, auditLinks: AuditRecordLinks? = nil) {
        self.sessionID = sessionID
        self.runID = runID
        self.intent = intent
        self.sequence = sequence
        self.state = state
        self.receipt = receipt
        self.output = output
        self.abortConfirmation = abortConfirmation
        self.auditLinks = auditLinks
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
    package let messageStart: UInt64
    package let messages: [JournalMessage]
    package let mutation: JournalStoredMutation?
    package let records: [AgentJournalRecord]
    package let followUpAdmission: JournalFollowUpAdmission?
    /// Admits new work (a Run's input) rather than settling work already admitted. A store under
    /// pressure refuses new work first.
    package let admitsNewWork: Bool
    package let auditRecords: [AuditRecord]

    package init(sessionID: UUID, expectedRevision: UInt64, header: JournalSessionHeader,
                 messageStart: UInt64, messages: [JournalMessage],
                 mutation: JournalStoredMutation?, records: [AgentJournalRecord],
                 followUpAdmission: JournalFollowUpAdmission? = nil, admitsNewWork: Bool = false,
                 auditRecords: [AuditRecord] = []) {
        self.sessionID = sessionID
        self.expectedRevision = expectedRevision
        self.header = header
        self.messageStart = messageStart
        self.messages = messages
        self.mutation = mutation
        self.records = records
        self.followUpAdmission = followUpAdmission
        self.admitsNewWork = admitsNewWork
        self.auditRecords = auditRecords
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
