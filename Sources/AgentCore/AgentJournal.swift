import AgentModels
import AgentTools
import Foundation
import Dispatch

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

/// A trusted Host decision that the external operation did not take effect.
/// An unknown outcome is never a valid basis for abort.
public struct AgentNoEffectConfirmation: Codable, Equatable, Sendable {
    public let basis: String
    public init(basis: String) throws {
        guard !basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentJournalError.invalidRecord
        }
        self.basis = basis
    }
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
    case mutationNeedsReconciliation(callID: ToolCallID)
    case mutationOutput(callID: ToolCallID, output: JSONValue)
    case mutationSettled(callID: ToolCallID, receipt: ToolReceipt, source: AgentMutationSettlementSource)
    case mutationAborted(callID: ToolCallID, confirmation: AgentNoEffectConfirmation)
    case checkpoint(history: [ModelMessage], steeringIDs: [UUID])
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

    func validate() throws {
        guard call.completeness == .complete,
              !call.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !call.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentJournalError.invalidMutationIntent
        }
        if receiptExpectation == nil {
            throw AgentJournalError.invalidMutationIntent
        }
        try ToolResource.validate(resources)
    }
}

package struct AgentJournalRecord: Equatable, Sendable {
    package let sequence: UInt64
    package let timestamp: Date
    package let sessionID: UUID
    package let runID: UUID?
    package let event: AgentJournalEvent

    init(
        sequence: UInt64,
        timestamp: Date,
        sessionID: UUID,
        runID: UUID?,
        event: AgentJournalEvent
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.runID = runID
        self.event = event
    }
}

package enum AgentJournalDurability: Sendable {
    case memory
    case durable
}

package enum AgentJournalStartupAdmissionError: Error, Sendable {
    case deadlineExceeded
}

public enum AgentJournalError: Error, LocalizedError, Equatable, Sendable {
    case invalidHeader
    case invalidFrame
    case invalidRecord
    case checksumMismatch
    case concurrentWriter
    case invalidMutationIntent
    case mutationIntentConflict
    case mutationPending
    case mutationReplayUnavailable
    case mutationRequiresReconciliation
    case mutationNotFound
    case mutationReceiptInvalid
    case mutationMissingReceiptExpectation
    case mutationSettlementRequiresReconciliation
    case persistenceUnavailable(String)
    case sessionLeaseUnavailable
    case storeInUse
    case unsupportedLegacyFormat
    case unsupportedFormat
    case storeClosed
    case commitUnknown
    case maintenanceRequired
    case deadlineExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidHeader: "Agent journal header is invalid."
        case .invalidFrame: "Agent journal frame is invalid."
        case .invalidRecord: "Agent journal record is invalid."
        case .checksumMismatch: "Agent journal checksum verification failed."
        case .concurrentWriter: "Agent journal changed outside this instance."
        case .invalidMutationIntent: "Mutation intent is incomplete or invalid."
        case .mutationIntentConflict: "Mutation intent conflicts with an existing operation."
        case .mutationPending: "An earlier attempt for this mutation is still pending."
        case .mutationReplayUnavailable: "The settled mutation does not contain a durable tool result for replay."
        case .mutationRequiresReconciliation: "An earlier mutation requires reconciliation before another mutation can run."
        case .mutationNotFound: "The mutation intent was not found in the journal."
        case .mutationReceiptInvalid: "The mutation receipt cannot be bound to the durable intent."
        case .mutationMissingReceiptExpectation: "Mutation admission requires a receipt expectation."
        case .mutationSettlementRequiresReconciliation: "Mutation settlement must use the reconciliation API."
        case .persistenceUnavailable(let message): "Agent journal persistence is unavailable: \(message)"
        case .sessionLeaseUnavailable: "The durable Agent session is already active in another process."
        case .storeInUse: "The Journal store has another active writer. Share its open handle within this process."
        case .unsupportedLegacyFormat: "This Journal uses an unsupported legacy format; stop the old workflow."
        case .unsupportedFormat: "This Journal format or schema is unsupported by this version."
        case .storeClosed: "The Journal store is closed."
        case .commitUnknown: "The Journal commit result is uncertain. Stop this execution and inspect the store before retrying."
        case .maintenanceRequired: "Journal maintenance is behind the configured storage budget; retry admission after it progresses."
        case .deadlineExceeded: "The Journal operation exceeded the caller's cooperative deadline."
        }
    }
}

/// Whether a journal is configured for durable mutation persistence.
///
/// This is a capability, not a file-path check. `.durable` means a persistence
/// backend is bound so crash-tail recovery can be attempted. It does not mean
/// every later write will succeed; appends can still throw
/// `persistenceUnavailable`. A future database, remote, or encrypted journal
/// should advertise `.durable` when it can keep an admitted mutation intent
/// across process death.
public enum AgentJournalStorage: Sendable, Equatable {
    /// In-process only. Sufficient for read-only sessions.
    case memory
    /// Persistence mode is configured. Required before a mutation Session can be created.
    case durable
}

