import AgentModels
import AgentTools
import Foundation

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
@_silgen_name("flock")
private func swiftAgentFlock(_ fileDescriptor: Int32, _ operation: Int32) -> Int32

private enum SwiftAgentFileLockOperation {
    static let exclusiveNonBlocking: Int32 = 2 | 4
    static let unlock: Int32 = 8
}
#endif

public struct AgentCompactionSummary: Codable, Equatable, Sendable {
    public let goal: String
    public let constraints: [String]
    public let decisions: [String]
    public let openWork: [String]

    public init(goal: String, constraints: [String] = [], decisions: [String] = [], openWork: [String] = []) {
        self.goal = goal
        self.constraints = constraints
        self.decisions = decisions
        self.openWork = openWork
    }
}

public enum AgentJournalRunOutcome: Codable, Equatable, Sendable {
    case completed
    case failed(code: String)
    case cancelled
}

public enum AgentMutationState: String, Codable, Equatable, Sendable {
    case intent
    case needsReconciliation
    case settled
    case aborted
}

public enum AgentMutationSettlementSource: String, Codable, Equatable, Sendable {
    case executor
    case reconciliation
}

public struct PendingMutationRecovery: Equatable, Sendable {
    public let sessionID: UUID
    public let runID: UUID
    public let intent: PendingMutationIntent
    public let state: AgentMutationState

    public init(sessionID: UUID, runID: UUID, intent: PendingMutationIntent, state: AgentMutationState) {
        self.sessionID = sessionID
        self.runID = runID
        self.intent = intent
        self.state = state
    }
}

/// The durable lifecycle vocabulary is intentionally independent of any host application.
public enum AgentJournalEvent: Codable, Equatable, Sendable {
    case sessionCreated
    case userMessage(String)
    case assistantMessage(content: [ModelContent], toolCalls: [ToolCall])
    case modelAttempt(turn: Int, model: ModelID)
    case modelCompleted(ModelResponse)
    case toolProposed(call: ToolCall, effect: ToolPolicy.Effect, resources: [ToolResource])
    case toolAuthorized(callID: ToolCallID)
    case toolStarted(callID: ToolCallID)
    case toolCompleted(ToolResultMessage)
    case toolReceipt(AgentToolReceipt)
    case pendingMutation(PendingMutationIntent)
    case mutationReceiptExpectation(callID: ToolCallID, expectation: ToolReceiptExpectation)
    case mutationNeedsReconciliation(callID: ToolCallID)
    case mutationSettled(callID: ToolCallID, receipt: ToolReceipt, source: AgentMutationSettlementSource)
    case mutationAborted(callID: ToolCallID)
    case checkpoint(history: [ModelMessage], steeringIDs: [UUID])
    case compaction(AgentCompactionSummary)
    case runCompleted(AgentJournalRunOutcome)
}

public struct PendingMutationIntent: Codable, Equatable, Sendable {
    public let call: ToolCall
    public let resources: [ToolResource]
    public let idempotencyKey: String
    public let receiptExpectation: ToolReceiptExpectation?

    public init(
        call: ToolCall,
        resources: [ToolResource],
        idempotencyKey: String,
        receiptExpectation: ToolReceiptExpectation? = nil
    ) throws {
        guard call.completeness == .complete,
              !call.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !call.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              receiptExpectation != nil else {
            throw AgentJournalError.invalidMutationIntent
        }
        try ToolResource.validate(resources)
        self.call = call
        self.resources = resources
        self.idempotencyKey = idempotencyKey
        self.receiptExpectation = receiptExpectation
    }

    func validate(allowMissingReceiptExpectation: Bool = false) throws {
        guard call.completeness == .complete,
              !call.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !call.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentJournalError.invalidMutationIntent
        }
        if !allowMissingReceiptExpectation, receiptExpectation == nil {
            throw AgentJournalError.invalidMutationIntent
        }
        try ToolResource.validate(resources)
    }
}

public struct AgentJournalRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public let id: UUID
    public let sequence: UInt64
    public let timestamp: Date
    public let schemaVersion: Int
    public let sessionID: UUID
    public let runID: UUID?
    public let checkpointID: UUID
    public let event: AgentJournalEvent

    init(
        id: UUID = UUID(),
        sequence: UInt64,
        timestamp: Date,
        sessionID: UUID,
        runID: UUID?,
        checkpointID: UUID,
        event: AgentJournalEvent
    ) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.schemaVersion = Self.schemaVersion
        self.sessionID = sessionID
        self.runID = runID
        self.checkpointID = checkpointID
        self.event = event
    }
}

