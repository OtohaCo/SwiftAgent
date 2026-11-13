import AgentCore
import AgentModels
import AgentTools
import Crypto
import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CAgentSQLite
#endif

public enum SQLiteJournalLockWait: Sendable {
    case failFast
    case until(ContinuousClock.Instant)
}

public enum SQLiteJournalDurability: Sendable, Equatable {
    case fullSync
    case appleFullFsync
}

package enum SQLiteJournalFaultStage: Sendable, Equatable {
    case beforeCommit
    case afterCommit
    case duringMaintenanceSnapshot
    case beforeSessionRead
}

public enum AgentSQLiteJournal {
    private static let openingQueue = DispatchQueue(
        label: "SwiftAgent.JournalSQLiteStore.open",
        qos: .utility,
        attributes: .concurrent
    )

    private static func normalized(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? AgentJournalError { return error }
        if let error = error as? AgentAuthorizationError { return error }
        if let error = error as? AgentFollowUpError { return error }
        if let error = error as? AgentRunAdmissionError { return error }
        if error is DecodingError { return AgentJournalError.invalidRecord }
        return AgentJournalError.persistenceUnavailable(error.localizedDescription)
    }

    public static func create(
        at directory: URL,
        operationDomain: String,
        durability: SQLiteJournalDurability = .fullSync,
        supportsAdmissionRejections: Bool = false,
        supportsAuthorizationAudit: Bool = false,
        supportsConfirmedNoEffect: Bool = false,
        supportsPerCallFollowUps: Bool = false,
        supportsRunRecords: Bool = false,
        supportsImageContent: Bool = false,
        supportsNativeContext: Bool = false,
        supportsContextHandoff: Bool = false,
        supportsFileContent: Bool = false,
        supportsIncompleteContextHandoff: Bool = false
    ) throws -> AgentJournal {
        do {
            let store = try AgentJournalSQLiteStore.create(
                at: directory,
                domain: operationDomain,
                durability: durability,
                supportsAdmissionRejections: supportsAdmissionRejections,
                supportsAuthorizationAudit: supportsAuthorizationAudit,
                supportsConfirmedNoEffect: supportsConfirmedNoEffect,
                supportsPerCallFollowUps: supportsPerCallFollowUps,
                supportsRunRecords: supportsRunRecords,
                supportsImageContent: supportsImageContent,
                supportsNativeContext: supportsNativeContext,
                supportsContextHandoff: supportsContextHandoff,
                supportsFileContent: supportsFileContent,
                supportsIncompleteContextHandoff: supportsIncompleteContextHandoff
            )
            return AgentJournal(store: store)
        } catch {
            throw normalized(error)
        }
    }

    package static func createForTesting(
        at directory: URL,
        operationDomain: String,
        durability: SQLiteJournalDurability = .fullSync,
        supportsAdmissionRejections: Bool = false,
        supportsAuthorizationAudit: Bool = false,
        supportsConfirmedNoEffect: Bool = false,
        supportsPerCallFollowUps: Bool = false,
        supportsRunRecords: Bool = false,
        supportsImageContent: Bool = false,
        supportsNativeContext: Bool = false,
        supportsContextHandoff: Bool = false,
        supportsFileContent: Bool = false,
        supportsIncompleteContextHandoff: Bool = false,
        fault: @escaping @Sendable (SQLiteJournalFaultStage) throws -> Void
    ) throws -> AgentJournal {
        do {
            let store = try AgentJournalSQLiteStore.create(
                at: directory,
                domain: operationDomain,
                durability: durability,
                supportsAdmissionRejections: supportsAdmissionRejections,
                supportsAuthorizationAudit: supportsAuthorizationAudit,
                supportsConfirmedNoEffect: supportsConfirmedNoEffect,
                supportsPerCallFollowUps: supportsPerCallFollowUps,
                supportsRunRecords: supportsRunRecords,
                supportsImageContent: supportsImageContent,
                supportsNativeContext: supportsNativeContext,
                supportsContextHandoff: supportsContextHandoff,
                supportsFileContent: supportsFileContent,
                supportsIncompleteContextHandoff: supportsIncompleteContextHandoff,
                fault: fault
            )
            return AgentJournal(store: store)
        } catch {
            throw normalized(error)
        }
    }