/// Durable typed lifecycle log. Mutation success is settlement from a trusted
/// receipt, never an executor that merely returned. Hosts inspect pending
/// work, recover after a crash, reconcile or abort. They cannot append a
/// settlement event directly.
///
/// Read-only Agents may omit a journal or use `.memory` storage. Mutation
/// tools require `.durable` storage at Session creation.
public actor AgentJournal {
    private nonisolated let ioExecutor = JournalIOExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { ioExecutor.asUnownedSerialExecutor() }

    private var records: [AgentJournalRecord]
    private var nextSequence: UInt64
    private let store: (any JournalStore)?
    private var maintenanceTask: Task<JournalMaintenanceStatus, Error>?
    private var maintenanceID: UUID?
    private var maintenanceTick: UInt64 = 0
    private var closing = false
    private var sessionLeases: Set<UUID>
    private var dispatcherLeases: [UUID: (owner: UUID, notify: @Sendable () async -> Void)] = [:]
    /// Immutable configured capability. A durable commit can still fail.
    public nonisolated let storage: AgentJournalStorage

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
        var receipt: ToolReceipt?
        var output: JSONValue?
        var abortConfirmation: AgentNoEffectConfirmation?
    }

    public init() {
        records = []
        nextSequence = 1
        store = nil
        maintenanceTask = nil
        maintenanceID = nil
        sessionLeases = []
        storage = .memory
    }

    package init(store: any JournalStore) {
        records = []
        nextSequence = 1
        self.store = store
        maintenanceTask = nil
        maintenanceID = nil
        sessionLeases = []
        storage = .durable
    }

    package func acquireSessionLease(sessionID: UUID, dispatcherID: UUID? = nil) throws {
        if let owner = dispatcherLeases[sessionID]?.owner, owner != dispatcherID {
            throw AgentFollowUpError.dispatchOwned
        }
        guard !closing, sessionLeases.insert(sessionID).inserted else {
            throw AgentJournalError.sessionLeaseUnavailable
        }
    }

    package func releaseSessionLease(sessionID: UUID) {
        sessionLeases.remove(sessionID)
    }

    package func acquireDispatcherLease(sessionID: UUID, owner: UUID,
                                        allowExistingRun: Bool,
                                        notify: @escaping @Sendable () async -> Void) throws {
        guard storage == .durable else { throw AgentFollowUpError.durableJournalRequired }
        guard !closing, dispatcherLeases[sessionID] == nil else { throw AgentFollowUpError.alreadyDispatching }
        guard allowExistingRun || !sessionLeases.contains(sessionID) else {
            throw AgentSessionError.runInProgress
        }
        dispatcherLeases[sessionID] = (owner, notify)
    }

    package func releaseDispatcherLease(sessionID: UUID, owner: UUID) {
        if dispatcherLeases[sessionID]?.owner == owner { dispatcherLeases.removeValue(forKey: sessionID) }
    }

    /// Returns the most recent canonical session history checkpoint. The
    /// checkpoint is host-neutral and is the only journal payload used to
    /// reconstruct a Session after a process restart.
    public func latestCheckpoint(
        sessionID: UUID
    ) throws -> (history: [ModelMessage], steeringIDs: [UUID])? {
        if let store {
            let current = try store.read { try $0.session(sessionID) }
            guard let current, current.header.historyHead != nil else { return nil }
            return (current.history, current.header.steeringIDs)
        }
        for record in records.reversed() where record.sessionID == sessionID {
            guard case .checkpoint(let history, let steeringIDs) = record.event else { continue }
            return (history: history, steeringIDs: steeringIDs)
        }
        return nil
    }

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

    /// Appends the startup frame while the session is still pre-admission.
    /// Lock acquisition is cancellation/deadline aware; once the frame write
    /// begins, the append is the atomic admission boundary for the Run.
    @discardableResult
    package func appendStartupCheckpoint(
        _ events: [AgentJournalEvent],
        sessionID: UUID,
        runID: UUID,
        deadline: ContinuousClock.Instant,
        timestamp: Date = Date(),
        durability: AgentJournalDurability,
        followUpInputID: String? = nil
    ) throws -> [AgentJournalRecord] {
        try appendCheckpoint(
            events,
            sessionID: sessionID,
            runID: runID,
            timestamp: timestamp,
            durability: durability,
            allowMutationSettlement: false,
            admissionDeadline: deadline,
            checkAdmissionCancellation: true,
            followUpInputID: followUpInputID
        )
    }

    @discardableResult
    package func appendCheckpointForCurrentRun(
        _ events: [AgentJournalEvent],
        sessionID: UUID,
        runID: UUID,
        timestamp: Date = Date(),
        durability: AgentJournalDurability = .memory
    ) throws -> [AgentJournalRecord] {
        if let store {
            let current = try store.read { try $0.header(sessionID)?.lastRunID }
            guard current == runID else { throw CancellationError() }
        } else if records.last(where: { $0.sessionID == sessionID && $0.runID != nil })?.runID != runID {
            throw CancellationError()
        }
        return try appendCheckpoint(
            events,
            sessionID: sessionID,
            runID: runID,
            timestamp: timestamp,
            durability: durability,
            allowMutationSettlement: false
        )
    }

    private func appendCheckpoint(
        _ events: [AgentJournalEvent],
        sessionID: UUID,
        runID: UUID?,
        timestamp: Date,
        durability: AgentJournalDurability,
        allowMutationSettlement: Bool,
        admissionDeadline: ContinuousClock.Instant? = nil,
        checkAdmissionCancellation: Bool = false,
        followUpInputID: String? = nil
    ) throws -> [AgentJournalRecord] {
        try checkStartupAdmission(deadline: admissionDeadline, checkCancellation: checkAdmissionCancellation)
        if let store {
            guard !closing else { throw AgentJournalError.storeClosed }
            let result = try store.write { view in
                try appendToStore(events, sessionID: sessionID, runID: runID,
                                  timestamp: timestamp, view: view,
                                  allowMutationSettlement: allowMutationSettlement,
                                  followUpInputID: followUpInputID)
            }
            scheduleMaintenanceIfNeeded()
            return result
        }
        guard durability == .memory else {
            throw AgentJournalError.persistenceUnavailable("a durable store is required")
        }
        guard followUpInputID == nil else { throw AgentFollowUpError.durableJournalRequired }
        guard !events.isEmpty else { return [] }
        guard allowMutationSettlement || !events.contains(where: Self.isMutationSettlementEvent) else {
            throw AgentJournalError.mutationSettlementRequiresReconciliation
        }
        if events.contains(where: Self.isMutationLifecycleEvent) {
            throw AgentJournalError.persistenceUnavailable("mutation lifecycle events require durable persistence")
        }
        let committed = events.enumerated().map { offset, event in
            AgentJournalRecord(
                sequence: nextSequence + UInt64(offset),
                timestamp: timestamp,
                sessionID: sessionID,
                runID: runID,
                event: event
            )
        }
        records.append(contentsOf: committed)
        nextSequence += UInt64(committed.count)
        return committed
    }

    public func pendingMutations(sessionID: UUID? = nil) throws -> [PendingMutationRecovery] {
        if let store {
            return try store.read { view in
                try view.pending(sessionID: sessionID).map {
                    PendingMutationRecovery(sessionID: $0.sessionID, runID: $0.runID,
                                            intent: $0.intent, state: $0.state)
                }
            }
        }
        return []
    }

    /// Converts an admitted but unsettled intent into a quarantine state. Recovery never invokes the tool.
    public func recoverPendingMutations(sessionID: UUID? = nil) throws -> [PendingMutationRecovery] {
        let intents = try pendingMutations(sessionID: sessionID).filter { $0.state == .intent }
        for pending in intents {
            _ = try append(.mutationNeedsReconciliation(callID: pending.intent.call.id),
                            sessionID: pending.sessionID, runID: pending.runID, durability: .durable)
        }
        return try pendingMutations(sessionID: sessionID)
    }

    /// Records that a mutation executor was reached without a trusted successful receipt.
    package func markMutationNeedsReconciliation(sessionID: UUID, runID: UUID, callID: ToolCallID) throws {
        let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
        guard let record = try mutationRecord(for: key) else { return }
        guard record.state == .intent else { return }
        _ = try append(.mutationNeedsReconciliation(callID: callID), sessionID: sessionID,
                       runID: runID, durability: .durable)
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
        output: JSONValue,
        history: [ModelMessage],
        steeringIDs: [UUID]
    ) throws {
        let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
        guard let record = try mutationRecord(for: key) else { throw AgentJournalError.mutationNotFound }
        guard record.state == .intent else { throw AgentJournalError.mutationRequiresReconciliation }
        guard let expectation = record.intent.receiptExpectation else {
            throw AgentJournalError.mutationMissingReceiptExpectation
        }
        try ToolReceiptValidator.validate(receipt, operationID: record.intent.idempotencyKey, expectation: expectation)
        let accepted = AgentToolReceipt(callID: callID, effect: .mutation, receipt: receipt)
        _ = try appendCheckpoint(
            [
                .toolReceipt(accepted),
                .mutationOutput(callID: callID, output: output),
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

    /// Reconciles an uncertain external effect with a trusted receipt and an
    /// explicit replay result. The conversation and ledger settle together.
    public func reconcileMutation(_ pending: PendingMutationRecovery,
                                  receipt: ToolReceipt, output: JSONValue) throws {
        let key = MutationKey(sessionID: pending.sessionID, runID: pending.runID, callID: pending.intent.call.id)
        guard let record = try mutationRecord(for: key), record.intent == pending.intent else {
            throw AgentJournalError.mutationIntentConflict
        }
        guard record.state == .needsReconciliation, pending.state == .needsReconciliation else {
            throw AgentJournalError.mutationRequiresReconciliation
        }
        guard let expectation = record.intent.receiptExpectation else {
            throw AgentJournalError.mutationMissingReceiptExpectation
        }
        try ToolReceiptValidator.validate(receipt, operationID: record.intent.idempotencyKey, expectation: expectation)
        let checkpoint = try latestCheckpoint(sessionID: pending.sessionID)
        let result = ModelMessage.tool(.init(callID: pending.intent.call.id,
                                             content: [.json(output)], isError: false))
        var history = checkpoint?.history ?? []
        let hasMatchingOpenCall: Bool
        if case .assistant(_, let calls)? = history.last {
            hasMatchingOpenCall = calls.contains { $0.id == pending.intent.call.id }
        } else {
            hasMatchingOpenCall = false
        }
        if !hasMatchingOpenCall {
            history.append(.assistant(content: [], toolCalls: [pending.intent.call]))
        }
        history.append(result)
        let accepted = AgentToolReceipt(callID: pending.intent.call.id, effect: .mutation, receipt: receipt)
        _ = try appendCheckpoint([
            .toolReceipt(accepted),
            .mutationOutput(callID: pending.intent.call.id, output: output),
            .mutationSettled(callID: pending.intent.call.id, receipt: receipt, source: .reconciliation),
            .checkpoint(history: history, steeringIDs: checkpoint?.steeringIDs ?? []),
        ], sessionID: pending.sessionID, runID: pending.runID,
           timestamp: Date(), durability: .durable, allowMutationSettlement: true)
    }

    /// Confirms that a quarantined intent produced no external side effect.
    ///
    /// This trusted Host decision permits a later admission with the same
    /// logical idempotency identity to start a new durable lifecycle.
    public func abortMutation(_ pending: PendingMutationRecovery,
                              confirmedNoEffect: AgentNoEffectConfirmation) throws {
        let key = MutationKey(sessionID: pending.sessionID, runID: pending.runID, callID: pending.intent.call.id)
        guard let record = try mutationRecord(for: key), record.intent == pending.intent else {
            throw AgentJournalError.mutationIntentConflict
        }
        guard record.state == .needsReconciliation, pending.state == .needsReconciliation else {
            throw AgentJournalError.mutationRequiresReconciliation
        }
        _ = try append(
            .mutationAborted(callID: pending.intent.call.id, confirmation: confirmedNoEffect),
            sessionID: pending.sessionID,
            runID: pending.runID,
            durability: .durable
        )
    }

    private static func applyMutationEvent(
        _ event: AgentJournalEvent,
        sessionID: UUID,
        runID: UUID?,
        sequence: UInt64,
        records: inout [MutationKey: MutationRecord],
        identityIndex: inout [String: MutationKey],
        identityMembers: inout [String: Set<MutationKey>],
        unresolvedBySession: inout [UUID: MutationKey]
    ) throws {
        switch event {
        case .pendingMutation(let intent):
            guard let runID else { throw AgentJournalError.invalidRecord }
            try intent.validate()
            let key = MutationKey(sessionID: sessionID, runID: runID, callID: intent.call.id)
            guard unresolvedBySession[sessionID] == nil else {
                throw AgentJournalError.mutationRequiresReconciliation
            }
            let latestMatchingIdentity = identityIndex[intent.idempotencyKey].flatMap { records[$0] }
            guard records[key] == nil else {
                throw AgentJournalError.mutationIntentConflict
            }
            if latestMatchingIdentity != nil,
               latestMatchingIdentity?.state != .aborted {
                throw AgentJournalError.mutationIntentConflict
            }
            records[key] = MutationRecord(
                key: key,
                intent: intent,
                sequence: sequence,
                state: .intent,
                receipt: nil,
                output: nil,
                abortConfirmation: nil
            )
            unresolvedBySession[sessionID] = key
            identityMembers[intent.idempotencyKey, default: []].insert(key)
            Self.refreshIdentityIndex(
                intent.idempotencyKey,
                records: records,
                identityIndex: &identityIndex,
                identityMembers: identityMembers
            )

        case .mutationNeedsReconciliation(let callID):
            guard let runID else { throw AgentJournalError.invalidRecord }
            let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
            guard let record = records[key], record.state == .intent || record.state == .needsReconciliation else {
                throw AgentJournalError.mutationNotFound
            }
            var updated = record
            updated.state = .needsReconciliation
            records[key] = updated
            Self.refreshIdentityIndex(
                updated.intent.idempotencyKey,
                records: records,
                identityIndex: &identityIndex,
                identityMembers: identityMembers
            )

        case .mutationOutput(let callID, let output):
            guard let runID else { throw AgentJournalError.invalidRecord }
            let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
            guard let record = records[key], record.state == .intent || record.state == .needsReconciliation,
                  record.output == nil else {
                throw AgentJournalError.mutationIntentConflict
            }
            var updated = record
            updated.output = output
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
                updated.receipt = receipt
                records[key] = updated
                if unresolvedBySession[sessionID] == key {
                    unresolvedBySession.removeValue(forKey: sessionID)
                }
                Self.refreshIdentityIndex(
                    updated.intent.idempotencyKey,
                    records: records,
                    identityIndex: &identityIndex,
                    identityMembers: identityMembers
                )
            default:
                throw AgentJournalError.mutationIntentConflict
            }

        case .mutationAborted(let callID, let confirmation):
            guard let runID else { throw AgentJournalError.invalidRecord }
            let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
            guard let record = records[key], record.state == .intent || record.state == .needsReconciliation else {
                throw AgentJournalError.mutationNotFound
            }
            var updated = record
            updated.state = .aborted
            updated.abortConfirmation = confirmation
            records[key] = updated
            if unresolvedBySession[sessionID] == key {
                unresolvedBySession.removeValue(forKey: sessionID)
            }
            Self.refreshIdentityIndex(
                updated.intent.idempotencyKey,
                records: records,
                identityIndex: &identityIndex,
                identityMembers: identityMembers
            )

        default:
            break
        }
    }

    private static func refreshIdentityIndex(
        _ idempotencyKey: String,
        records: [MutationKey: MutationRecord],
        identityIndex: inout [String: MutationKey],
        identityMembers: [String: Set<MutationKey>]
    ) {
        let candidates = (identityMembers[idempotencyKey] ?? []).compactMap { records[$0] }
        guard let selected = candidates.max(by: { lhs, rhs in
            let left = identityPriority(lhs.state)
            let right = identityPriority(rhs.state)
            return left == right ? lhs.sequence < rhs.sequence : left < right
        }) else {
            identityIndex.removeValue(forKey: idempotencyKey)
            return
        }
        identityIndex[idempotencyKey] = selected.key
    }

    private static func identityPriority(_ state: AgentMutationState) -> Int {
        switch state {
        case .needsReconciliation: 4
        case .intent: 3
        case .settled: 2
        case .aborted: 1
        }
    }

    private static func isMutationLifecycleEvent(_ event: AgentJournalEvent) -> Bool {
        switch event {
        case .pendingMutation, .mutationNeedsReconciliation, .mutationOutput,
             .mutationSettled, .mutationAborted:
            true
        default:
            false
        }
    }

    private static func isMutationSettlementEvent(_ event: AgentJournalEvent) -> Bool {
        if case .mutationSettled = event { return true }
        return false
    }

    private func checkStartupAdmission(
        deadline: ContinuousClock.Instant?,
        checkCancellation: Bool
    ) throws {
        guard checkCancellation else { return }
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline {
            throw AgentJournalStartupAdmissionError.deadlineExceeded
        }
    }


}

extension AgentJournal: ToolMutationAdmission {
    @discardableResult
    package func admit(_ request: ToolMutationAdmissionRequest) async throws -> ToolMutationAdmissionResult {
        guard !closing else { throw AgentJournalError.storeClosed }
        guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.callID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentJournalError.invalidMutationIntent
        }
        guard request.receiptExpectation != nil else {
            throw AgentJournalError.mutationMissingReceiptExpectation
        }
        let arguments: JSONValue
        do {
            arguments = try JSONValue.decodeToolArguments(request.argumentsJSON)
        } catch {
            throw AgentJournalError.invalidMutationIntent
        }
        try ToolResource.validate(request.resources)
        if let store {
            let decision = try store.write { view -> ToolMutationAdmissionResult in
                if let existing = try view.identity(request.idempotencyKey) {
                    guard existing.intent.call.name == request.name,
                          try JSONValue.decodeToolArguments(existing.intent.call.argumentsJSON) == arguments,
                          existing.intent.resources == request.resources,
                          existing.intent.receiptExpectation == request.receiptExpectation else {
                        throw AgentJournalError.mutationIntentConflict
                    }
                    switch existing.state {
                    case .settled:
                        guard let receipt = existing.receipt else { throw AgentJournalError.mutationIntentConflict }
                        guard let output = existing.output else { throw AgentJournalError.mutationReplayUnavailable }
                        return .settled(receipt: receipt, output: output)
                    case .intent: throw AgentJournalError.mutationPending
                    case .needsReconciliation: throw AgentJournalError.mutationRequiresReconciliation
                    case .aborted: break
                    }
                }
                let call = ToolCall(id: request.callID, name: request.name,
                                    argumentsJSON: request.argumentsJSON, completeness: .complete)
                let intent = try PendingMutationIntent(call: call, resources: request.resources,
                                                       idempotencyKey: request.idempotencyKey,
                                                       receiptExpectation: request.receiptExpectation)
                _ = try appendToStore([.pendingMutation(intent)], sessionID: request.sessionID,
                                      runID: request.runID, timestamp: Date(), view: view,
                                      allowMutationSettlement: false)
                return .admitted
            }
            scheduleMaintenanceIfNeeded()
            return decision
        }
        throw AgentJournalError.persistenceUnavailable("mutation admission requires a durable store")
    }
}