public enum AgentJournalRecovery: Equatable, Sendable {
    case clean
    case truncatedTail
}

package enum AgentJournalDurability: Sendable {
    case memory
    case durable
}

public enum AgentJournalError: Error, LocalizedError, Equatable, Sendable {
    case invalidHeader
    case invalidFrame
    case invalidRecord
    case checksumMismatch
    case concurrentWriter
    case invalidMutationIntent
    case mutationIntentConflict
    case mutationRequiresReconciliation
    case mutationNotFound
    case mutationReceiptInvalid
    case mutationMissingReceiptExpectation
    case mutationSettlementRequiresReconciliation
    case persistenceUnavailable(String)
    case sessionLeaseUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidHeader: "Agent journal header is invalid."
        case .invalidFrame: "Agent journal frame is invalid."
        case .invalidRecord: "Agent journal record is invalid."
        case .checksumMismatch: "Agent journal checksum verification failed."
        case .concurrentWriter: "Agent journal changed outside this instance."
        case .invalidMutationIntent: "Mutation intent is incomplete or invalid."
        case .mutationIntentConflict: "Mutation intent conflicts with an existing operation."
        case .mutationRequiresReconciliation: "An earlier mutation requires reconciliation before another mutation can run."
        case .mutationNotFound: "The mutation intent was not found in the journal."
        case .mutationReceiptInvalid: "The mutation receipt cannot be bound to the durable intent."
        case .mutationMissingReceiptExpectation: "Mutation admission requires a receipt expectation."
        case .mutationSettlementRequiresReconciliation: "Mutation settlement must use the reconciliation API."
        case .persistenceUnavailable(let message): "Agent journal persistence is unavailable: \(message)"
        case .sessionLeaseUnavailable: "The durable Agent session is already active in another process."
        }
    }
}

/// Whether a journal can guarantee mutation durability across process death.
///
/// This is a capability, not a file-path check. A future database, remote, or
/// encrypted journal should advertise `.durable` when it can survive a crash
/// without losing an admitted mutation intent.
public enum AgentJournalStorage: Sendable, Equatable {
    /// In-process only. Sufficient for read-only sessions.
    case memory
    /// Survives process death. Required before a mutation Session can be created.
    case durable
}

private final class AgentJournalStorageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentJournalStorage

    init(_ value: AgentJournalStorage) {
        self.value = value
    }

    var current: AgentJournalStorage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }
}