    public static func createAsync(
        at directory: URL,
        operationDomain: String,
        durability: SQLiteJournalDurability = .fullSync,
        supportsAdmissionRejections: Bool = false,
        supportsAuthorizationAudit: Bool = false,
        supportsConfirmedNoEffect: Bool = false,
        supportsPerCallFollowUps: Bool = false,
        supportsRunRecords: Bool = false,
        supportsImageContent: Bool = false,
        supportsNativeContext: Bool = false,
        supportsContextHandoff: Bool = false,
        supportsFileContent: Bool = false,
        supportsIncompleteContextHandoff: Bool = false,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> AgentJournal {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw AgentJournalError.deadlineExceeded }
        return try await runAsyncOpen(deadline: deadline) { _ in
            try AgentJournalSQLiteStore.create(
                at: directory,
                domain: operationDomain,
                durability: durability,
                supportsAdmissionRejections: supportsAdmissionRejections,
                supportsAuthorizationAudit: supportsAuthorizationAudit,
                supportsConfirmedNoEffect: supportsConfirmedNoEffect,
                supportsPerCallFollowUps: supportsPerCallFollowUps,
                supportsRunRecords: supportsRunRecords,
                supportsImageContent: supportsImageContent,
                supportsNativeContext: supportsNativeContext,
                supportsContextHandoff: supportsContextHandoff,
                supportsFileContent: supportsFileContent,
                supportsIncompleteContextHandoff: supportsIncompleteContextHandoff
            )
        }
    }

    public static func open(
        at directory: URL,
        durability: SQLiteJournalDurability = .fullSync
    ) throws -> AgentJournal {
        do {
            return AgentJournal(store: try AgentJournalSQLiteStore.open(at: directory, durability: durability))
        } catch {
            throw normalized(error)
        }
    }

    public static func openAsync(
        at directory: URL,
        durability: SQLiteJournalDurability = .fullSync,
        writerLockWait: SQLiteJournalLockWait = .failFast,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> AgentJournal {
        try Task.checkCancellation()
        let effectiveDeadline: ContinuousClock.Instant?
        switch writerLockWait {
        case .failFast:
            effectiveDeadline = deadline
        case .until(let limit):
            effectiveDeadline = deadline.map { min($0, limit) } ?? limit
        }
        if let effectiveDeadline, ContinuousClock.now >= effectiveDeadline {
            throw AgentJournalError.deadlineExceeded
        }
        return try await runAsyncOpen(deadline: effectiveDeadline) { cancellation in
            let lockWait: (@Sendable () throws -> Void)?
            switch writerLockWait {
            case .failFast:
                lockWait = nil
            case .until:
                lockWait = { try cancellation.waitStep(until: effectiveDeadline!) }
            }
            return try AgentJournalSQLiteStore.open(
                at: directory,
                durability: durability,
                lockRetry: lockWait
            )
        }
    }

    /// Offline, writer-exclusive upgrade of a context-handoff store to one that can retire a turn that did not
    /// finish (incomplete context handoff, with file references). Close and drain every owner first. History,
    /// effects and Run terminals are untouched: only the store's capabilities change, in one SQLite transaction,
    /// so the outcome is either the old store or the upgraded one. A store without context handoff, or one
    /// already upgraded, is refused with `unsupportedFormat`.
    public static func upgradeForIncompleteContextHandoff(
        at directory: URL,
        durability: SQLiteJournalDurability = .fullSync
    ) throws -> AgentJournal {
        do {
            return AgentJournal(store: try AgentJournalSQLiteStore.upgradeForIncompleteContextHandoff(
                at: directory, durability: durability))
        } catch {
            throw normalized(error)
        }
    }

    private static func runAsyncOpen(
        deadline: ContinuousClock.Instant?,
        operation: @escaping @Sendable (AsyncOpenGate) throws -> AgentJournalSQLiteStore
    ) async throws -> AgentJournal {
        let gate = AsyncOpenGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                openingQueue.async {
                    do {
                        if gate.isCancelled { throw CancellationError() }
                        if let deadline, ContinuousClock.now >= deadline { throw AgentJournalError.deadlineExceeded }
                        let store = try operation(gate)
                        if gate.isCancelled || (deadline.map { ContinuousClock.now >= $0 } ?? false) {
                            try? store.close()
                            if gate.isCancelled { throw CancellationError() }
                            throw AgentJournalError.deadlineExceeded
                        }
                        continuation.resume(returning: AgentJournal(store: store))
                    } catch {
                        continuation.resume(throwing: normalized(error))
                    }
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }
}

private final class AsyncOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let semaphore = DispatchSemaphore(value: 0)

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
        semaphore.signal()
    }