extension AgentJournal {
    private func mutationRecord(for key: MutationKey) throws -> MutationRecord? {
        if let store {
            return try store.read { view in
                try view.mutation(sessionID: key.sessionID, runID: key.runID, callID: key.callID)
                    .map(Self.mutationRecord)
            }
        }
        return nil
    }

    package func hasSessionCreated(_ sessionID: UUID) throws -> Bool {
        if let store { return try store.read { try $0.header(sessionID)?.created ?? false } }
        return records.contains { record in
            guard record.sessionID == sessionID else { return false }
            if case .sessionCreated = record.event { return true }
            return false
        }
    }

    package func hasRun(_ runID: UUID, sessionID: UUID) throws -> Bool {
        if let store { return try store.read { try $0.header(sessionID)?.lastRunID == runID } }
        return records.contains { $0.sessionID == sessionID && $0.runID == runID }
    }

    public func readMessages(sessionID: UUID, after ordinal: UInt64 = 0, limit: Int = 100) throws -> [JournalConversationMessage] {
        guard let store else { throw AgentJournalError.persistenceUnavailable("paginated messages require a durable store") }
        return try store.read { view in
            try view.messages(sessionID: sessionID, after: ordinal, limit: limit)
                .map { JournalConversationMessage(id: $0.id, message: $0.value) }
        }
    }