/// Durable typed lifecycle log. Mutation success is settlement from a trusted
/// receipt, never an executor that merely returned. Hosts inspect pending
/// work, recover after a crash, reconcile or abort. They cannot append a
/// settlement event directly.
///
/// Read-only Agents may omit a journal or use `.memory` storage. Mutation
/// tools require `.durable` storage at Session creation.
public actor AgentJournal {
    private struct JournalFrame: Codable {
        let schemaVersion: Int
        let records: [AgentJournalRecord]
    }

    private struct ReadResult {
        let records: [AgentJournalRecord]
        let recovery: AgentJournalRecovery
        let validLength: Int
        let exists: Bool
    }

    private static let header = Data("SWIFTAGENT-JOURNAL-1".utf8)
    private static let maximumFrameSize = 16 * 1024 * 1024
    private static let supportedSchemaVersions: Set<Int> = [1, AgentJournalRecord.schemaVersion]

    private var records: [AgentJournalRecord]
    private var nextSequence: UInt64
    private var persistenceURL: URL?
    private var recoveryState: AgentJournalRecovery
    private var sessionLeases: [UUID: FileHandle]
    private nonisolated let storageBox: AgentJournalStorageBox

    /// Advertised durability guarantee. `persist(to:)` upgrades `.memory` to
    /// `.durable` after a successful snapshot bind.
    public nonisolated var storage: AgentJournalStorage { storageBox.current }

    private struct MutationKey: Hashable {
        let sessionID: UUID
        let runID: UUID
        let callID: ToolCallID
    }

    private struct MutationRecord: Equatable {
        let key: MutationKey
        var intent: PendingMutationIntent
        let sequence: UInt64
        var state: AgentMutationState
    }

    private var mutationRecords: [MutationKey: MutationRecord]

    public init() {
        records = []
        nextSequence = 1
        persistenceURL = nil
        recoveryState = .clean
        sessionLeases = [:]
        mutationRecords = [:]
        storageBox = AgentJournalStorageBox(.memory)
    }

    /// Opens an existing journal or prepares a new journal at the supplied URL.
    public init(persistenceURL: URL) throws {
        let loaded = try Self.read(from: persistenceURL)
        records = loaded.records
        nextSequence = (loaded.records.last?.sequence ?? 0) + 1
        self.persistenceURL = persistenceURL
        recoveryState = loaded.recovery
        sessionLeases = [:]
        mutationRecords = try Self.buildMutationRecords(from: loaded.records)
        storageBox = AgentJournalStorageBox(.durable)
    }

    public static func load(from url: URL) throws -> AgentJournal {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentJournalError.persistenceUnavailable("journal file does not exist")
        }
        return try AgentJournal(persistenceURL: url)
    }

    public func snapshot() -> [AgentJournalRecord] { records }

    /// Holds an OS-backed lease for one persistent Session identity. The file
    /// descriptor remains open for the lifetime of the lease, so a crashed
    /// process cannot strand the lease behind a stale marker file.
    package func acquireSessionLease(sessionID: UUID) throws {
        guard let persistenceURL else { return }
        guard sessionLeases[sessionID] == nil else {
            throw AgentJournalError.sessionLeaseUnavailable
        }

        let leaseURL = Self.sessionLeaseURL(for: persistenceURL, sessionID: sessionID)
        do {
            try FileManager.default.createDirectory(
                at: leaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: leaseURL.path),
               !FileManager.default.createFile(atPath: leaseURL.path, contents: nil) {
                throw AgentJournalError.persistenceUnavailable("cannot create session lease file")
            }
        } catch let error as AgentJournalError {
            throw error
        } catch {
            throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: leaseURL)
        } catch {
            throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }

        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        guard swiftAgentFlock(handle.fileDescriptor, SwiftAgentFileLockOperation.exclusiveNonBlocking) == 0 else {
            try? handle.close()
            throw AgentJournalError.sessionLeaseUnavailable
        }
        #else
        try? handle.close()
        throw AgentJournalError.persistenceUnavailable("session leases are unsupported on this platform")
        #endif

        sessionLeases[sessionID] = handle
    }

    package func releaseSessionLease(sessionID: UUID) {
        guard let handle = sessionLeases.removeValue(forKey: sessionID) else { return }
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        _ = swiftAgentFlock(handle.fileDescriptor, SwiftAgentFileLockOperation.unlock)
        #endif
        try? handle.close()
    }

    /// Returns the most recent canonical session history checkpoint. The
    /// checkpoint is host-neutral and is the only journal payload used to
    /// reconstruct a Session after a process restart.
    public func latestCheckpoint(
        sessionID: UUID
    ) -> (history: [ModelMessage], steeringIDs: [UUID])? {
        for record in records.reversed() where record.sessionID == sessionID {
            guard case .checkpoint(let history, let steeringIDs) = record.event else { continue }
            return (history: history, steeringIDs: steeringIDs)
        }
        return nil
    }

    public var recovery: AgentJournalRecovery { recoveryState }

    @discardableResult
    package func append(
        _ event: AgentJournalEvent,
        sessionID: UUID,
        runID: UUID? = nil,
        timestamp: Date = Date(),
        durability: AgentJournalDurability = .memory
    ) throws -> AgentJournalRecord {
        try appendCheckpoint(
            [event],
            sessionID: sessionID,
            runID: runID,
            timestamp: timestamp,
            durability: durability
        )[0]
    }

    @discardableResult
    package func appendCheckpoint(
        _ events: [AgentJournalEvent],
        sessionID: UUID,
        runID: UUID? = nil,
        timestamp: Date = Date(),
        durability: AgentJournalDurability = .memory
    ) throws -> [AgentJournalRecord] {
        try appendCheckpoint(events, sessionID: sessionID, runID: runID, timestamp: timestamp,
                             durability: durability, allowMutationSettlement: false)
    }

    private func appendCheckpoint(
        _ events: [AgentJournalEvent],
        sessionID: UUID,
        runID: UUID?,
        timestamp: Date,
        durability: AgentJournalDurability,
        allowMutationSettlement: Bool
    ) throws -> [AgentJournalRecord] {
        guard !events.isEmpty else { return [] }
        guard allowMutationSettlement || !events.contains(where: Self.isMutationSettlementEvent) else {
            throw AgentJournalError.mutationSettlementRequiresReconciliation
        }
        if durability != .durable,
           events.contains(where: Self.isMutationLifecycleEvent) {
            throw AgentJournalError.persistenceUnavailable("mutation lifecycle events require durable persistence")
        }
        let updatedMutationRecords = try applying(events, sessionID: sessionID, runID: runID)
        let checkpointID = UUID()
        let committed = events.enumerated().map { offset, event in
            AgentJournalRecord(
                sequence: nextSequence + UInt64(offset),
                timestamp: timestamp,
                sessionID: sessionID,
                runID: runID,
                checkpointID: checkpointID,
                event: event
            )
        }
        try commit(committed, durability: durability)
        records.append(contentsOf: committed)
        nextSequence += UInt64(committed.count)
        recoveryState = .clean
        mutationRecords = updatedMutationRecords
        return committed
    }

    public func pendingMutations(sessionID: UUID? = nil) -> [PendingMutationRecovery] {
        mutationRecords.values
            .filter { record in
                guard record.state == .intent || record.state == .needsReconciliation else { return false }
                return sessionID == nil || record.key.sessionID == sessionID
            }
            .sorted { $0.sequence < $1.sequence }
            .map { record in
                PendingMutationRecovery(sessionID: record.key.sessionID, runID: record.key.runID,
                                        intent: record.intent, state: record.state)
            }
    }

    /// Converts an admitted but unsettled intent into a quarantine state. Recovery never invokes the tool.
    public func recoverPendingMutations(sessionID: UUID? = nil) throws -> [PendingMutationRecovery] {
        let intents = pendingMutations(sessionID: sessionID).filter { $0.state == .intent }
        for pending in intents {
            _ = try append(.mutationNeedsReconciliation(callID: pending.intent.call.id),
                            sessionID: pending.sessionID, runID: pending.runID, durability: .durable)
        }
        return pendingMutations(sessionID: sessionID)
    }

    /// Records that a mutation executor was reached without a trusted successful receipt.
    package func markMutationNeedsReconciliation(sessionID: UUID, runID: UUID, callID: ToolCallID) throws {
        let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
        guard let record = mutationRecords[key] else { return }
        guard record.state == .intent else { return }
        _ = try append(.mutationNeedsReconciliation(callID: callID), sessionID: sessionID,
                       runID: runID, durability: .durable)
    }

    /// Settles an executor-reported receipt only after it validates against the durable intent.
    package func settleMutation(sessionID: UUID, runID: UUID, callID: ToolCallID, receipt: ToolReceipt) throws {
        let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
        guard let record = mutationRecords[key] else { throw AgentJournalError.mutationNotFound }
        guard record.state == .intent else { throw AgentJournalError.mutationRequiresReconciliation }
        guard let expectation = record.intent.receiptExpectation else {
            throw AgentJournalError.mutationMissingReceiptExpectation
        }
        do {
            try ToolReceiptValidator.validate(receipt, operationID: record.intent.idempotencyKey, expectation: expectation)
        } catch {
            throw error
        }
        let accepted = AgentToolReceipt(callID: callID, effect: .mutation, receipt: receipt)
        _ = try appendCheckpoint([.toolReceipt(accepted),
                                  .mutationSettled(callID: callID, receipt: receipt, source: .executor)],
                                 sessionID: sessionID, runID: runID, timestamp: Date(), durability: .durable,
                                 allowMutationSettlement: true)
    }

    /// Atomically settles an executor-reported mutation and publishes the
    /// resulting canonical history checkpoint in the same durable frame.
    /// If persistence fails, the in-memory intent remains unsettled so a later
    /// recovery pass can quarantine it instead of replaying the mutation.
    package func commitMutation(
        sessionID: UUID,
        runID: UUID,
        callID: ToolCallID,
        receipt: ToolReceipt,
        history: [ModelMessage],
        steeringIDs: [UUID]
    ) throws {
        let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
        guard let record = mutationRecords[key] else { throw AgentJournalError.mutationNotFound }
        guard record.state == .intent else { throw AgentJournalError.mutationRequiresReconciliation }
        guard let expectation = record.intent.receiptExpectation else {
            throw AgentJournalError.mutationMissingReceiptExpectation
        }
        try ToolReceiptValidator.validate(receipt, operationID: record.intent.idempotencyKey, expectation: expectation)
        let accepted = AgentToolReceipt(callID: callID, effect: .mutation, receipt: receipt)
        _ = try appendCheckpoint(
            [
                .toolReceipt(accepted),
                .mutationSettled(callID: callID, receipt: receipt, source: .executor),
                .checkpoint(history: history, steeringIDs: steeringIDs),
            ],
            sessionID: sessionID,
            runID: runID,
            timestamp: Date(),
            durability: .durable,
            allowMutationSettlement: true
        )
    }

    /// Settles a quarantined intent from an explicit trusted reconciliation result; it never invokes the original tool.
    public func reconcileMutation(_ pending: PendingMutationRecovery, receipt: ToolReceipt) throws {
        try reconcileMutation(pending, receipt: receipt, receiptExpectation: nil)
    }

    /// Reconciles a legacy intent that predates persisted receipt expectations.
    /// The supplied expectation is persisted together with the receipt before settlement.
    public func reconcileMutation(_ pending: PendingMutationRecovery, receipt: ToolReceipt,
                                  receiptExpectation: ToolReceiptExpectation?) throws {
        let key = MutationKey(sessionID: pending.sessionID, runID: pending.runID, callID: pending.intent.call.id)
        guard let record = mutationRecords[key], record.intent == pending.intent else {
            throw AgentJournalError.mutationIntentConflict
        }
        guard record.state == .needsReconciliation, pending.state == .needsReconciliation else {
            throw AgentJournalError.mutationRequiresReconciliation
        }
        let expectation = record.intent.receiptExpectation ?? receiptExpectation
        guard let expectation else {
            throw AgentJournalError.mutationMissingReceiptExpectation
        }
        if record.intent.receiptExpectation == nil {
            try Self.validateLegacyReceiptExpectation(expectation, for: record.intent)
        }
        try ToolReceiptValidator.validate(receipt, operationID: record.intent.idempotencyKey, expectation: expectation)
        let accepted = AgentToolReceipt(callID: pending.intent.call.id, effect: .mutation, receipt: receipt)
        var events: [AgentJournalEvent] = []
        if record.intent.receiptExpectation == nil {
            events.append(.mutationReceiptExpectation(callID: pending.intent.call.id, expectation: expectation))
        }
        events.append(contentsOf: [.toolReceipt(accepted),
                                   .mutationSettled(callID: pending.intent.call.id, receipt: receipt,
                                                    source: .reconciliation)])
        _ = try appendCheckpoint(events,
                                 sessionID: pending.sessionID, runID: pending.runID, timestamp: Date(),
                                 durability: .durable, allowMutationSettlement: true)
    }

    /// Closes a quarantined intent without executing the original tool.
    public func abortMutation(_ pending: PendingMutationRecovery) throws {
        let key = MutationKey(sessionID: pending.sessionID, runID: pending.runID, callID: pending.intent.call.id)
        guard let record = mutationRecords[key], record.intent == pending.intent else {
            throw AgentJournalError.mutationIntentConflict
        }
        guard record.state == .needsReconciliation, pending.state == .needsReconciliation else {
            throw AgentJournalError.mutationRequiresReconciliation
        }
        _ = try append(
            .mutationAborted(callID: pending.intent.call.id),
            sessionID: pending.sessionID,
            runID: pending.runID,
            durability: .durable
        )
    }

    private func applying(
        _ events: [AgentJournalEvent], sessionID: UUID, runID: UUID?
    ) throws -> [MutationKey: MutationRecord] {
        var updated = mutationRecords
        for (offset, event) in events.enumerated() {
            try Self.applyMutationEvent(event, sessionID: sessionID, runID: runID,
                                        sequence: nextSequence + UInt64(offset),
                                        schemaVersion: AgentJournalRecord.schemaVersion,
                                        records: &updated)
        }
        return updated
    }

    private static func buildMutationRecords(from records: [AgentJournalRecord]) throws -> [MutationKey: MutationRecord] {
        var mutationRecords: [MutationKey: MutationRecord] = [:]
        do {
            for record in records {
                try applyMutationEvent(record.event, sessionID: record.sessionID, runID: record.runID,
                                       sequence: record.sequence, schemaVersion: record.schemaVersion,
                                       allowLegacyMissingReceiptExpectation: record.schemaVersion == 1,
                                       records: &mutationRecords)
            }
        } catch {
            throw AgentJournalError.invalidRecord
        }
        return mutationRecords
    }

    private static func applyMutationEvent(
        _ event: AgentJournalEvent,
        sessionID: UUID,
        runID: UUID?,
        sequence: UInt64,
        schemaVersion: Int,
        allowLegacyMissingReceiptExpectation: Bool = false,
        records: inout [MutationKey: MutationRecord]
    ) throws {
        switch event {
        case .pendingMutation(let intent):
            guard let runID else { throw AgentJournalError.invalidRecord }
            try intent.validate(allowMissingReceiptExpectation: allowLegacyMissingReceiptExpectation)
            let key = MutationKey(sessionID: sessionID, runID: runID, callID: intent.call.id)
            guard !records.values.contains(where: {
                $0.key.sessionID == sessionID && ($0.state == .intent || $0.state == .needsReconciliation)
            }) else {
                throw AgentJournalError.mutationRequiresReconciliation
            }
            guard records[key] == nil,
                  !records.values.contains(where: {
                      $0.key.sessionID == sessionID && $0.intent.idempotencyKey == intent.idempotencyKey
                  }) else {
                throw AgentJournalError.mutationIntentConflict
            }
            records[key] = MutationRecord(
                key: key,
                intent: intent,
                sequence: sequence,
                state: intent.receiptExpectation == nil ? .needsReconciliation : .intent
            )

        case .mutationReceiptExpectation(let callID, let expectation):
            guard let runID else { throw AgentJournalError.invalidRecord }
            let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
            guard let record = records[key], record.intent.receiptExpectation == nil,
                  record.state == .needsReconciliation || record.state == .intent else {
                throw AgentJournalError.mutationIntentConflict
            }
            try Self.validateLegacyReceiptExpectation(expectation, for: record.intent)
            var updated = record
            updated.intent = try PendingMutationIntent(call: record.intent.call,
                                                       resources: record.intent.resources,
                                                       idempotencyKey: record.intent.idempotencyKey,
                                                       receiptExpectation: expectation)
            records[key] = updated

        case .mutationNeedsReconciliation(let callID):
            guard let runID else { throw AgentJournalError.invalidRecord }
            let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
            guard let record = records[key], record.state == .intent || record.state == .needsReconciliation else {
                throw AgentJournalError.mutationNotFound
            }
            var updated = record
            updated.state = .needsReconciliation
            records[key] = updated

        case .mutationSettled(let callID, let receipt, let source):
            guard let runID else { throw AgentJournalError.invalidRecord }
            let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
            guard let record = records[key] else { throw AgentJournalError.mutationNotFound }
            guard let expectation = record.intent.receiptExpectation else {
                throw AgentJournalError.mutationMissingReceiptExpectation
            }
            try ToolReceiptValidator.validate(receipt, operationID: record.intent.idempotencyKey, expectation: expectation)
            switch (record.state, source) {
            case (.intent, .executor), (.needsReconciliation, .reconciliation):
                var updated = record
                updated.state = .settled
                records[key] = updated
            default:
                throw AgentJournalError.mutationIntentConflict
            }

        case .mutationAborted(let callID):
            guard let runID else { throw AgentJournalError.invalidRecord }
            let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
            guard let record = records[key], record.state == .intent || record.state == .needsReconciliation else {
                throw AgentJournalError.mutationNotFound
            }
            var updated = record
            updated.state = .aborted
            records[key] = updated

        default:
            break
        }
    }

    private static func isMutationLifecycleEvent(_ event: AgentJournalEvent) -> Bool {
        switch event {
        case .pendingMutation, .mutationReceiptExpectation, .mutationNeedsReconciliation, .mutationSettled, .mutationAborted:
            true
        default:
            false
        }
    }

    private static func isMutationSettlementEvent(_ event: AgentJournalEvent) -> Bool {
        if case .mutationSettled = event { return true }
        return false
    }

    private static func sessionLeaseURL(for persistenceURL: URL, sessionID: UUID) -> URL {
        URL(fileURLWithPath: persistenceURL.path + ".session-\(sessionID.uuidString).lease")
    }

    private static func validateLegacyReceiptExpectation(
        _ expectation: ToolReceiptExpectation,
        for intent: PendingMutationIntent
    ) throws {
        let resourceTargets = intent.resources.compactMap { resource -> EvidenceReference? in
            if case .named(let reference) = resource { return reference }
            return nil
        }
        guard !resourceTargets.isEmpty,
              Set(resourceTargets) == Set(expectation.targets) else {
            throw AgentJournalError.mutationReceiptInvalid
        }
    }

    /// Writes a complete snapshot and binds this journal to the destination for later durable appends.
    public func persist(to url: URL) throws {
        let data = try Self.encodeFile(records: records)
        try Self.withFileLock(for: url) {
            let existing = try Self.read(from: url)
            guard !existing.exists || existing.records == records else {
                throw AgentJournalError.concurrentWriter
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            do {
                try Self.writeAndSync(data, to: temporary)
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: url)
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error is AgentJournalError ? error : AgentJournalError.persistenceUnavailable(error.localizedDescription)
            }
        }
        persistenceURL = url
        recoveryState = .clean
        storageBox.current = .durable
    }

    private func commit(_ committed: [AgentJournalRecord], durability: AgentJournalDurability) throws {
        guard durability == .durable else { return }
        guard let url = persistenceURL else {
            throw AgentJournalError.persistenceUnavailable("no persistence URL configured")
        }
        let expectedRecords = records
        let frame = try Self.encodeFrame(records: committed)
        try Self.withFileLock(for: url) {
            let current = try Self.read(from: url)
            guard current.records == expectedRecords else {
                throw AgentJournalError.concurrentWriter
            }
            let appendOffset = current.exists ? current.validLength : Self.header.count
            try Self.createOrTruncateTail(at: url, to: appendOffset)
            try Self.appendAndSync(frame, to: url, offset: appendOffset)
        }
    }

    private static func encodeFile(records: [AgentJournalRecord]) throws -> Data {
        var data = header
        var start = 0
        while start < records.count {
            let checkpointID = records[start].checkpointID
            var end = start + 1
            while end < records.count, records[end].checkpointID == checkpointID { end += 1 }
            data.append(try encodeFrame(records: Array(records[start..<end])))
            start = end
        }
        return data
    }

    private static func encodeFrame(records: [AgentJournalRecord]) throws -> Data {
        guard !records.isEmpty else { throw AgentJournalError.invalidFrame }
        let checkpointID = records[0].checkpointID
        guard records.allSatisfy({ $0.checkpointID == checkpointID }) else {
            throw AgentJournalError.invalidRecord
        }
        let payload = try JSONEncoder().encode(JournalFrame(schemaVersion: AgentJournalRecord.schemaVersion, records: records))
        guard payload.count <= maximumFrameSize else { throw AgentJournalError.invalidFrame }
        var frame = Data()
        frame.append(contentsOf: bytes(UInt32(payload.count)))
        frame.append(contentsOf: bytes(crc32(payload)))
        frame.append(payload)
        return frame
    }

    private static func read(from url: URL) throws -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ReadResult(records: [], recovery: .clean, validLength: 0, exists: false)
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw AgentJournalError.persistenceUnavailable(error.localizedDescription) }
        guard data.count >= header.count, data.prefix(header.count) == header else {
            throw AgentJournalError.invalidHeader
        }

        var records: [AgentJournalRecord] = []
        var offset = header.count
        var expectedSequence: UInt64 = 1
        var recovery: AgentJournalRecovery = .clean
        while offset < data.count {
            let remaining = data.count - offset
            guard remaining >= 8 else {
                recovery = .truncatedTail
                break
            }
            let length = Int(readUInt32(data, at: offset))
            let expectedChecksum = readUInt32(data, at: offset + 4)
            guard length > 0, length <= maximumFrameSize else { throw AgentJournalError.invalidFrame }
            let end = offset + 8 + length
            guard end <= data.count else {
                recovery = .truncatedTail
                break
            }
            let payload = data.subdata(in: (offset + 8)..<end)
            guard crc32(payload) == expectedChecksum else { throw AgentJournalError.checksumMismatch }
            let frame: JournalFrame
            do { frame = try JSONDecoder().decode(JournalFrame.self, from: payload) }
            catch { throw AgentJournalError.invalidFrame }
            guard Self.supportedSchemaVersions.contains(frame.schemaVersion),
                  !frame.records.isEmpty,
                  frame.records.allSatisfy({ $0.checkpointID == frame.records[0].checkpointID }) else {
                throw AgentJournalError.invalidRecord
            }
            for record in frame.records {
                guard Self.supportedSchemaVersions.contains(record.schemaVersion),
                      record.sequence == expectedSequence else {
                    throw AgentJournalError.invalidRecord
                }
                records.append(record)
                expectedSequence += 1
            }
            offset = end
        }
        return ReadResult(records: records, recovery: recovery, validLength: offset, exists: true)
    }

    private static func createOrTruncateTail(at url: URL, to offset: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: header) else {
                throw AgentJournalError.persistenceUnavailable("cannot create journal file")
            }
            return
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: url) }
        catch { throw AgentJournalError.persistenceUnavailable(error.localizedDescription) }
        do {
            try handle.truncate(atOffset: UInt64(offset))
            try handle.close()
        } catch {
            try? handle.close()
            throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }
    }

    private static func writeAndSync(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AgentJournalError.persistenceUnavailable("cannot create temporary journal file")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: url) }
        catch { throw AgentJournalError.persistenceUnavailable(error.localizedDescription) }
        do {
            try handle.write(contentsOf: data)
            try sync(handle)
            try handle.close()
        } catch {
            try? handle.close()
            throw error is AgentJournalError ? error : AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }
    }

    private static func appendAndSync(_ data: Data, to url: URL, offset: Int) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: header) else {
                throw AgentJournalError.persistenceUnavailable("cannot create journal file")
            }
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: url) }
        catch { throw AgentJournalError.persistenceUnavailable(error.localizedDescription) }
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
            try sync(handle)
            try handle.close()
        } catch {
            try? handle.close()
            throw error is AgentJournalError ? error : AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }
    }

    private static func sync(_ handle: FileHandle) throws {
        try handle.synchronize()
    }

    private static func withFileLock<T>(for url: URL, _ body: () throws -> T) throws -> T {
        let lockURL = URL(fileURLWithPath: url.path + ".lock")
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Older builds used a directory as a marker. Remove only that
            // obsolete empty marker; the current lock is an OS advisory lock
            // on a regular file and therefore survives a crashed process.
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: lockURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                try FileManager.default.removeItem(at: lockURL)
            }
            if !FileManager.default.fileExists(atPath: lockURL.path),
               !FileManager.default.createFile(atPath: lockURL.path, contents: nil) {
                throw AgentJournalError.persistenceUnavailable("cannot create journal lock file")
            }
        } catch {
            throw error is AgentJournalError
                ? error
                : AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: lockURL)
        } catch {
            throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(5)
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        while swiftAgentFlock(handle.fileDescriptor, SwiftAgentFileLockOperation.exclusiveNonBlocking) != 0 {
            guard Date() < deadline else {
                try? handle.close()
                throw AgentJournalError.persistenceUnavailable("journal lock is busy")
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        defer {
            _ = swiftAgentFlock(handle.fileDescriptor, SwiftAgentFileLockOperation.unlock)
            try? handle.close()
        }
        return try body()
        #else
        try? handle.close()
        throw AgentJournalError.persistenceUnavailable("journal locks are unsupported on this platform")
        #endif
    }

    private static func bytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xffffffff
        for byte in data {
            checksum ^= UInt32(byte)
            for _ in 0..<8 {
                checksum = (checksum & 1) == 0
                    ? checksum >> 1
                    : (checksum >> 1) ^ 0xedb88320
            }
        }
        return checksum ^ 0xffffffff
    }
}

extension AgentJournal: ToolMutationAdmission {
    package func admit(_ request: ToolMutationAdmissionRequest) async throws {
        guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.callID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentJournalError.invalidMutationIntent
        }
        guard request.receiptExpectation != nil else {
            throw AgentJournalError.mutationMissingReceiptExpectation
        }
        do {
            _ = try JSONValue.decodeToolArguments(request.argumentsJSON)
        } catch {
            throw AgentJournalError.invalidMutationIntent
        }
        try ToolResource.validate(request.resources)
        let call = ToolCall(id: request.callID, name: request.name,
                            argumentsJSON: request.argumentsJSON, completeness: .complete)
        let intent = try PendingMutationIntent(call: call, resources: request.resources,
                                               idempotencyKey: request.idempotencyKey,
                                               receiptExpectation: request.receiptExpectation)
        _ = try append(.pendingMutation(intent), sessionID: request.sessionID, runID: request.runID,
                       durability: .durable)
    }
}