    func waitStep(until deadline: ContinuousClock.Instant) throws {
        if isCancelled { throw CancellationError() }
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw AgentJournalError.deadlineExceeded }
        let step = min(remaining, .milliseconds(25))
        let parts = step.components
        let ns = Int(parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000)
        _ = semaphore.wait(timeout: .now() + .nanoseconds(ns))
        if isCancelled { throw CancellationError() }
        if ContinuousClock.now >= deadline { throw AgentJournalError.deadlineExceeded }
    }
}

package final class AgentJournalSQLiteStore: JournalStore, @unchecked Sendable {
    static let magic = "SWIFTAGENT-SQLITE-JOURNAL"
    static let supportedSchemaVersion = 1
    /// The same name the segmented file store uses, so a Host waiting for a released store watches one file.
    static let writerLockName = ".writer.lock"

    package let directoryURL: URL
    package let storeID: UUID
    package let operationDomain: String
    package let supportsAdmissionRejections: Bool
    package let supportsAuthorizationAudit: Bool
    package let supportsConfirmedNoEffect: Bool
    package let noEffectProofVersion: Int
    package let supportsPerCallFollowUps: Bool
    package let supportsRunRecords: Bool
    package let supportsImageContent: Bool
    package let supportsFileContent: Bool
    package let supportsNativeContext: Bool
    package let supportsContextHandoff: Bool
    package let supportsIncompleteContextHandoff: Bool

    private let writeLock = NSLock()
    private let readLock = NSLock()
    private let countersLock = NSLock()
    private var writerDB: OpaquePointer?
    private var readerDB: OpaquePointer?
    private var writerLock: SQLiteJournalWriterLock?
    private var closed = false
    private var poisoned = false
    let fault: (@Sendable (SQLiteJournalFaultStage) throws -> Void)?

    var bytesReadCount: UInt64 = 0
    var decodedBatchesCount: UInt64 = 0
    var bytesWrittenCount: UInt64 = 0
    var committedBatchesCount: UInt64 = 0
    var writeLockNanosecondsCount: UInt64 = 0
    var maintenanceNanosecondsCount: UInt64 = 0
    var encodedBatchesCount: UInt64 = 0
    var maintenanceRunCount: UInt64 = 0

    /// WAL size at which `status()` asks for maintenance. 4 MiB is about SQLite's default auto-checkpoint
    /// window (1000 pages of 4 KiB): below it the WAL is normal working space, not work to relieve.
    package static let walMaintenanceThresholdBytes: UInt64 = 4 * 1024 * 1024
    /// WAL size the last maintenance left behind (non-zero when a reader kept the checkpoint from truncating).
    var walBytesAfterMaintenance: UInt64 = 0

    private func currentWALBytes() -> UInt64 {
        let path = directoryURL.appendingPathComponent("journal.sqlite3").path + "-wal"
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
    }

    /// Number of `maintain()` runs so far; lets tests check that background maintenance goes quiet.
    package func maintenanceRuns() -> UInt64 {
        countersLock.withLock { maintenanceRunCount }
    }

    func noteReadBytes(_ count: Int, decoded: UInt64 = 1) {
        countersLock.withLock {
            bytesReadCount += UInt64(max(0, count))
            decodedBatchesCount += decoded
        }
    }

    struct CapabilitiesRecord: Codable, Equatable {
        let supportsAdmissionRejections: Bool
        let supportsAuthorizationAudit: Bool
        let supportsConfirmedNoEffect: Bool
        let noEffectProofVersion: Int
        let supportsPerCallFollowUps: Bool
        let supportsRunRecords: Bool
        let supportsImageContent: Bool
        let supportsFileContent: Bool
        let supportsNativeContext: Bool
        let supportsContextHandoff: Bool
        let supportsIncompleteContextHandoff: Bool
    }

    struct MetaState {
        var logicalSequence: UInt64
        var nextRecordSequence: UInt64
        var layoutGeneration: UInt64
        var auditHighWater: UInt64
    }

    private init(
        directoryURL: URL,
        storeID: UUID,
        operationDomain: String,
        capabilities: CapabilitiesRecord,
        writerDB: OpaquePointer,
        readerDB: OpaquePointer,
        writerLock: SQLiteJournalWriterLock,
        fault: (@Sendable (SQLiteJournalFaultStage) throws -> Void)?
    ) {
        self.directoryURL = directoryURL
        self.storeID = storeID
        self.operationDomain = operationDomain
        self.supportsAdmissionRejections = capabilities.supportsAdmissionRejections
        self.supportsAuthorizationAudit = capabilities.supportsAuthorizationAudit
        self.supportsConfirmedNoEffect = capabilities.supportsConfirmedNoEffect
        self.noEffectProofVersion = capabilities.noEffectProofVersion
        self.supportsPerCallFollowUps = capabilities.supportsPerCallFollowUps
        self.supportsRunRecords = capabilities.supportsRunRecords
        self.supportsImageContent = capabilities.supportsImageContent
        self.supportsFileContent = capabilities.supportsFileContent
        self.supportsNativeContext = capabilities.supportsNativeContext
        self.supportsContextHandoff = capabilities.supportsContextHandoff
        self.supportsIncompleteContextHandoff = capabilities.supportsIncompleteContextHandoff
        self.writerDB = writerDB
        self.readerDB = readerDB
        self.writerLock = writerLock
        self.fault = fault
    }

    deinit {
        if let db = readerDB { sqlite3_close_v2(db) }
        if let db = writerDB { sqlite3_close_v2(db) }
        try? writerLock?.close()
    }

    static func create(
        at url: URL,
        domain: String,
        durability: SQLiteJournalDurability,
        supportsAdmissionRejections: Bool = false,
        supportsAuthorizationAudit: Bool = false,
        supportsConfirmedNoEffect: Bool = false,
        supportsPerCallFollowUps: Bool = false,
        supportsRunRecords: Bool = false,
        supportsImageContent: Bool = false,
        supportsNativeContext: Bool = false,
        supportsContextHandoff: Bool = false,
        supportsFileContent: Bool = false,
        supportsIncompleteContextHandoff: Bool = false,
        fault: (@Sendable (SQLiteJournalFaultStage) throws -> Void)? = nil
    ) throws -> AgentJournalSQLiteStore {
        guard !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentJournalError.invalidRecord
        }
        let directory = url.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw AgentJournalError.persistenceUnavailable("create requires a new directory")
        }
        #if os(Windows)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #else
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #endif
        let writerLock = try acquireExclusiveLock(at: directory.appendingPathComponent(writerLockName), retry: nil)
        let dbURL = directory.appendingPathComponent("journal.sqlite3")
        let writer = try openConnection(at: dbURL, readOnly: false, durability: durability)
        do {
            try initializeSchema(on: writer)
            let fileCap = supportsFileContent || supportsIncompleteContextHandoff
            let handoffCap = supportsContextHandoff || fileCap
            let nativeCap = supportsNativeContext || handoffCap
            let imageCap = supportsImageContent || nativeCap
            let runCap = supportsRunRecords || imageCap
            let followUpCap = supportsPerCallFollowUps || runCap
            let noEffectCap = supportsConfirmedNoEffect || followUpCap
            let auditCap = supportsAuthorizationAudit || noEffectCap
            let rejectCap = supportsAdmissionRejections || auditCap
            let caps = CapabilitiesRecord(
                supportsAdmissionRejections: rejectCap,
                supportsAuthorizationAudit: auditCap,
                supportsConfirmedNoEffect: noEffectCap,
                noEffectProofVersion: noEffectCap ? 2 : 0,
                supportsPerCallFollowUps: followUpCap,
                supportsRunRecords: runCap,
                supportsImageContent: imageCap,
                supportsFileContent: fileCap,
                supportsNativeContext: nativeCap,
                supportsContextHandoff: handoffCap,
                supportsIncompleteContextHandoff: supportsIncompleteContextHandoff
            )
            let storeID = UUID()
            let capsBytes = try canonicalJSON(caps)
            try exec(on: writer, "BEGIN IMMEDIATE TRANSACTION;")
            let metaDigest = computeMetaDigest(
                magic: magic,
                schemaVersion: supportedSchemaVersion,
                storeID: storeID,
                domain: domain,
                capabilitiesBytes: capsBytes,
                logicalSequence: 0,
                nextRecordSequence: 1,
                layoutGeneration: 0,
                auditHighWater: 0
            )
            try withPrepared(
                on: writer,
                sql: """
                INSERT INTO store_meta (
                    singleton, magic, schema_version, store_id, domain, capabilities_json,
                    logical_sequence, next_record_sequence, layout_generation, audit_high_water, digest
                ) VALUES (1, ?, ?, ?, ?, ?, 0, 1, 0, 0, ?);
                """
            ) { stmt in
                bindText(stmt, 1, magic)
                sqlite3_bind_int64(stmt, 2, Int64(supportedSchemaVersion))
                bindText(stmt, 3, storeID.uuidString)
                bindText(stmt, 4, domain)
                bindBlob(stmt, 5, capsBytes)
                bindText(stmt, 6, metaDigest)
                try stepDone(stmt, on: writer)
            }
            try exec(on: writer, "COMMIT;")
            let reader = try openConnection(at: dbURL, readOnly: true, durability: durability)
            return AgentJournalSQLiteStore(
                directoryURL: directory,
                storeID: storeID,
                operationDomain: domain,
                capabilities: caps,
                writerDB: writer,
                readerDB: reader,
                writerLock: writerLock,
                fault: fault
            )
        } catch {
            sqlite3_close_v2(writer)
            try? writerLock.close()
            throw error
        }
    }

    static func open(
        at url: URL,
        durability: SQLiteJournalDurability,
        lockRetry: (@Sendable () throws -> Void)? = nil,
        fault: (@Sendable (SQLiteJournalFaultStage) throws -> Void)? = nil
    ) throws -> AgentJournalSQLiteStore {
        let directory = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw AgentJournalError.persistenceUnavailable("store does not exist; call create explicitly")
        }
        guard isDirectory.boolValue else {
            throw AgentJournalError.invalidHeader
        }
        let dbURL = directory.appendingPathComponent("journal.sqlite3")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw AgentJournalError.invalidHeader
        }
        let writerLock = try acquireExclusiveLock(at: directory.appendingPathComponent(writerLockName), retry: lockRetry)
        let writer: OpaquePointer
        do {
            writer = try openConnection(at: dbURL, readOnly: false, durability: durability)
        } catch {
            try? writerLock.close()
            throw error
        }
        do {
            let loaded = try loadStoreIdentityAndCapabilities(on: writer)
            let reader = try openConnection(at: dbURL, readOnly: true, durability: durability)
            return AgentJournalSQLiteStore(
                directoryURL: directory,
                storeID: loaded.storeID,
                operationDomain: loaded.domain,
                capabilities: loaded.capabilities,
                writerDB: writer,
                readerDB: reader,
                writerLock: writerLock,
                fault: fault
            )
        } catch {
            sqlite3_close_v2(writer)
            try? writerLock.close()
            throw error
        }
    }

    static func upgradeForIncompleteContextHandoff(
        at url: URL,
        durability: SQLiteJournalDurability
    ) throws -> AgentJournalSQLiteStore {
        let old = try open(at: url, durability: durability)
        do {
            try old.publishIncompleteContextHandoff()
            try old.close()
        } catch {
            try? old.close()
            throw error
        }
        return try open(at: url, durability: durability)
    }

    private func publishIncompleteContextHandoff() throws {
        guard supportsContextHandoff, !supportsIncompleteContextHandoff else {
            throw AgentJournalError.unsupportedFormat
        }
        let upgraded = CapabilitiesRecord(
            supportsAdmissionRejections: true,
            supportsAuthorizationAudit: true,
            supportsConfirmedNoEffect: true,
            noEffectProofVersion: 2,
            supportsPerCallFollowUps: true,
            supportsRunRecords: true,
            supportsImageContent: true,
            supportsFileContent: true,
            supportsNativeContext: true,
            supportsContextHandoff: true,
            supportsIncompleteContextHandoff: true
        )
        let capsBytes = try Self.canonicalJSON(upgraded)
        try writeLock.withLock {
            guard !closed else { throw AgentJournalError.storeClosed }
            guard !poisoned, let db = writerDB else { throw AgentJournalError.commitUnknown }
            try Self.exec(on: db, "BEGIN IMMEDIATE TRANSACTION;")
            do {
                let meta = try loadMetaState(on: db)
                let digest = Self.computeMetaDigest(
                    magic: Self.magic,
                    schemaVersion: Self.supportedSchemaVersion,
                    storeID: storeID,
                    domain: operationDomain,
                    capabilitiesBytes: capsBytes,
                    logicalSequence: meta.logicalSequence,
                    nextRecordSequence: meta.nextRecordSequence,
                    layoutGeneration: meta.layoutGeneration,
                    auditHighWater: meta.auditHighWater
                )
                try Self.withPrepared(
                    on: db,
                    sql: "UPDATE store_meta SET capabilities_json = ?, digest = ? WHERE singleton = 1;"
                ) { stmt in
                    Self.bindBlob(stmt, 1, capsBytes)
                    Self.bindText(stmt, 2, digest)
                    try Self.stepDone(stmt, on: db)
                }
            } catch {
                try? Self.exec(on: db, "ROLLBACK;")
                throw error
            }
            do {
                try Self.exec(on: db, "COMMIT;")
            } catch {
                // SQLite may or may not have made the change durable; reopen to see which format is current.
                poisoned = true
                throw AgentJournalError.commitUnknown
            }
        }
    }

    package func auditDigest(_ bytes: Data) -> String {
        Self.sha256Hex(bytes)
    }

    package func rotationOverdue() -> Bool { false }

    package func metrics() -> JournalStorageMetrics {
        countersLock.withLock {
            JournalStorageMetrics(
                bytesRead: bytesReadCount,
                decodedBatches: decodedBatchesCount,
                bytesWritten: bytesWrittenCount,
                committedBatches: committedBatchesCount,
                writeLockNanoseconds: writeLockNanosecondsCount,
                maintenanceNanoseconds: maintenanceNanosecondsCount,
                encodedBatches: encodedBatchesCount
            )
        }
    }

    package func status() throws -> JournalStoreStatus {
        try readLocked { db in
            let meta = try loadMetaState(on: db)
            let walBytes = currentWALBytes()
            // Only a WAL that grew a full threshold beyond what the last maintenance left behind is work:
            // a merely non-empty WAL (or one a reader kept from shrinking) cannot be relieved by maintaining again.
            // A WAL that has since shrunk lowers the baseline, so the next growth is measured from there.
            let baseline = countersLock.withLock {
                walBytesAfterMaintenance = min(walBytesAfterMaintenance, walBytes)
                return walBytesAfterMaintenance
            }
            let needsMaintenance = walBytes >= Self.walMaintenanceThresholdBytes &&
                walBytes - baseline >= Self.walMaintenanceThresholdBytes
            return JournalStoreStatus(
                identity: JournalStoreIdentity(storeID: storeID, operationDomain: operationDomain),
                logicalSequence: meta.logicalSequence,
                layoutGeneration: meta.layoutGeneration,
                activeSegmentBytes: walBytes,
                sealedSegments: needsMaintenance ? 1 : 0,
                pendingGarbageSegments: 0,
                pendingGarbagePacks: 0
            )
        }
    }

    package func maintenanceStatus() throws -> JournalMaintenanceStatus {
        let current = try status()
        return JournalMaintenanceStatus(sealedSegments: 0, reclaimedBytes: 0, lastError: nil)
            .withSealed(current.sealedSegments > 0 ? 0 : 0)
    }

    package func maintain() async throws -> JournalMaintenanceStatus {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            countersLock.withLock {
                maintenanceNanosecondsCount += elapsed
                maintenanceRunCount += 1
            }
        }
        try writeLock.withLock {
            guard !closed else { throw AgentJournalError.storeClosed }
            guard !poisoned else { throw AgentJournalError.commitUnknown }
        }
        // Snapshot boundary happens outside writeLock so foreground commits and reads can interleave.
        try fault?(.duringMaintenanceSnapshot)
        try Task.checkCancellation()
        return try writeLock.withLock {
            guard !closed else { throw AgentJournalError.storeClosed }
            guard !poisoned, let writer = writerDB else { throw AgentJournalError.commitUnknown }
            let beforeBytes = currentWALBytes()
            // Meta first, so the checkpoint below also covers this write and leaves nothing behind in the WAL.
            try Self.exec(on: writer, "BEGIN IMMEDIATE TRANSACTION;")
            do {
                var meta = try loadMetaState(on: writer)
                meta.layoutGeneration += 1
                try saveMetaState(meta, on: writer)
                try Self.exec(on: writer, "COMMIT;")
            } catch {
                try? Self.exec(on: writer, "ROLLBACK;")
                throw error
            }
            // TRUNCATE resets the WAL file to zero bytes when no reader holds it. Do not wait for readers while
            // holding writeLock: with no busy handler SQLite checkpoints what it can and returns BUSY.
            sqlite3_busy_timeout(writer, 0)
            let rc = sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            sqlite3_busy_timeout(writer, Self.busyTimeoutMilliseconds)
            if rc != SQLITE_OK && rc != SQLITE_BUSY && rc != SQLITE_LOCKED {
                throw Self.sqliteError(on: writer, context: "wal_checkpoint")
            }
            let afterBytes = currentWALBytes()
            countersLock.withLock { walBytesAfterMaintenance = afterBytes }
            let reclaimed = beforeBytes > afterBytes ? beforeBytes - afterBytes : 0
            return JournalMaintenanceStatus(sealedSegments: 0, reclaimedBytes: reclaimed, lastError: nil)
        }
    }

    package func close() throws {
        writeLock.lock()
        readLock.lock()
        defer {
            readLock.unlock()
            writeLock.unlock()
        }
        if closed { return }
        closed = true
        if let db = readerDB {
            sqlite3_close_v2(db)
            readerDB = nil
        }
        if let db = writerDB {
            if !poisoned {
                _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            }
            sqlite3_close_v2(db)
            writerDB = nil
        }
        if let writerLock {
            self.writerLock = nil
            try? writerLock.close()
        }
    }

    package func read<T>(_ body: (any JournalStoreView) throws -> T) throws -> T {
        try readLocked { db in
            let view = View(store: self, db: db, writable: false)
            return try body(view)
        }
    }

    package func write<T>(_ body: (any JournalStoreView) throws -> T) throws -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        writeLock.lock()
        defer {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            countersLock.withLock { writeLockNanosecondsCount += elapsed }
            writeLock.unlock()
        }
        guard !closed else { throw AgentJournalError.storeClosed }
        guard !poisoned, let db = writerDB else { throw AgentJournalError.commitUnknown }

        try Self.exec(on: db, "BEGIN IMMEDIATE TRANSACTION;")
        var committed = false
        do {
            let view = View(store: self, db: db, writable: true)
            let result = try body(view)
            if view.didPublish {
                try fault?(.beforeCommit)
                try Self.exec(on: db, "COMMIT;")
                committed = true
                countersLock.withLock {
                    committedBatchesCount += 1
                    bytesWrittenCount += view.writtenBytes
                    encodedBatchesCount += 1
                }
                do {
                    try fault?(.afterCommit)
                } catch {
                    poisoned = true
                    throw AgentJournalError.commitUnknown
                }
            } else {
                try Self.exec(on: db, "ROLLBACK;")
            }
            return result
        } catch {
            if !committed {
                try? Self.exec(on: db, "ROLLBACK;")
            } else {
                poisoned = true
                throw AgentJournalError.commitUnknown
            }
            if poisoned { throw AgentJournalError.commitUnknown }
            throw error
        }
    }

    private func readLocked<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        // Check poisoned/closed status without blocking concurrent maintenance snapshot pauses.
        if poisoned { throw AgentJournalError.commitUnknown }
        readLock.lock()
        defer { readLock.unlock() }
        guard !closed else { throw AgentJournalError.storeClosed }
        guard !poisoned, let db = readerDB else { throw AgentJournalError.commitUnknown }
        return try body(db)
    }
}

private extension JournalMaintenanceStatus {
    func withSealed(_ count: Int) -> JournalMaintenanceStatus {
        JournalMaintenanceStatus(sealedSegments: count, reclaimedBytes: reclaimedBytes, lastError: lastError)
    }
}