    package func enqueueFollowUp(_ input: AgentFollowUpInput, sessionID: UUID) async throws -> AgentFollowUpRecord {
        try Task.checkCancellation()
        try input.validate()
        guard let store else { throw AgentFollowUpError.durableJournalRequired }
        let result = try store.write { view -> AgentFollowUpRecord in
            if let existing = try view.followUp(sessionID: sessionID, inputID: input.inputID) {
                guard existing.input.matches(input) else { throw AgentFollowUpError.inputConflict }
                return existing.publicRecord(storeID: store.storeID)
            }
            var head = try view.followUpHead(sessionID: sessionID)
            guard head.queuedCount < 128,
                  input.text.utf8.count <= 8 * 1024 * 1024 - head.queuedBytes else {
                throw AgentFollowUpError.queueFull
            }
            guard head.revision < .max, head.nextOrdinal < .max else { throw AgentJournalError.invalidRecord }
            let oldRevision = head.revision
            let ordinal = head.nextOrdinal
            var changes: [JournalStoredFollowUp] = []
            if let last = head.lastQueued {
                guard var tail = try view.followUps(sessionID: sessionID, after: last, limit: 1).first,
                      tail.ordinal == last, tail.state == .queued,
                      tail.nextQueued == nil else { throw AgentJournalError.invalidRecord }
                tail.nextQueued = ordinal
                changes.append(tail)
            } else { head.firstQueued = ordinal }
            head.lastQueued = ordinal
            head.nextOrdinal += 1
            head.revision += 1
            head.queuedCount += 1
            head.queuedBytes += input.text.utf8.count
            let accepted = JournalStoredFollowUp(sessionID: sessionID, ordinal: ordinal,
                                                 input: input, state: .queued)
            changes.append(accepted)
            try view.publishFollowUp(.init(sessionID: sessionID, expectedRevision: oldRevision,
                                            head: head, records: changes))
            return accepted.publicRecord(storeID: store.storeID)
        }
        scheduleMaintenanceIfNeeded()
        if let notify = dispatcherLeases[sessionID]?.notify { await notify() }
        return result
    }

    package func followUp(sessionID: UUID, inputID: String) throws -> AgentFollowUpRecord? {
        guard let store else { throw AgentFollowUpError.durableJournalRequired }
        return try store.read { view in
            try view.followUp(sessionID: sessionID, inputID: inputID)?.publicRecord(storeID: store.storeID)
        }
    }

    package func followUpText(sessionID: UUID, inputID: String) throws -> String {
        guard let store else { throw AgentFollowUpError.durableJournalRequired }
        return try store.read { view in
            guard let record = try view.followUp(sessionID: sessionID, inputID: inputID) else {
                throw AgentFollowUpError.missingInput
            }
            return record.input.text
        }
    }

    package func followUps(sessionID: UUID, after ordinal: UInt64?, limit: Int) throws -> [AgentFollowUpRecord] {
        guard let store else { throw AgentFollowUpError.durableJournalRequired }
        guard (1...100).contains(limit) else { throw AgentFollowUpError.invalidInput }
        guard ordinal != .max else { return [] }
        return try store.read { view in
            try view.followUps(sessionID: sessionID, after: ordinal.map { $0 + 1 } ?? 0, limit: limit)
                .map { $0.publicRecord(storeID: store.storeID) }
        }
    }

    package func firstQueuedFollowUp(sessionID: UUID) throws -> JournalStoredFollowUp? {
        guard let store else { throw AgentFollowUpError.durableJournalRequired }
        return try store.read { view in
            let head = try view.followUpHead(sessionID: sessionID)
            guard let first = head.firstQueued else { return nil }
            guard let record = try view.followUps(sessionID: sessionID, after: first, limit: 1).first,
                  record.state == .queued else { throw AgentJournalError.invalidRecord }
            return record
        }
    }

    package func interruptedFollowUp(sessionID: UUID) throws -> JournalStoredFollowUp? {
        guard let store else { throw AgentFollowUpError.durableJournalRequired }
        return try store.read { view in
            let head = try view.followUpHead(sessionID: sessionID)
            guard head.lastAdmitted != head.lastReleased else { return nil }
            guard let ordinal = head.lastAdmitted,
                  let record = try view.followUps(sessionID: sessionID, after: ordinal, limit: 1).first,
                  record.ordinal == ordinal,
                  case .admitted = record.state else { throw AgentJournalError.invalidRecord }
            return record
        }
    }

    package func releaseCompletedFollowUp(sessionID: UUID, inputID: String, runID: UUID) throws {
        guard let store else { throw AgentFollowUpError.durableJournalRequired }
        try store.write { view in
            let head = try view.followUpHead(sessionID: sessionID)
            guard let record = try view.followUp(sessionID: sessionID, inputID: inputID),
                  case .admitted(let originalRun, _) = record.state,
                  originalRun == runID, head.lastAdmitted == record.ordinal,
                  head.lastReleased != record.ordinal, head.revision < .max else {
                throw AgentFollowUpError.staleDispatch
            }
            var updated = head
            updated.revision += 1
            updated.lastReleased = record.ordinal
            try view.publishFollowUp(.init(sessionID: sessionID, expectedRevision: head.revision,
                                            head: updated, records: []))
        }
        scheduleMaintenanceIfNeeded()
    }

    package func releaseInspectedFollowUp(sessionID: UUID, inputID: String) throws {
        guard let store else { throw AgentFollowUpError.durableJournalRequired }
        try store.write { view in
            let head = try view.followUpHead(sessionID: sessionID)
            guard let record = try view.followUp(sessionID: sessionID, inputID: inputID),
                  case .admitted = record.state, head.lastAdmitted == record.ordinal,
                  head.lastReleased != record.ordinal, head.revision < .max,
                  try view.pending(sessionID: sessionID).isEmpty else {
                throw AgentFollowUpError.needsInspection
            }
            var updated = head
            updated.revision += 1
            updated.lastReleased = record.ordinal
            try view.publishFollowUp(.init(sessionID: sessionID, expectedRevision: head.revision,
                                            head: updated, records: []))
        }
        scheduleMaintenanceIfNeeded()
    }

    package func withdrawFollowUp(sessionID: UUID, inputID: String) async throws -> AgentFollowUpWithdrawal {
        try Task.checkCancellation()
        guard let store else { throw AgentFollowUpError.durableJournalRequired }
        let result = try store.write { view -> AgentFollowUpWithdrawal in
            guard var entry = try view.followUp(sessionID: sessionID, inputID: inputID) else {
                throw AgentFollowUpError.missingInput
            }
            switch entry.state {
            case .withdrawn: return .withdrawn
            case .admitted(let runID, let messageID):
                return .alreadyAdmitted(runID: runID, formalMessageID: messageID)
            case .queued: break
            }
            var head = try view.followUpHead(sessionID: sessionID)
            let oldRevision = head.revision
            guard head.revision < .max, head.queuedCount > 0,
                  head.queuedBytes >= entry.input.text.utf8.count else { throw AgentJournalError.invalidRecord }
            var changes: [JournalStoredFollowUp] = []
            if head.firstQueued == entry.ordinal {
                head.firstQueued = entry.nextQueued
            } else {
                var cursor = head.firstQueued
                var predecessor: JournalStoredFollowUp?
                for _ in 0..<head.queuedCount {
                    guard let ordinal = cursor,
                          let candidate = try view.followUps(sessionID: sessionID, after: ordinal, limit: 1).first,
                          candidate.ordinal == ordinal, candidate.state == .queued else {
                        throw AgentJournalError.invalidRecord
                    }
                    if candidate.nextQueued == entry.ordinal { predecessor = candidate; break }
                    cursor = candidate.nextQueued
                }
                guard var previous = predecessor else { throw AgentJournalError.invalidRecord }
                previous.nextQueued = entry.nextQueued
                changes.append(previous)
            }
            if head.lastQueued == entry.ordinal { head.lastQueued = changes.last?.ordinal }
            head.queuedCount -= 1
            head.queuedBytes -= entry.input.text.utf8.count
            if head.queuedCount == 0 { head.firstQueued = nil; head.lastQueued = nil }
            head.revision += 1
            entry.state = .withdrawn
            entry.nextQueued = nil
            changes.append(entry)
            try view.publishFollowUp(.init(sessionID: sessionID, expectedRevision: oldRevision,
                                            head: head, records: changes))
            return .withdrawn
        }
        scheduleMaintenanceIfNeeded()
        if let notify = dispatcherLeases[sessionID]?.notify { await notify() }
        return result
    }

    public func mutationStatus(identity: String) throws -> JournalMutationStatus? {
        guard let store else { return nil }
        return try store.read { view in
            try view.identity(identity).map {
                JournalMutationStatus(state: $0.state, receipt: $0.receipt,
                                      replayOutput: $0.output, abortConfirmation: $0.abortConfirmation)
            }
        }
    }

    private static func formalMessages(_ history: [ModelMessage]) -> [ModelMessage] {
        var index = 0
        while index < history.count {
            switch history[index] {
            case .system, .developer: index += 1
            default: return Array(history[index...])
            }
        }
        return []
    }

    private static func mutationRecord(_ stored: JournalStoredMutation) -> MutationRecord {
        MutationRecord(key: MutationKey(sessionID: stored.sessionID, runID: stored.runID,
                                        callID: stored.intent.call.id),
                       intent: stored.intent, sequence: stored.sequence, state: stored.state,
                       receipt: stored.receipt, output: stored.output,
                       abortConfirmation: stored.abortConfirmation)
    }

    private static func storedMutation(_ record: MutationRecord) -> JournalStoredMutation {
        JournalStoredMutation(sessionID: record.key.sessionID, runID: record.key.runID,
                              intent: record.intent, sequence: record.sequence, state: record.state,
                              receipt: record.receipt, output: record.output,
                              abortConfirmation: record.abortConfirmation)
    }

    private func appendToStore(
        _ events: [AgentJournalEvent], sessionID: UUID, runID: UUID?, timestamp: Date,
        view: any JournalStoreView, allowMutationSettlement: Bool,
        followUpInputID: String? = nil
    ) throws -> [AgentJournalRecord] {
        guard !events.isEmpty else { return [] }
        guard allowMutationSettlement || !events.contains(where: Self.isMutationSettlementEvent) else {
            throw AgentJournalError.mutationSettlementRequiresReconciliation
        }
        let initialHeader = try view.header(sessionID) ?? JournalSessionHeader()
        let sequence = try view.nextRecordSequence()
        let committed = events.enumerated().map { offset, event in
            AgentJournalRecord(sequence: sequence + UInt64(offset), timestamp: timestamp,
                               sessionID: sessionID, runID: runID, event: event)
        }
        var storedRecords: [MutationKey: MutationRecord] = [:]
        var identityIndex: [String: MutationKey] = [:]
        var identityMembers: [String: Set<MutationKey>] = [:]
        var unresolvedBySession: [UUID: MutationKey] = [:]
        func include(_ stored: JournalStoredMutation) {
            let record = Self.mutationRecord(stored)
            storedRecords[record.key] = record
            identityMembers[stored.intent.idempotencyKey, default: []].insert(record.key)
            Self.refreshIdentityIndex(stored.intent.idempotencyKey, records: storedRecords,
                                      identityIndex: &identityIndex,
                                      identityMembers: identityMembers)
            if stored.state == .intent || stored.state == .needsReconciliation {
                unresolvedBySession[stored.sessionID] = record.key
            }
        }
        if let unresolved = try view.pending(sessionID: sessionID).first { include(unresolved) }
        var changedKey: MutationKey?
        for (offset, event) in events.enumerated() {
            let callID: ToolCallID?
            switch event {
            case .pendingMutation(let intent):
                callID = intent.call.id
                if let previous = try view.identity(intent.idempotencyKey) {
                    if storedRecords[Self.mutationRecord(previous).key] == nil { include(previous) }
                    guard previous.intent.call.name == intent.call.name,
                          try JSONValue.decodeToolArguments(previous.intent.call.argumentsJSON)
                              == JSONValue.decodeToolArguments(intent.call.argumentsJSON),
                          previous.intent.resources == intent.resources,
                          previous.intent.receiptExpectation == intent.receiptExpectation else {
                        throw AgentJournalError.mutationIntentConflict
                    }
                }
            case .mutationNeedsReconciliation(let id),
                 .mutationOutput(let id, _), .mutationSettled(let id, _, _), .mutationAborted(let id, _):
                callID = id
            default: callID = nil
            }
            if let callID, let runID {
                let key = MutationKey(sessionID: sessionID, runID: runID, callID: callID)
                if storedRecords[key] == nil,
                   let previous = try view.mutation(sessionID: sessionID, runID: runID, callID: callID) {
                    include(previous)
                }
                changedKey = key
            }
            try Self.applyMutationEvent(event, sessionID: sessionID, runID: runID,
                                        sequence: sequence + UInt64(offset),
                                        records: &storedRecords,
                                        identityIndex: &identityIndex,
                                        identityMembers: &identityMembers,
                                        unresolvedBySession: &unresolvedBySession)
        }
        var nextHeader = initialHeader
        nextHeader.revision += 1
        nextHeader.created = nextHeader.created || events.contains { if case .sessionCreated = $0 { return true }; return false }
        if let runID { nextHeader.lastRunID = runID }
        var messageStart = initialHeader.messageCount
        var changedMessages: [JournalMessage] = []
        for event in events {
            if case .checkpoint(let history, let steeringIDs) = event {
                let formal = Self.formalMessages(history)
                guard initialHeader.messageCount <= UInt64(formal.count) else {
                    throw AgentJournalError.concurrentWriter
                }
                (messageStart, changedMessages) = try Self.messageChange(
                    formal, previousCount: initialHeader.messageCount,
                    sessionID: sessionID, view: view
                )
                nextHeader.steeringIDs = steeringIDs
            }
        }
        nextHeader.messageCount = messageStart + UInt64(changedMessages.count)
        if let pending = unresolvedBySession[sessionID], let record = storedRecords[pending] {
            nextHeader.pendingIdentity = record.intent.idempotencyKey
        } else if changedKey != nil {
            nextHeader.pendingIdentity = nil
        }
        let mutation = changedKey.flatMap { storedRecords[$0] }.map(Self.storedMutation)
        let admission = try followUpInputID.map { id in
            JournalFollowUpAdmission(inputID: id,
                expectedQueueRevision: try view.followUpHead(sessionID: sessionID).revision)
        }
        try view.publish(JournalStoreChange(sessionID: sessionID,
                                            expectedRevision: initialHeader.revision,
                                            header: nextHeader,
                                            messageStart: messageStart, messages: changedMessages,
                                            mutation: mutation, records: committed,
                                            followUpAdmission: admission))
        return committed
    }

    /// A tool batch may enlarge its assistant call set and insert a completed
    /// result ahead of an earlier result. Only that active, paired tail may be
    /// republished; stable message IDs follow unchanged results by call ID.
    private static func messageChange(
        _ formal: [ModelMessage], previousCount: UInt64, sessionID: UUID,
        view: any JournalStoreView
    ) throws -> (UInt64, [JournalMessage]) {
        let appendFrom = Int(previousCount)
        var tailStart: Int?
        for index in formal.indices.reversed() {
            if case .assistant(_, let calls) = formal[index], !calls.isEmpty,
               formal[(index + 1)...].allSatisfy({ if case .tool = $0 { true } else { false } }) {
                tailStart = index
                break
            }
        }
        guard let start = tailStart, start < appendFrom else {
            return (previousCount, formal.dropFirst(appendFrom).map(JournalMessage.init(value:)))
        }
        var oldTail: [JournalMessage] = []
        var cursor = UInt64(start)
        while cursor < previousCount {
            let page = try view.messages(sessionID: sessionID, after: cursor,
                                         limit: Int(min(1000, previousCount - cursor)))
            guard !page.isEmpty else { throw AgentJournalError.invalidRecord }
            oldTail.append(contentsOf: page)
            cursor += UInt64(page.count)
        }
        let candidateTail = Array(formal[start...])
        if oldTail.map(\.value) == Array(formal[start..<appendFrom]) {
            return (previousCount, formal.dropFirst(appendFrom).map(JournalMessage.init(value:)))
        }
        guard case .assistant(_, let oldCalls) = oldTail.first?.value,
              case .assistant(_, let newCalls) = candidateTail.first,
              oldCalls.allSatisfy({ old in newCalls.contains(old) }),
              candidateTail.dropFirst().allSatisfy({ if case .tool = $0 { true } else { false } }) else {
            throw AgentJournalError.concurrentWriter
        }
        var oldResults: [ToolCallID: JournalMessage] = [:]
        for old in oldTail.dropFirst() {
            guard case .tool(let value) = old.value,
                  oldResults.updateValue(old, forKey: value.callID) == nil else {
                throw AgentJournalError.invalidRecord
            }
        }
        let currentResults = candidateTail.dropFirst().compactMap { message -> ToolResultMessage? in
            if case .tool(let result) = message { return result }
            return nil
        }
        guard oldResults.allSatisfy({ key, prior in
            currentResults.contains { result in
                result.callID == key && prior.value == .tool(result)
            }
        }) else { throw AgentJournalError.concurrentWriter }
        let replacement = candidateTail.enumerated().map { offset, value in
            if offset == 0, let assistant = oldTail.first {
                return JournalMessage(id: assistant.id, value: value)
            }
            if case .tool(let result) = value,
               let prior = oldResults[result.callID] {
                return JournalMessage(id: prior.id, value: value)
            }
            return JournalMessage(value: value)
        }
        return (UInt64(start), replacement)
    }

    private func scheduleMaintenanceIfNeeded() {
        guard let store, maintenanceTask == nil, !closing else { return }
        maintenanceTick &+= 1
        let status = try? store.status()
        guard (status?.sealedSegments ?? 0) > 0 ||
                (status?.pendingGarbageSegments ?? 0) > 0 ||
                (status?.pendingGarbagePacks ?? 0) > 0
                || maintenanceTick.isMultiple(of: 32) else { return }
        let task = Task { try await store.maintain() }
        let id = UUID()
        maintenanceID = id
        maintenanceTask = task
        Task { [weak self] in
            let outcome = await task.result
            await self?.maintenanceDidComplete(id: id, succeeded: (try? outcome.get()) != nil)
        }
    }

    private func maintenanceDidComplete(id: UUID, succeeded: Bool) {
        guard maintenanceID == id else { return }
        maintenanceID = nil
        maintenanceTask = nil
        if succeeded { scheduleMaintenanceIfNeeded() }
    }

    public func maintenanceStatus() throws -> JournalMaintenanceStatus? {
        try store?.maintenanceStatus()
    }

    public func storageMetrics() -> JournalStorageMetrics? { store?.metrics() }

    public func storeIdentity() -> JournalStoreIdentity? {
        store.map { JournalStoreIdentity(storeID: $0.storeID, operationDomain: $0.operationDomain) }
    }

    public func storeStatus() throws -> JournalStoreStatus? { try store?.status() }

    @discardableResult
    public func requestMaintenance() async throws -> JournalMaintenanceStatus? {
        guard let store else { return nil }
        let id = maintenanceID ?? UUID()
        let task = maintenanceTask ?? Task { try await store.maintain() }
        maintenanceID = id
        maintenanceTask = task
        do {
            let result = try await task.value
            maintenanceDidComplete(id: id, succeeded: true)
            try Task.checkCancellation()
            return result
        } catch {
            maintenanceDidComplete(id: id, succeeded: false)
            throw error
        }
    }

    public func close() async throws {
        guard sessionLeases.isEmpty, dispatcherLeases.isEmpty else { throw AgentJournalError.sessionLeaseUnavailable }
        closing = true
        if let maintenanceTask {
            _ = await maintenanceTask.result
            self.maintenanceTask = nil
            maintenanceID = nil
        }
        try store?.close()
    }
}
