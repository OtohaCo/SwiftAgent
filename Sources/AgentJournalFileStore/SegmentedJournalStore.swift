import AgentCore
import AgentModels
import AgentTools
import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct JournalMaintenancePolicy: Sendable {
    public let segmentBytes: Int
    public let maxWorkBytes: Int
    public let maxUnreclaimedBytes: Int
    public let maxSegmentBatches: Int

    /// `maxWorkBytes` must cover the largest segment rotation can seal; see `minimumWorkBytes`.
    public init(segmentBytes: Int = 2 * 1024 * 1024,
                maxWorkBytes: Int = 4 * 1024 * 1024,
                maxUnreclaimedBytes: Int = 64 * 1024 * 1024,
                maxSegmentBatches: Int = 128) throws {
        guard segmentBytes >= 1024, let minimumWorkBytes = try Self.minimumWorkBytes(segmentBytes: segmentBytes),
              maxWorkBytes >= minimumWorkBytes,
              maxUnreclaimedBytes >= maxWorkBytes, (1...1024).contains(maxSegmentBatches) else {
            throw AgentJournalError.invalidRecord
        }
        self.segmentBytes = segmentBytes
        self.maxWorkBytes = maxWorkBytes
        self.maxUnreclaimedBytes = maxUnreclaimedBytes
        self.maxSegmentBatches = maxSegmentBatches
    }

    public static let `default` = try! JournalMaintenancePolicy()

    /// A segment rotates after the append that reaches `segmentBytes`, so it can end one largest
    /// inline frame past it. Maintenance reads a whole sealed segment within `maxWorkBytes`.
    /// Returns nil when the sum does not fit in `Int`.
    static func minimumWorkBytes(segmentBytes: Int) throws -> Int? {
        let (minimum, overflow) = (segmentBytes - 1)
            .addingReportingOverflow(try SegmentedJournalStore.largestInlineFrameBytes(segmentBytes: segmentBytes))
        return overflow ? nil : minimum
    }
}

package enum JournalFileFaultStage: Sendable {
    case beforeAppend
    case partialAppend
    case beforeAppendSync
    case afterAppendSync
    case beforeManagedWrite
    case beforeManagedSync
    case afterIndexSync
    case beforeCurrentReplace
    case afterCurrentReplace
    case beforeRotation
    case beforeMaintenancePublish
    case afterMaintenanceSnapshot
    case beforeSegmentDelete
    case beforePackDelete
    case beforeClose
    case beforeSessionRead
}

/// Default fail-fast ownership, or an explicit finite absolute lock-wait deadline.
public enum JournalWriterLockWait: Sendable {
    case failFast
    case until(ContinuousClock.Instant)
}

package enum JournalOpeningStage: Sendable { case formatValidated, lockContended, lockAcquired }

public enum AgentIncrementalJournal {
    private static let openingQueue = DispatchQueue(label: "SwiftAgent.JournalFileStore.open",
                                                     qos: .utility, attributes: .concurrent)

    fileprivate static func normalized(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? AgentJournalError { return error }
        if let error = error as? AgentAuthorizationError { return error }
        if let error = error as? AgentFollowUpError { return error }
        if error is DecodingError { return AgentJournalError.invalidRecord }
        return AgentJournalError.persistenceUnavailable(error.localizedDescription)
    }

    /// Use from UI and actor callers. A cancellation request after I/O starts
    /// still waits for the owned file operation to finish before returning.
    public static func createAsync(at directory: URL, operationDomain: String,
                                   policy: JournalMaintenancePolicy = .default,
                                   supportsAdmissionRejections: Bool = false,
                       supportsAuthorizationAudit: Bool = false,
                       supportsConfirmedNoEffect: Bool = false,
                                   deadline: ContinuousClock.Instant? = nil) async throws -> AgentJournal {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw AgentJournalError.deadlineExceeded }
        let journal = try await openOwned(deadline: deadline) { _ in
            try SegmentedJournalStore.create(at: directory, domain: operationDomain, policy: policy,
                                             supportsAdmissionRejections: supportsAdmissionRejections, supportsAuthorizationAudit: supportsAuthorizationAudit, supportsConfirmedNoEffect: supportsConfirmedNoEffect)
        }
        try Task.checkCancellation()
        return journal
    }

    /// The existing asynchronous fail-fast API, including its function signature.
    public static func openAsync(at directory: URL,
                                 policy: JournalMaintenancePolicy = .default,
                                 deadline: ContinuousClock.Instant? = nil) async throws -> AgentJournal {
        try await openAsync(at: directory, policy: policy, writerLockWait: .failFast, deadline: deadline)
    }

    /// Optional waiting applies only to writer-lock contention. Other opening
    /// work is attempted once. The finite deadline is never reset by a retry.
    public static func openAsync(at directory: URL,
                                 policy: JournalMaintenancePolicy = .default,
                                 writerLockWait: JournalWriterLockWait,
                                 deadline: ContinuousClock.Instant? = nil) async throws -> AgentJournal {
        try await openAsyncOwned(at: directory, policy: policy, writerLockWait: writerLockWait,
                                 deadline: deadline, observer: nil)
    }

    package static func openAsyncForTesting(at directory: URL,
                                            writerLockWait: JournalWriterLockWait,
                                            deadline: ContinuousClock.Instant? = nil,
                                            observer: @escaping @Sendable (JournalOpeningStage) -> Void) async throws -> AgentJournal {
        try await openAsyncOwned(at: directory, policy: .default, writerLockWait: writerLockWait,
                                 deadline: deadline, observer: observer)
    }

    private static func openAsyncOwned(at directory: URL, policy: JournalMaintenancePolicy,
                                        writerLockWait: JournalWriterLockWait,
                                        deadline: ContinuousClock.Instant?,
                                        observer: (@Sendable (JournalOpeningStage) -> Void)?) async throws -> AgentJournal {
        try Task.checkCancellation()
        let effectiveDeadline: ContinuousClock.Instant?
        switch writerLockWait {
        case .failFast: effectiveDeadline = deadline
        case .until(let end): effectiveDeadline = deadline.map { min($0, end) } ?? end
        }
        if let effectiveDeadline, ContinuousClock.now >= effectiveDeadline { throw AgentJournalError.deadlineExceeded }
        let journal = try await openOwned(deadline: effectiveDeadline) { cancellation in
            let wait: (@Sendable () throws -> Void)?
            switch writerLockWait {
            case .failFast: wait = nil
            case .until: wait = { try cancellation.waitForLockRetry(until: effectiveDeadline!) }
            }
            return try SegmentedJournalStore.open(at: directory, policy: policy, lockRetry: wait, observer: observer)
        }
        if Task.isCancelled || (effectiveDeadline.map { ContinuousClock.now >= $0 } ?? false) {
            try await journal.close()
            if Task.isCancelled { throw CancellationError() }
            throw AgentJournalError.deadlineExceeded
        }
        return journal
    }

    private static func openOwned(deadline: ContinuousClock.Instant?,
                                  operation: @escaping @Sendable (OpeningCancellation) throws -> SegmentedJournalStore) async throws -> AgentJournal {
        let cancellation = OpeningCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                openingQueue.async {
                    do {
                        if cancellation.isCancelled { throw CancellationError() }
                        if let deadline, ContinuousClock.now >= deadline { throw AgentJournalError.deadlineExceeded }
                        let store = try operation(cancellation)
                        if cancellation.isCancelled || (deadline.map { ContinuousClock.now >= $0 } ?? false) {
                            try store.close()
                            if cancellation.isCancelled { throw CancellationError() }
                            throw AgentJournalError.deadlineExceeded
                        }
                        continuation.resume(returning: AgentJournal(store: store))
                    } catch { continuation.resume(throwing: normalized(error)) }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    public static func create(at directory: URL, operationDomain: String,
                              policy: JournalMaintenancePolicy = .default,
                              supportsAdmissionRejections: Bool = false,
                              supportsAuthorizationAudit: Bool = false,
                              supportsConfirmedNoEffect: Bool = false) throws -> AgentJournal {
        do {
            return AgentJournal(store: try SegmentedJournalStore.create(at: directory, domain: operationDomain,
                policy: policy, supportsAdmissionRejections: supportsAdmissionRejections, supportsAuthorizationAudit: supportsAuthorizationAudit, supportsConfirmedNoEffect: supportsConfirmedNoEffect))
        } catch { throw normalized(error) }
    }

    public static func open(at directory: URL,
                            policy: JournalMaintenancePolicy = .default) throws -> AgentJournal {
        do { return AgentJournal(store: try SegmentedJournalStore.open(at: directory, policy: policy)) }
        catch { throw normalized(error) }
    }

    package static func createForTesting(at directory: URL, operationDomain: String,
                                         policy: JournalMaintenancePolicy = .default,
                                         supportsAdmissionRejections: Bool = false,
                                         supportsAuthorizationAudit: Bool = false,
                                         supportsConfirmedNoEffect: Bool = false,
                                         fault: @escaping @Sendable (JournalFileFaultStage) throws -> Void) throws -> AgentJournal {
        AgentJournal(store: try SegmentedJournalStore.create(at: directory, domain: operationDomain,
                                                              policy: policy,
                                                              supportsAdmissionRejections: supportsAdmissionRejections,
                                                              supportsAuthorizationAudit: supportsAuthorizationAudit,
                                                              supportsConfirmedNoEffect: supportsConfirmedNoEffect,
                                                              fault: fault))
    }
}

private final class OpeningCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let wake = DispatchSemaphore(value: 0)
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        wake.signal()
    }
    func waitForLockRetry(until deadline: ContinuousClock.Instant) throws {
        if isCancelled { throw CancellationError() }
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw AgentJournalError.deadlineExceeded }
        // Dedicated owned utility-queue I/O; never block a Swift cooperative
        // thread. DispatchTime is monotonic and cancellation wakes this wait.
        let retry = min(remaining, .milliseconds(25))
        let parts = retry.components
        let nanoseconds = Int(parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000)
        _ = wake.wait(timeout: .now() + .nanoseconds(nanoseconds))
        if isCancelled { throw CancellationError() }
        if ContinuousClock.now >= deadline { throw AgentJournalError.deadlineExceeded }
    }
}

private struct Format: Codable {
    let magic: String
    let schema: Int
    let storeID: UUID
    let domain: String
}

private struct Location: Codable {
    let kind: String
    let file: UUID
    let offset: UInt64
    let length: UInt32
    let generation: UInt64
    let commitID: UUID?

    init(kind: String, file: UUID, offset: UInt64, length: UInt32,
         generation: UInt64, commitID: UUID? = nil) {
        self.kind = kind; self.file = file; self.offset = offset
        self.length = length; self.generation = generation; self.commitID = commitID
    }
}

private struct IndexWitness: Codable {
    let kind: String
    let keyDigest: String
    let firstSequence: UInt64
    let commitID: UUID
}

private struct Slot<Value: Codable>: Codable {
    let key: String
    let version: UInt64
    let value: Value
}

private struct Index<Value: Codable>: Codable {
    let current: Slot<Value>
    let previous: Slot<Value>?
}

private struct IndexEnvelope: Codable {
    let storeID: UUID
    let digest: String
    let payload: Data
}

private struct MessagePointer: Codable {
    let sequence: UInt64
    let offset: Int
}

/// One family of on-disk indexes: its directory, the value its slots hold, and whether a witness
/// guards its first publication. Reads, writes and cleanup name a kind rather than a string, so a
/// slot is always decoded as the value its writer stored.
private struct IndexKind<Value: Codable> {
    let name: String
    let witnessed: Bool
    /// Only stores created with admission-rejection support (format schema 4) have this index.
    let requiresAdmissionRejections: Bool
    let requiresAuthorizationAudit: Bool

    init(_ name: String, witnessed: Bool = false, requiresAdmissionRejections: Bool = false, requiresAuthorizationAudit: Bool = false) {
        self.name = name
        self.witnessed = witnessed
        self.requiresAdmissionRejections = requiresAdmissionRejections
        self.requiresAuthorizationAudit = requiresAuthorizationAudit
    }

    func isPublished(_ slot: Slot<Value>, in root: Root) -> Bool {
        slot.version <= root.sequence && Self.generation(of: slot.value) <= root.layoutGeneration
    }

    /// A position records the layout generation it was written for; other values hold in every layout.
    static func generation(of value: Value) -> UInt64 { (value as? Location)?.generation ?? 0 }
}

/// Most UInt64 indexes point to the Journal batch holding their current value.
/// auditMembers instead maps a group ordinal to a global audit-record sequence.
extension IndexKind where Value == UInt64 {
    static var sessions: Self { .init("sessions", witnessed: true) }
    static var operations: Self { .init("operations", witnessed: true) }
    static var calls: Self { .init("calls") }
    static var blobIndex: Self { .init("blob-index") }
    static var queueHeads: Self { .init("queue-heads", witnessed: true) }
    static var queueIDs: Self { .init("queue-ids", witnessed: true) }
    static var queueOrder: Self { .init("queue-order") }
    static var queueLinks: Self { .init("queue-links") }
    /// Ordinal -> audit sequence, retained with its group and typed facts; not a batch pointer.
    static var auditMembers: Self { .init("audit-members", requiresAuthorizationAudit: true) }
    /// Latest checkpoint batch sequence; keeps that checkpoint batch live.
    static var auditExports: Self { .init("audit-exports", witnessed: true, requiresAuthorizationAudit: true) }
    static var rejections: Self { .init("rejections", witnessed: true, requiresAdmissionRejections: true) }
}

extension IndexKind where Value == AuditRecordPointer {
    static var auditRecords: Self { .init("audit-records", witnessed: true, requiresAuthorizationAudit: true) }
}

extension IndexKind where Value == AuditIndexSummary {
    static var auditGroups: Self { .init("audit-groups", witnessed: true, requiresAuthorizationAudit: true) }
}

extension IndexKind where Value == MessagePointer {
    static var messages: Self { .init("messages") }
}

extension IndexKind where Value == Location {
    static var positions: Self { .init("positions") }
}

extension IndexKind where Value == [UUID] {
    /// The Sessions whose mutation for one logical operation is unresolved. The set is the whole
    /// value; it names no batch, so it keeps no batch alive during maintenance.
    static var pendingOperations: Self {
        .init("pending-operations", witnessed: true, requiresAdmissionRejections: true)
    }
}

/// A kind's publication metadata, for code that walks every index file.
private struct AnyIndexKind {
    let name: String
    let requiresAdmissionRejections: Bool
    let requiresAuthorizationAudit: Bool
    /// Decodes an index payload as this kind's value and returns its slots, current first.
    let slots: (Data) throws -> [(key: String, version: UInt64, generation: UInt64)]

    init<Value>(_ kind: IndexKind<Value>) {
        name = kind.name
        requiresAdmissionRejections = kind.requiresAdmissionRejections
        requiresAuthorizationAudit = kind.requiresAuthorizationAudit
        slots = { payload in
            let index = try JSONDecoder().decode(Index<Value>.self, from: payload)
            return [index.current, index.previous].compactMap { $0 }.map {
                (key: $0.key, version: $0.version, generation: IndexKind<Value>.generation(of: $0.value))
            }
        }
    }

    static func all(supportsAdmissionRejections: Bool, supportsAuthorizationAudit: Bool = false, supportsConfirmedNoEffect: Bool = false) -> [AnyIndexKind] {
        [
            .init(IndexKind<UInt64>.sessions), .init(IndexKind<UInt64>.operations), .init(IndexKind<UInt64>("calls", witnessed: supportsConfirmedNoEffect)),
            .init(IndexKind<MessagePointer>.messages), .init(IndexKind<Location>.positions),
            .init(IndexKind<UInt64>.blobIndex), .init(IndexKind<UInt64>.queueHeads),
            .init(IndexKind<UInt64>.queueIDs), .init(IndexKind<UInt64>.queueOrder),
            .init(IndexKind<UInt64>.queueLinks), .init(IndexKind<UInt64>.rejections),
            .init(IndexKind<[UUID]>.pendingOperations),
            .init(IndexKind<AuditRecordPointer>.auditRecords), .init(IndexKind<AuditIndexSummary>.auditGroups),
            .init(IndexKind<UInt64>.auditMembers), .init(IndexKind<UInt64>.auditExports),
        ].filter { (supportsAdmissionRejections || !$0.requiresAdmissionRejections)
            && (supportsAuthorizationAudit || !$0.requiresAuthorizationAudit) }
    }
}

private struct Segment: Codable {
    let id: UUID
    let end: UInt64
    let garbageBlobs: [GarbageBlob]

    init(id: UUID, end: UInt64, garbageBlobs: [GarbageBlob] = []) {
        self.id = id
        self.end = end
        self.garbageBlobs = garbageBlobs
    }
}

private struct GarbageBlob: Codable {
    let sequence: UInt64
    let id: UUID
}

private struct GarbagePack: Codable {
    let id: UUID
    let blobs: [GarbageBlob]
}

private struct Layout: Codable {
    let generation: UInt64
    let sealed: [Segment]
    let packs: [UUID]
    let garbage: [Segment]
    let garbagePacks: [GarbagePack]
}

private struct Root: Codable {
    let storeID: UUID
    let formatDigest: String
    let sequence: UInt64
    let nextRecordSequence: UInt64
    let active: UUID
    let activeEnd: UInt64
    let activeBatches: Int
    let layout: UUID
    let layoutDigest: String
    let layoutGeneration: UInt64
    let lastFrame: Location?
    let lastDigest: String?
    var auditRecordCount: UInt64? = nil
}

private struct Current: Codable, Equatable {
    let root: UUID
    let digest: String
}

// Format schema 3 keeps the bounded BatchV2 payload and adds index witnesses
// plus stable position commit IDs. Schema 4 reserves the optional rejection
// payload and operation-pending index; RC4 readers reject format.json.
private struct BatchV2: Codable {
    let schema: Int
    let commitID: UUID
    let sequence: UInt64
    let sessionID: UUID
    let header: DiskHeaderV1?
    let messageStart: UInt64
    let messages: [DiskMessageV1]
    let mutation: DiskMutationV1?
    let admissionRejection: DiskAdmissionRejectionV1?
    let queueHead: DiskFollowUpHeadV2?
    let queueChanges: [DiskFollowUpV2]
    let queueLinks: [DiskFollowUpLinkV2]
    let recordCount: UInt32
    var auditRecords: [DiskAuditRecordV1]? = nil
    var auditCheckpoint: JournalAuditExportCheckpoint? = nil
}

private struct DiskAdmissionRejectionV1: Codable {
    let runID: UUID
    let callID: String
    let toolName: String

    init(_ value: JournalAdmissionRejection) {
        runID = value.runID
        callID = value.callID.rawValue
        toolName = value.toolName
    }

    func value(sessionID: UUID) throws -> JournalAdmissionRejection {
        guard !callID.isEmpty, !toolName.isEmpty else { throw AgentJournalError.invalidRecord }
        return .init(sessionID: sessionID, runID: runID,
                     callID: .init(rawValue: callID), toolName: toolName)
    }
}

private struct Frame: Codable {
    let digest: String
    let payload: Data?
    let blob: UUID?
}

private final class MetricsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var read: UInt64 = 0
    private var decoded: UInt64 = 0
    private var written: UInt64 = 0
    private var committed: UInt64 = 0
    private var encoded: UInt64 = 0
    private var writeLock: UInt64 = 0
    private var maintenance: UInt64 = 0

    func add(read bytes: Int = 0, decoded batches: Int = 0, written output: Int = 0,
             committed publications: Int = 0, writeLockNanoseconds: UInt64 = 0,
             maintenanceNanoseconds: UInt64 = 0, encodedBatches: UInt64 = 0) {
        lock.lock()
        read += UInt64(bytes)
        decoded += UInt64(batches)
        written += UInt64(output)
        committed += UInt64(publications)
        writeLock += writeLockNanoseconds
        maintenance += maintenanceNanoseconds
        encoded += encodedBatches
        lock.unlock()
    }

    func snapshot() -> JournalStorageMetrics {
        lock.lock()
        defer { lock.unlock() }
        return JournalStorageMetrics(bytesRead: read, decodedBatches: decoded,
                                     bytesWritten: written, committedBatches: committed,
                                     writeLockNanoseconds: writeLock,
                                     maintenanceNanoseconds: maintenance, encodedBatches: encoded)
    }
}

private final class SegmentedJournalStore: JournalStore, @unchecked Sendable {
    let directoryURL: URL
    let storeID: UUID
    let operationDomain: String
    let supportsAdmissionRejections: Bool
    let supportsConfirmedNoEffect: Bool
    private var callsIndex: IndexKind<UInt64> { .init("calls", witnessed: supportsConfirmedNoEffect) }
    let supportsAuthorizationAudit: Bool
    private let policy: JournalMaintenancePolicy
    private let lock = NSLock()
    private var descriptor: Int32
    private var closed = false
    private var poisoned = false
    private var expectedCurrent: Current?
    private let expectedFormatDigest: String
    private var reclaimed: UInt64 = 0
    private var lastMaintenanceError: String?
    private let counters = MetricsBox()
    private let maintenanceQueue = DispatchQueue(label: "SwiftAgent.JournalFileStore.maintenance", qos: .utility)
    private let fault: (@Sendable (JournalFileFaultStage) throws -> Void)?
    private var garbageShard = 0
    private var garbageIndexShard = 0
    private var packCursor = 0
    private var garbageEnumerators: [String: FileManager.DirectoryEnumerator] = [:]
    private var finishedIndexKinds: Set<String> = []

    private init(directoryURL: URL, format: Format, descriptor: Int32,
                 formatDigest: String,
                 policy: JournalMaintenancePolicy,
                 fault: (@Sendable (JournalFileFaultStage) throws -> Void)? = nil) {
        self.directoryURL = directoryURL
        storeID = format.storeID
        operationDomain = format.domain
        supportsAdmissionRejections = format.schema >= 4
        supportsAuthorizationAudit = format.schema >= 5
        supportsConfirmedNoEffect = format.schema == 6
        expectedFormatDigest = formatDigest
        self.descriptor = descriptor
        self.policy = policy
        self.fault = fault
    }

    deinit { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); _ = DarwinOrGlibcClose(descriptor) } }

    static func create(at url: URL, domain: String, policy: JournalMaintenancePolicy,
                       supportsAdmissionRejections: Bool = false,
                       supportsAuthorizationAudit: Bool = false,
                       supportsConfirmedNoEffect: Bool = false,
                       fault: (@Sendable (JournalFileFaultStage) throws -> Void)? = nil) throws -> SegmentedJournalStore {
        let supportsAuthorizationAudit = supportsAuthorizationAudit || supportsConfirmedNoEffect
        guard !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentJournalError.invalidRecord
        }
        let directory = canonical(url)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw AgentJournalError.persistenceUnavailable("create requires a new directory")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in Self.managedDirectories(supportsAdmissionRejections: supportsAdmissionRejections || supportsAuthorizationAudit, supportsAuthorizationAudit: supportsAuthorizationAudit, supportsConfirmedNoEffect: supportsConfirmedNoEffect) {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        let descriptor = try lockStore(directory)
        let format = Format(magic: "SWIFTAGENT-SEGMENTED-JOURNAL", schema: supportsConfirmedNoEffect ? 6 : supportsAuthorizationAudit ? 5 : (supportsAdmissionRejections ? 4 : 3),
                            storeID: UUID(), domain: domain)
        let formatBytes = try JSONEncoder().encode(format)
        let store = SegmentedJournalStore(directoryURL: directory, format: format,
                                          descriptor: descriptor, formatDigest: Self.digest(formatBytes),
                                          policy: policy, fault: fault)
        do {
            try store.validateManagedDirectories()
            try store.writeNew(formatBytes, at: directory.appendingPathComponent("format.json"))
            let segment = UUID(), layoutID = UUID(), rootID = UUID()
            try store.writeNew(Data(), at: store.segmentURL(segment))
            let layoutBytes = try JSONEncoder().encode(Layout(generation: 0, sealed: [], packs: [],
                                                              garbage: [], garbagePacks: []))
            try store.writeNew(layoutBytes, at: store.layoutURL(layoutID))
            let root = Root(storeID: format.storeID, formatDigest: Self.digest(formatBytes),
                            sequence: 0, nextRecordSequence: 1,
                            active: segment, activeEnd: 0, activeBatches: 0, layout: layoutID,
                            layoutDigest: Self.digest(layoutBytes), layoutGeneration: 0,
                            lastFrame: nil, lastDigest: nil, auditRecordCount: supportsAuthorizationAudit ? 0 : nil)
            try store.publishRoot(root, id: rootID)
            try Self.syncParentDirectory(of: directory)
            return store
        } catch {
            try? store.close()
            throw error
        }
    }

    static func open(at url: URL, policy: JournalMaintenancePolicy,
                     lockRetry: (@Sendable () throws -> Void)? = nil,
                     observer: (@Sendable (JournalOpeningStage) -> Void)? = nil) throws -> SegmentedJournalStore {
        let directory = canonical(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw AgentJournalError.persistenceUnavailable("store does not exist; call create explicitly")
        }
        guard isDirectory.boolValue else {
            let prefix = try Data(contentsOf: directory).prefix(20)
            if prefix == Data("SWIFTAGENT-JOURNAL-1".utf8) {
                throw AgentJournalError.unsupportedLegacyFormat
            }
            throw AgentJournalError.invalidHeader
        }
        let formatURL = directory.appendingPathComponent("format.json")
        guard FileManager.default.fileExists(atPath: formatURL.path) else {
            throw AgentJournalError.invalidHeader
        }
        let format: Format
        let formatBytes: Data
        do {
            let fd = DarwinOrGlibcOpen(formatURL.path, O_RDONLY | O_NOFOLLOW, 0)
            guard fd >= 0 else { throw AgentJournalError.invalidHeader }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw AgentJournalError.invalidHeader
            }
            formatBytes = try handle.readToEnd() ?? Data()
            format = try JSONDecoder().decode(Format.self, from: formatBytes)
        } catch is DecodingError {
            throw AgentJournalError.invalidHeader
        } catch {
            throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }
        guard format.magic == "SWIFTAGENT-SEGMENTED-JOURNAL", !format.domain.isEmpty else {
            throw AgentJournalError.invalidHeader
        }
        guard format.schema == 3 || format.schema == 4 || format.schema == 5 || format.schema == 6 else { throw AgentJournalError.unsupportedFormat }
        observer?(.formatValidated)
        let descriptor = try lockStore(directory, retry: lockRetry, observer: observer)
        let store = SegmentedJournalStore(directoryURL: directory, format: format,
                                          descriptor: descriptor, formatDigest: Self.digest(formatBytes),
                                          policy: policy)
        do {
            try store.validateManagedDirectories()
            let (root, _) = try store.currentRoot()
            try store.requireWorkBudget(root: root, layout: try store.layout(root))
            if let location = root.lastFrame {
                let batch = try store.load(location)
                guard batch.sequence == root.sequence,
                      try store.frameDigest(location) == root.lastDigest else { throw AgentJournalError.invalidRecord }
            }
            let activeURL = store.segmentURL(root.active)
            let activeHandle = try store.openRegularFile(activeURL)
            try activeHandle.close()
            let size = try Self.fileSize(activeURL)
            guard size >= root.activeEnd else { throw AgentJournalError.invalidFrame }
            // The exclusive owner can remove only bytes beyond the committed
            // root. A complete but unpublished tail was never admitted.
            if size > root.activeEnd { try Self.truncate(activeURL, to: root.activeEnd) }
            return store
        } catch {
            try? store.close()
            if let error = error as? AgentJournalError { throw error }
            if let error = error as? AgentAuthorizationError { throw error }
            if error is DecodingError { throw AgentJournalError.invalidRecord }
            throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The lock lives exactly as long as this handle's descriptor. O_CLOEXEC keeps a child the Host
    /// spawns (posix_spawn, fork/exec) from inheriting it and holding the store after close.
    private static func lockStore(_ directory: URL,
                                  retry: (@Sendable () throws -> Void)? = nil,
                                  observer: (@Sendable (JournalOpeningStage) -> Void)? = nil) throws -> Int32 {
        let path = directory.appendingPathComponent(".writer.lock").path
        let fd = DarwinOrGlibcOpen(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ioError("open writer lock") }
        do {
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                guard code == EWOULDBLOCK || code == EAGAIN else { throw ioError("acquire writer lock") }
                observer?(.lockContended)
                guard let retry else { throw AgentJournalError.storeInUse }
                try retry()
            }
            observer?(.lockAcquired)
            return fd
        } catch {
            _ = DarwinOrGlibcClose(fd)
            throw error
        }
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        // Closing relinquishes ownership only; it does not interpret, repair,
        // publish or roll back an uncertain transaction. Keep the handle
        // poisoned until a new owner validates CURRENT on reopen.
        try fault?(.beforeClose)
        let fd = descriptor
        guard DarwinOrGlibcClose(fd) == 0 else { throw Self.ioError("close writer lock") }
        descriptor = -1
        closed = true
    }

    func read<T>(_ body: (any JournalStoreView) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw AgentJournalError.storeClosed }
        guard !poisoned else { throw AgentJournalError.commitUnknown }
        do {
            let (root, _) = try currentRoot()
            return try body(View(store: self, root: root, writable: false))
        } catch {
            if poisoned { throw AgentJournalError.commitUnknown }
            if let error = error as? AgentJournalError { throw error }
            if let error = error as? AgentAuthorizationError { throw error }
            if let error = error as? AgentFollowUpError { throw error }
            if let error = error as? JournalFollowUpAdmissionError { throw error }
            if error is DecodingError { throw AgentJournalError.invalidRecord }
            throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }
    }

    func write<T>(_ body: (any JournalStoreView) throws -> T) throws -> T {
        let began = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer {
            counters.add(writeLockNanoseconds: DispatchTime.now().uptimeNanoseconds - began)
            lock.unlock()
        }
        guard !closed else { throw AgentJournalError.storeClosed }
        guard !poisoned else { throw AgentJournalError.commitUnknown }
        do {
            let (root, _) = try currentRoot()
            return try body(View(store: self, root: root, writable: true))
        } catch {
            if poisoned { throw AgentJournalError.commitUnknown }
            if let error = error as? AgentJournalError { throw error }
            if let error = error as? AgentAuthorizationError { throw error }
            if let error = error as? AgentFollowUpError { throw error }
            if let error = error as? JournalFollowUpAdmissionError { throw error }
            if error is DecodingError { throw AgentJournalError.invalidRecord }
            throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }
    }

    func maintenanceStatus() throws -> JournalMaintenanceStatus {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw AgentJournalError.storeClosed }
        guard !poisoned else { throw AgentJournalError.commitUnknown }
        do {
            let (root, _) = try currentRoot()
            return JournalMaintenanceStatus(sealedSegments: try layout(root).sealed.count,
                                            reclaimedBytes: reclaimed, lastError: lastMaintenanceError)
        } catch { throw AgentIncrementalJournal.normalized(error) }
    }

    func status() throws -> JournalStoreStatus {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw AgentJournalError.storeClosed }
        guard !poisoned else { throw AgentJournalError.commitUnknown }
        do {
            let (root, _) = try currentRoot()
            let current = try layout(root)
            return JournalStoreStatus(
                identity: .init(storeID: storeID, operationDomain: operationDomain),
                logicalSequence: root.sequence, layoutGeneration: root.layoutGeneration,
                activeSegmentBytes: root.activeEnd, sealedSegments: current.sealed.count,
                pendingGarbageSegments: current.garbage.count,
                pendingGarbagePacks: current.garbagePacks.count
            )
        } catch { throw AgentIncrementalJournal.normalized(error) }
    }

    func metrics() -> JournalStorageMetrics { counters.snapshot() }

    func rotationOverdue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !poisoned, let (root, _) = try? currentRoot() else { return false }
        return root.activeEnd >= UInt64(policy.segmentBytes)
    }

    /// Maintenance reads a whole sealed segment or state pack, and the active segment is sealed as
    /// it is. A budget smaller than what the store already keeps would stall maintenance for good.
    private func requireWorkBudget(root: Root, layout: Layout) throws {
        var largest = max(root.activeEnd, layout.sealed.map(\.end).max() ?? 0)
        for pack in layout.packs {
            if let size = try? Self.fileSize(stateURL(pack)) { largest = max(largest, size) }
        }
        guard largest <= UInt64(policy.maxWorkBytes) else {
            throw AgentJournalError.maintenanceBudgetTooSmall(requiredWorkBytes: largest)
        }
    }

    private func readData(_ url: URL) throws -> Data {
        let handle = try openRegularFile(url)
        defer { try? handle.close() }
        let data = try handle.readToEnd() ?? Data()
        counters.add(read: data.count)
        return data
    }

    private static func managedDirectories(supportsAdmissionRejections: Bool, supportsAuthorizationAudit: Bool = false, supportsConfirmedNoEffect: Bool = false) -> [String] {
        ["roots", "layouts", "segments", "state", "blobs", "tmp", "witnesses"]
            + AnyIndexKind.all(supportsAdmissionRejections: supportsAdmissionRejections, supportsAuthorizationAudit: supportsAuthorizationAudit, supportsConfirmedNoEffect: supportsConfirmedNoEffect).map(\.name)
    }

    private func validateManagedDirectories() throws {
        for name in Self.managedDirectories(supportsAdmissionRejections: supportsAdmissionRejections || supportsAuthorizationAudit, supportsAuthorizationAudit: supportsAuthorizationAudit, supportsConfirmedNoEffect: supportsConfirmedNoEffect) {
            try validateManagedDirectory(directoryURL.appendingPathComponent(name))
        }
    }

    private func validateManagedDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw AgentJournalError.invalidHeader
        }
    }

    private func openRegularFile(_ url: URL) throws -> FileHandle {
        try validateManagedDirectory(url.deletingLastPathComponent())
        let fd = DarwinOrGlibcOpen(url.path, O_RDONLY | O_NOFOLLOW, 0)
        guard fd >= 0 else { throw Self.ioError("open managed file") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            _ = DarwinOrGlibcClose(fd)
            throw AgentJournalError.invalidFrame
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func managedName(_ id: UUID) -> String { "\(storeID.uuidString)_\(id.uuidString)" }
    private func rootURL(_ id: UUID) -> URL { directoryURL.appendingPathComponent("roots/\(managedName(id)).json") }
    private func layoutURL(_ id: UUID) -> URL { directoryURL.appendingPathComponent("layouts/\(managedName(id)).json") }
    private func segmentURL(_ id: UUID) -> URL { directoryURL.appendingPathComponent("segments/\(managedName(id)).seg") }
    private func stateURL(_ id: UUID) -> URL { directoryURL.appendingPathComponent("state/\(managedName(id)).pack") }
    private func blobURL(_ id: UUID) -> URL {
        directoryURL.appendingPathComponent("blobs/\(id.uuidString.prefix(2))/\(managedName(id)).blob")
    }

    private func indexURL(_ kind: String, _ key: String) -> URL {
        let digest = Self.digest(Data(key.utf8))
        return directoryURL.appendingPathComponent(kind)
            .appendingPathComponent(String(digest.prefix(2)))
            .appendingPathComponent("\(storeID.uuidString)_\(digest).json")
    }

    private func witnessURL(_ kind: String, _ key: String) -> URL {
        let digest = Self.digest(Data(key.utf8))
        return directoryURL.appendingPathComponent("witnesses")
            .appendingPathComponent(String(digest.prefix(2)))
            .appendingPathComponent("\(storeID.uuidString)_\(kind)_\(digest).witness")
    }

    private func witnessExists(_ kind: String, _ key: String) throws -> Bool {
        let url = witnessURL(kind, key)
        let shard = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: shard.path) {
            try validateManagedDirectory(shard)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func loadWitness(_ kind: String, _ key: String) throws -> IndexWitness {
        try validateManagedDirectory(directoryURL.appendingPathComponent("witnesses"))
        try validateManagedDirectory(witnessURL(kind, key).deletingLastPathComponent())
        let wrapped = try JSONDecoder().decode(IndexEnvelope.self,
            from: readData(witnessURL(kind, key)))
        guard wrapped.storeID == storeID,
              Self.digest(wrapped.payload) == wrapped.digest else {
            throw AgentJournalError.checksumMismatch
        }
        let witness = try JSONDecoder().decode(IndexWitness.self, from: wrapped.payload)
        guard witness.kind == kind, witness.keyDigest == Self.digest(Data(key.utf8)),
              witness.firstSequence > 0 else { throw AgentJournalError.invalidRecord }
        return witness
    }

    /// An orphan witness can precede an unpublished transaction. The
    /// position's stable commit ID distinguishes that candidate from the
    /// different batch later published at the same sequence, even after GC.
    private func witnessWasPublished(_ witness: IndexWitness, root: Root) throws -> Bool {
        guard witness.firstSequence <= root.sequence else { return false }
        let published = try location(witness.firstSequence, root: root)
        guard let commitID = published.commitID else { throw AgentJournalError.invalidRecord }
        return commitID == witness.commitID
    }

    private func publishWitness(_ kind: String, key: String, sequence: UInt64,
                                commitID: UUID) throws {
        let target = witnessURL(kind, key)
        let shard = target.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: shard.path) {
            try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: false)
            try Self.syncDirectory(shard.deletingLastPathComponent())
        }
        try validateManagedDirectory(shard)
        let witness = IndexWitness(kind: kind, keyDigest: Self.digest(Data(key.utf8)),
                                   firstSequence: sequence, commitID: commitID)
        let bytes = try JSONEncoder().encode(witness)
        try atomicWrite(JSONEncoder().encode(IndexEnvelope(storeID: storeID,
            digest: Self.digest(bytes), payload: bytes)), at: target)
    }

    private static func followUpKey(_ sessionID: UUID, _ inputID: String) -> String {
        "\(sessionID.uuidString)/\(Data(inputID.utf8).base64EncodedString())"
    }

    /// Stable operation identity is the key prefix before the exact tool name
    /// and canonical JSON arguments, so '/' inside an operation ID is legal.
    private static func operationID(_ intent: PendingMutationIntent) -> String? {
        guard let arguments = try? JSONValue.decodeToolArguments(intent.call.argumentsJSON) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(arguments) else { return nil }
        let suffix = "/\(intent.call.name)/\(String(decoding: data, as: UTF8.self))"
        guard intent.idempotencyKey.hasSuffix(suffix) else { return nil }
        let prefix = intent.idempotencyKey.dropLast(suffix.count)
        return prefix.isEmpty ? nil : String(prefix)
    }

    private static func pendingOperationKey(_ operationID: String) -> String {
        "operation/\(Data(operationID.utf8).base64EncodedString())"
    }

    private static let untypedPendingKey = "untyped"

    private static func pendingOperationKey(_ intent: PendingMutationIntent, runID: UUID) -> String? {
        // The Run/call fallback is known not to represent a logical operation.
        // A malformed or otherwise unrecognized key is unknown and blocks safely.
        if intent.idempotencyKey == "\(runID.uuidString)/\(intent.call.id.rawValue)" { return nil }
        return operationID(intent).map(pendingOperationKey) ?? untypedPendingKey
    }

    private static func followUpOrdinalKey(_ sessionID: UUID, _ ordinal: UInt64) -> String {
        "\(sessionID.uuidString)/\(ordinal)"
    }

    func auditDigest(_ data: Data) -> String { Self.digest(data) }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func currentRoot() throws -> (Root, UUID) {
        let current = try JSONDecoder().decode(Current.self,
            from: readData(directoryURL.appendingPathComponent("CURRENT")))
        if let expectedCurrent {
            guard current == expectedCurrent else { throw AgentJournalError.concurrentWriter }
        } else {
            expectedCurrent = current
        }
        let bytes = try readData(rootURL(current.root))
        guard Self.digest(bytes) == current.digest else { throw AgentJournalError.checksumMismatch }
        let root = try JSONDecoder().decode(Root.self, from: bytes)
        guard root.storeID == storeID, root.nextRecordSequence > 0,
              (root.auditRecordCount != nil) == supportsAuthorizationAudit else { throw AgentJournalError.invalidHeader }
        guard root.formatDigest == expectedFormatDigest,
              Self.digest(try readData(directoryURL.appendingPathComponent("format.json"))) == expectedFormatDigest else {
            throw AgentJournalError.checksumMismatch
        }
        return (root, current.root)
    }

    private func layout(_ root: Root) throws -> Layout {
        let bytes = try readData(layoutURL(root.layout))
        guard Self.digest(bytes) == root.layoutDigest else { throw AgentJournalError.checksumMismatch }
        let value = try JSONDecoder().decode(Layout.self, from: bytes)
        guard value.generation == root.layoutGeneration else { throw AgentJournalError.invalidRecord }
        return value
    }

    private func publishRoot(_ root: Root, id: UUID) throws {
        let bytes = try JSONEncoder().encode(root)
        try writeNew(bytes, at: rootURL(id))
        let current = Current(root: id, digest: Self.digest(bytes))
        try atomicWrite(JSONEncoder().encode(current),
                        at: directoryURL.appendingPathComponent("CURRENT"))
        expectedCurrent = current
    }

    private static func ioError(_ operation: String) -> AgentJournalError {
        .persistenceUnavailable("\(operation): errno \(errno)")
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw AgentJournalError.invalidFrame }
        return size.uint64Value
    }

    private static func truncate(_ url: URL, to offset: UInt64) throws {
        let fd = DarwinOrGlibcOpen(url.path, O_RDWR | O_NOFOLLOW, 0)
        guard fd >= 0 else { throw ioError("open segment") }
        defer { _ = DarwinOrGlibcClose(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size >= 0, UInt64(info.st_size) >= offset else {
            throw AgentJournalError.invalidFrame
        }
        guard ftruncate(fd, off_t(offset)) == 0, fsync(fd) == 0 else { throw ioError("truncate unpublished tail") }
    }

    private func writeNew(_ data: Data, at url: URL) throws {
        try validateManagedDirectory(url.deletingLastPathComponent())
        let fd = DarwinOrGlibcOpen(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Self.ioError("create managed file") }
        defer { _ = DarwinOrGlibcClose(fd) }
        try fault?(.beforeManagedWrite)
        try writeAll(data, fd: fd)
        try fault?(.beforeManagedSync)
        guard fsync(fd) == 0 else { throw Self.ioError("sync managed file") }
        try Self.syncDirectory(url.deletingLastPathComponent())
    }

    private func atomicWrite(_ data: Data, at url: URL) throws {
        try validateManagedDirectory(url.deletingLastPathComponent())
        let temporary = directoryURL.appendingPathComponent("tmp/\(managedName(UUID())).tmp")
        try writeNew(data, at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if url.lastPathComponent == "CURRENT" { try fault?(.beforeCurrentReplace) }
        guard rename(temporary.path, url.path) == 0 else { throw Self.ioError("publish managed file") }
        if url.lastPathComponent == "CURRENT" { try fault?(.afterCurrentReplace) }
        try Self.syncDirectory(url.deletingLastPathComponent())
    }

    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = DarwinOrGlibcWrite(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Self.ioError("write managed file") }
                offset += written
            }
        }
        counters.add(written: data.count)
    }

    /// The Host owns the store's parent and may reach it through a symlink, which the path keeps while
    /// the store does not exist yet. Sync the parent's real directory; managed paths keep `O_NOFOLLOW`.
    private static func syncParentDirectory(of directory: URL) throws {
        guard let resolved = realpath(directory.deletingLastPathComponent().path, nil) else {
            throw ioError("resolve store parent directory")
        }
        defer { free(resolved) }
        try syncDirectory(URL(fileURLWithPath: String(cString: resolved)))
    }

    private static func syncDirectory(_ url: URL) throws {
        let fd = DarwinOrGlibcOpen(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW, 0)
        guard fd >= 0 else { throw ioError("open managed directory") }
        defer { _ = DarwinOrGlibcClose(fd) }
        guard fsync(fd) == 0 else { throw ioError("sync managed directory") }
    }

    /// A batch payload up to this size is stored inside its frame; a larger one goes to a blob.
    static func inlinePayloadLimit(segmentBytes: Int) -> Int { min(segmentBytes / 2, 256 * 1024) }

    /// The largest frame an append writes: the length prefix and the JSON wrapper around an inline
    /// payload at the limit, whose base64 text is all slashes that the encoder escapes.
    static func largestInlineFrameBytes(segmentBytes: Int) throws -> Int {
        let payload = Data(repeating: 0xFF, count: inlinePayloadLimit(segmentBytes: segmentBytes))
        return try 4 + JSONEncoder().encode(Frame(digest: String(repeating: "0", count: 64),
                                                  payload: payload, blob: nil)).count
    }

    private func frameBytes(_ batch: BatchV2) throws -> (Data, String, UUID?) {
        counters.add(encodedBatches: 1)
        let payload = try JSONEncoder().encode(batch)
        let digest = Self.digest(payload)
        let frame: Frame
        if payload.count > Self.inlinePayloadLimit(segmentBytes: policy.segmentBytes) {
            let id = UUID()
            let shard = blobURL(id).deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: shard.path) {
                try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: false)
                try Self.syncDirectory(shard.deletingLastPathComponent())
            }
            try writeNew(payload, at: blobURL(id))
            frame = Frame(digest: digest, payload: nil, blob: id)
        } else {
            frame = Frame(digest: digest, payload: payload, blob: nil)
        }
        let wrapped = try JSONEncoder().encode(frame)
        guard wrapped.count <= UInt32.max - 4 else { throw AgentJournalError.invalidFrame }
        var length = UInt32(wrapped.count).bigEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(wrapped)
        return (data, digest, frame.blob)
    }

    private func readFrame(_ location: Location) throws -> (BatchV2, String, UUID?) {
        guard location.length >= 4, location.length <= 32 * 1024 * 1024,
              location.kind == "segment" || location.kind == "state" else { throw AgentJournalError.invalidFrame }
        let url = location.kind == "segment" ? segmentURL(location.file) : stateURL(location.file)
        let handle = try openRegularFile(url)
        defer { try? handle.close() }
        try handle.seek(toOffset: location.offset)
        guard let data = try handle.read(upToCount: Int(location.length)), data.count == location.length else {
            throw AgentJournalError.invalidFrame
        }
        counters.add(read: data.count)
        let length = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard UInt64(length) + 4 == UInt64(location.length) else { throw AgentJournalError.invalidFrame }
        let frame = try JSONDecoder().decode(Frame.self, from: Data(data.dropFirst(4)))
        guard (frame.payload == nil) != (frame.blob == nil) else { throw AgentJournalError.invalidFrame }
        let payload = try frame.payload ?? readData(blobURL(frame.blob!))
        guard Self.digest(payload) == frame.digest else { throw AgentJournalError.checksumMismatch }
        let batch = try JSONDecoder().decode(BatchV2.self, from: payload)
        counters.add(decoded: 1)
        guard batch.schema == 2,
              supportsConfirmedNoEffect || batch.mutation?.executorNoEffectProof == nil,
              supportsAuthorizationAudit || (batch.auditRecords == nil && batch.auditCheckpoint == nil),
              location.commitID.map({ $0 == batch.commitID }) ?? true else {
            throw AgentJournalError.invalidRecord
        }
        return (batch, frame.digest, frame.blob)
    }

    private func load(_ location: Location) throws -> BatchV2 { try readFrame(location).0 }
    private func frameDigest(_ location: Location) throws -> String { try readFrame(location).1 }

    private func pointer<Value: Codable>(_ kind: IndexKind<Value>, key: String, root: Root) throws -> Value? {
        let url = indexURL(kind.name, key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if kind.witnessed,
               try witnessExists(kind.name, key),
               try witnessWasPublished(loadWitness(kind.name, key), root: root) {
                throw AgentJournalError.invalidRecord
            }
            return nil
        }
        if kind.witnessed {
            guard try witnessExists(kind.name, key) else {
                throw AgentJournalError.invalidRecord
            }
            // An index candidate written before a failed CURRENT publication
            // can reuse a sequence later occupied by a different commit.
            guard try witnessWasPublished(loadWitness(kind.name, key), root: root) else { return nil }
        }
        let index: Index<Value> = try loadIndex(url)
        for slot in [index.current, index.previous].compactMap({ $0 }) {
            guard slot.key == key else { throw AgentJournalError.invalidRecord }
            if kind.isPublished(slot, in: root) { return slot.value }
        }
        return nil
    }

    private func updateIndex<Value: Codable>(_ kind: IndexKind<Value>, key: String, value: Value,
                                              version: UInt64, root: Root,
                                              commitID: UUID? = nil) throws {
        let url = indexURL(kind.name, key)
        let shard = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: shard.path) {
            try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: false)
            try Self.syncDirectory(shard.deletingLastPathComponent())
        }
        let old: Index<Value>?
        if FileManager.default.fileExists(atPath: url.path) {
            old = try loadIndex(url)
        } else {
            old = nil
        }
        let witnessExists = try kind.witnessed && self.witnessExists(kind.name, key)
        let witnessPublished = try witnessExists && witnessWasPublished(loadWitness(kind.name, key), root: root)
        let previous = [old?.current, old?.previous].compactMap { $0 }.first { slot in
            slot.key == key && kind.isPublished(slot, in: root) && (!kind.witnessed || witnessPublished)
        }
        if let old, old.current.key != key { throw AgentJournalError.invalidRecord }
        if kind.witnessed {
            guard let commitID else { throw AgentJournalError.invalidRecord }
            if previous != nil {
                guard witnessPublished else {
                    throw AgentJournalError.invalidRecord
                }
            } else {
                if witnessPublished {
                    // The published key's index disappeared; never turn a
                    // retry into a new identity or Session.
                    throw AgentJournalError.invalidRecord
                }
                // The witness is durable before the index and CURRENT. A
                // failed candidate may safely be replaced on the next write.
                try publishWitness(kind.name, key: key, sequence: version, commitID: commitID)
            }
        }
        let index = Index(current: Slot(key: key, version: version, value: value), previous: previous)
        let bytes = try JSONEncoder().encode(index)
        try atomicWrite(JSONEncoder().encode(IndexEnvelope(storeID: storeID,
            digest: Self.digest(bytes), payload: bytes)), at: url)
    }

    private func loadIndex<Value: Codable>(_ url: URL) throws -> Index<Value> {
        try JSONDecoder().decode(Index<Value>.self, from: loadIndexPayload(url))
    }

    private func loadIndexPayload(_ url: URL) throws -> Data {
        let wrapped = try JSONDecoder().decode(IndexEnvelope.self, from: readData(url))
        guard wrapped.storeID == storeID,
              Self.digest(wrapped.payload) == wrapped.digest else { throw AgentJournalError.checksumMismatch }
        return wrapped.payload
    }

    private func location(_ sequence: UInt64, root: Root) throws -> Location {
        guard sequence > 0, sequence <= root.sequence,
              let location: Location = try pointer(.positions, key: String(sequence), root: root) else {
            throw AgentJournalError.invalidRecord
        }
        guard location.commitID != nil else { throw AgentJournalError.invalidRecord }
        return location
    }

    private func hasLiveMessage(_ batch: BatchV2, root: Root) throws -> Bool {
        let count = try View(store: self, root: root, writable: false)
            .header(batch.sessionID)?.messageCount ?? 0
        for offset in batch.messages.indices {
            let ordinal = batch.messageStart + UInt64(offset)
            guard ordinal < count else { continue }
            let key = "\(batch.sessionID.uuidString)/\(ordinal)"
            let pointer: MessagePointer? = try pointer(.messages, key: key, root: root)
            if pointer?.sequence == batch.sequence && pointer?.offset == offset { return true }
        }
        return false
    }

    private func isBatchNeeded(_ batch: BatchV2, at location: Location, root: Root) throws -> Bool {
        // Default retention is append-only: audit facts and their restricted payloads stay live.
        if !(batch.auditRecords ?? []).isEmpty { return true }
        if let checkpoint = batch.auditCheckpoint {
            let head: UInt64? = try pointer(.auditExports, key: checkpoint.configurationID, root: root)
            if head == batch.sequence { return true }
        }
        let sessionHead: UInt64? = try pointer(.sessions, key: batch.sessionID.uuidString, root: root)
        let callHead: UInt64?
        if let mutation = batch.mutation {
            let key = "\(mutation.sessionID.uuidString)/\(mutation.runID.uuidString)/\(mutation.intent.call.id)"
            callHead = try pointer(callsIndex, key: key, root: root)
        } else { callHead = nil }
        if let rejection = batch.admissionRejection {
            let key = "\(batch.sessionID.uuidString)/\(rejection.runID.uuidString)/\(rejection.callID)"
            let rejectionHead: UInt64? = try pointer(.rejections, key: key, root: root)
            if rejectionHead == batch.sequence { return true }
        }
        // `pendingOperations` holds its Session set inline and names no batch, so it keeps none.
        if batch.queueHead != nil {
            let head: UInt64? = try pointer(.queueHeads, key: batch.sessionID.uuidString, root: root)
            if head == batch.sequence { return true }
        }
        for record in batch.queueChanges {
            let idHead: UInt64? = try pointer(.queueIDs, key: Self.followUpKey(batch.sessionID, record.inputID), root: root)
            let ordinalHead: UInt64? = try pointer(.queueOrder, key: Self.followUpOrdinalKey(batch.sessionID, record.ordinal), root: root)
            if idHead == batch.sequence || ordinalHead == batch.sequence { return true }
        }
        for link in batch.queueLinks {
            let head: UInt64? = try pointer(.queueLinks, key: Self.followUpOrdinalKey(batch.sessionID, link.ordinal), root: root)
            if head == batch.sequence { return true }
        }
        return try hasLiveMessage(batch, root: root) || sessionHead == batch.sequence ||
            callHead == batch.sequence ||
            (root.lastFrame?.kind == location.kind && root.lastFrame?.file == location.file &&
             root.lastFrame?.offset == location.offset)
    }

    private func append(_ data: Data, to root: Root, commitID: UUID) throws -> Location {
        let url = segmentURL(root.active)
        try validateManagedDirectory(url.deletingLastPathComponent())
        let fd = DarwinOrGlibcOpen(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW, 0)
        guard fd >= 0 else { throw Self.ioError("open active segment") }
        defer { _ = DarwinOrGlibcClose(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size >= 0, UInt64(info.st_size) == root.activeEnd else {
            throw AgentJournalError.persistenceUnavailable("active segment changed outside the owner")
        }
        if let fault {
            do { try fault(.partialAppend) }
            catch {
                try writeAll(Data(data.prefix(max(1, data.count / 3))), fd: fd)
                throw error
            }
        }
        try writeAll(data, fd: fd)
        try fault?(.beforeAppendSync)
        guard fsync(fd) == 0 else { throw Self.ioError("sync active segment") }
        try fault?(.afterAppendSync)
        return Location(kind: "segment", file: root.active, offset: root.activeEnd,
                        length: UInt32(data.count), generation: root.layoutGeneration,
                        commitID: commitID)
    }

    private func rotateIfNeeded(_ root: Root) throws {
        guard root.activeEnd >= policy.segmentBytes || root.activeBatches >= policy.maxSegmentBatches else { return }
        try fault?(.beforeRotation)
        let oldLayout = try layout(root)
        let nextSegment = UUID(), nextLayoutID = UUID()
        try writeNew(Data(), at: segmentURL(nextSegment))
        let nextLayout = Layout(generation: root.layoutGeneration + 1,
                                sealed: oldLayout.sealed + [Segment(id: root.active, end: root.activeEnd)],
                                packs: oldLayout.packs, garbage: oldLayout.garbage,
                                garbagePacks: oldLayout.garbagePacks)
        let nextLayoutBytes = try JSONEncoder().encode(nextLayout)
        try writeNew(nextLayoutBytes, at: layoutURL(nextLayoutID))
        let nextRoot = Root(storeID: storeID, formatDigest: root.formatDigest,
                            sequence: root.sequence,
                            nextRecordSequence: root.nextRecordSequence, active: nextSegment,
                            activeEnd: 0, activeBatches: 0, layout: nextLayoutID,
                            layoutDigest: Self.digest(nextLayoutBytes),
                            layoutGeneration: nextLayout.generation,
                            lastFrame: root.lastFrame, lastDigest: root.lastDigest, auditRecordCount: root.auditRecordCount)
        let (_, oldRootID) = try currentRoot()
        // Once CURRENT may have changed, only a reopen can tell which root is current.
        poisoned = true
        try publishRoot(nextRoot, id: UUID())
        poisoned = false
        try? FileManager.default.removeItem(at: rootURL(oldRootID))
        try? FileManager.default.removeItem(at: layoutURL(root.layout))
    }

    func maintain() async throws -> JournalMaintenanceStatus {
        try await withCheckedThrowingContinuation { continuation in
            maintenanceQueue.async { [self] in
                do {
                    _ = try performMaintenance()
                    try cleanupObsoletePack()
                    try cleanupGarbage()
                    continuation.resume(returning: try maintenanceStatus())
                }
                catch {
                    lock.lock()
                    lastMaintenanceError = String(describing: error)
                    lock.unlock()
                    continuation.resume(throwing: AgentIncrementalJournal.normalized(error))
                }
            }
        }
    }

    private func performMaintenance() throws -> JournalMaintenanceStatus {
        let began = DispatchTime.now().uptimeNanoseconds
        defer { counters.add(maintenanceNanoseconds: DispatchTime.now().uptimeNanoseconds - began) }
        struct CandidateFrame {
            let batch: BatchV2
            let bytes: Data
            let blob: UUID?
            let source: Location
        }
        struct Candidate {
            let segment: Segment
            let rootSequence: UInt64
            let frames: [CandidateFrame]
        }
        // Pin one sealed segment by owning the only maintenance candidate.
        // Foreground commits can proceed while immutable bytes are copied.
        let snapshot: (Root, Segment)?
        lock.lock()
        do {
            guard !closed else { throw AgentJournalError.storeClosed }
            guard !poisoned else { throw AgentJournalError.commitUnknown }
            var (root, _) = try currentRoot()
            if root.activeEnd >= UInt64(policy.segmentBytes) || root.activeBatches >= policy.maxSegmentBatches {
                // One retry per pass of a rotation that failed after an earlier commit.
                do { try rotateIfNeeded(root) } catch {
                    if poisoned { throw AgentJournalError.commitUnknown }
                    throw error
                }
                (root, _) = try currentRoot()
            }
            let currentLayout = try layout(root)
            if let segment = currentLayout.sealed.first {
                guard segment.end <= UInt64(policy.maxWorkBytes) else {
                    throw AgentJournalError.persistenceUnavailable("sealed segment exceeds maintenance work budget")
                }
                snapshot = (root, segment)
            } else { snapshot = nil }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }

        try fault?(.afterMaintenanceSnapshot)
        let candidate: Candidate?
        if let (root, segment) = snapshot {
            let file = try openRegularFile(segmentURL(segment.id))
            defer { try? file.close() }
            var sourceOffset: UInt64 = 0
            var frames: [CandidateFrame] = []
            while sourceOffset < segment.end {
                try Task.checkCancellation()
                try file.seek(toOffset: sourceOffset)
                guard let header = try file.read(upToCount: 4), header.count == 4 else {
                    throw AgentJournalError.invalidFrame
                }
                counters.add(read: header.count)
                let size = UInt64(header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                guard size > 0, size < 32 * 1024 * 1024,
                      sourceOffset <= segment.end, size + 4 <= segment.end - sourceOffset else {
                    throw AgentJournalError.invalidFrame
                }
                let source = Location(kind: "segment", file: segment.id, offset: sourceOffset,
                                      length: UInt32(size + 4), generation: root.layoutGeneration)
                let (batch, _, blob) = try readFrame(source)
                try file.seek(toOffset: sourceOffset)
                guard let bytes = try file.read(upToCount: Int(size + 4)), bytes.count == size + 4 else {
                    throw AgentJournalError.invalidFrame
                }
                counters.add(read: bytes.count)
                frames.append(CandidateFrame(batch: batch, bytes: bytes, blob: blob, source: source))
                sourceOffset += size + 4
            }
            candidate = Candidate(segment: segment, rootSequence: root.sequence, frames: frames)
        } else { candidate = nil }

        guard let candidate else {
            try cleanupGarbage()
            try cleanupManagedOrphans()
            return try maintenanceStatus()
        }
        try Task.checkCancellation()
        lock.lock()
        defer { lock.unlock() }
        do {
            let (root, oldRootID) = try currentRoot()
            let currentLayout = try layout(root)
            guard currentLayout.sealed.contains(where: { $0.id == candidate.segment.id }),
                  root.sequence >= candidate.rootSequence else {
                throw AgentJournalError.concurrentWriter
            }
            try Task.checkCancellation()
            let generation = root.layoutGeneration + 1
            var relocatedLast = root.lastFrame
            var retainedData = Data()
            var retained: [(UInt64, UInt64, UInt32)] = []
            var discarded: [UInt64] = []
            var discardedBlobs: [(UInt64, UUID)] = []
            for frame in candidate.frames {
                let sequence = frame.batch.sequence
                let old = try location(sequence, root: root)
                guard old.kind == "segment", old.file == candidate.segment.id,
                      old.offset == frame.source.offset, old.length == frame.source.length else {
                    throw AgentJournalError.concurrentWriter
                }
                if try isBatchNeeded(frame.batch, at: old, root: root) {
                    retained.append((sequence, UInt64(retainedData.count), old.length))
                    retainedData.append(frame.bytes)
                } else {
                    discarded.append(sequence)
                    if let blob = frame.blob { discardedBlobs.append((sequence, blob)) }
                }
            }
            let packID: UUID? = retained.isEmpty ? nil : UUID()
            if let packID { try writeNew(retainedData, at: stateURL(packID)) }
            for (sequence, offset, length) in retained {
                guard let packID else { throw AgentJournalError.invalidRecord }
                let old = try location(sequence, root: root)
                let new = Location(kind: "state", file: packID, offset: offset,
                                   length: length, generation: generation,
                                   commitID: old.commitID)
                try updateIndex(.positions, key: String(sequence), value: new,
                                version: root.sequence, root: root)
                if root.lastFrame?.file == old.file && root.lastFrame?.offset == old.offset {
                    relocatedLast = new
                }
            }
            for sequence in discarded {
                let old = try location(sequence, root: root)
                let discardedLocation = Location(kind: "discarded", file: candidate.segment.id,
                                                  offset: old.offset, length: old.length,
                                                  generation: generation, commitID: old.commitID)
                try updateIndex(.positions, key: String(sequence), value: discardedLocation,
                                version: root.sequence, root: root)
            }
            guard relocatedLast?.file != candidate.segment.id else { throw AgentJournalError.invalidRecord }
            let nextLayoutID = UUID()
            let nextLayout = Layout(generation: generation,
                                   sealed: currentLayout.sealed.filter { $0.id != candidate.segment.id },
                                    packs: currentLayout.packs + (packID.map { [$0] } ?? []),
                                    garbage: currentLayout.garbage + [Segment(
                                        id: candidate.segment.id, end: candidate.segment.end,
                                        garbageBlobs: discardedBlobs.map {
                                            GarbageBlob(sequence: $0.0, id: $0.1)
                                        }
                                    )], garbagePacks: currentLayout.garbagePacks)
            let nextLayoutBytes = try JSONEncoder().encode(nextLayout)
            try writeNew(nextLayoutBytes, at: layoutURL(nextLayoutID))
            let updated = Root(storeID: root.storeID, formatDigest: root.formatDigest,
                               sequence: root.sequence,
                               nextRecordSequence: root.nextRecordSequence,
                               active: root.active, activeEnd: root.activeEnd,
                               activeBatches: root.activeBatches,
                               layout: nextLayoutID, layoutDigest: Self.digest(nextLayoutBytes),
                               layoutGeneration: generation,
                               lastFrame: relocatedLast, lastDigest: root.lastDigest, auditRecordCount: root.auditRecordCount)
            try fault?(.beforeMaintenancePublish)
            poisoned = true
            try publishRoot(updated, id: UUID())
            poisoned = false
            try? FileManager.default.removeItem(at: rootURL(oldRootID))
            try? FileManager.default.removeItem(at: layoutURL(root.layout))
            for sequence in discarded {
                let pointer: Location? = try pointer(.positions, key: String(sequence), root: updated)
                guard pointer?.kind == "discarded", pointer?.file == candidate.segment.id else {
                    throw AgentJournalError.invalidRecord
                }
            }
            let oldSize = try Self.fileSize(segmentURL(candidate.segment.id))
            try fault?(.beforeSegmentDelete)
            try FileManager.default.removeItem(at: segmentURL(candidate.segment.id))
            reclaimed += oldSize
            for (sequence, blob) in discardedBlobs {
                try removeDiscardedBlob(blob, sequence: sequence, root: updated)
            }
            try cleanupManagedOrphansLocked()
            lastMaintenanceError = nil
            return JournalMaintenanceStatus(sealedSegments: nextLayout.sealed.count,
                                            reclaimedBytes: reclaimed, lastError: nil)
        } catch {
            lastMaintenanceError = String(describing: error)
            throw error
        }
    }

    private func cleanupGarbage() throws {
        lock.lock()
        defer { lock.unlock() }
        let (root, oldRootID) = try currentRoot()
        let oldLayout = try layout(root)
        if let pack = oldLayout.garbagePacks.first {
            let url = stateURL(pack.id)
            if FileManager.default.fileExists(atPath: url.path) {
                guard try managedRegularFile(url) else { throw AgentJournalError.invalidRecord }
                try FileManager.default.removeItem(at: url)
            }
            for blob in pack.blobs {
                try removeDiscardedBlob(blob.id, sequence: blob.sequence, root: root)
            }
            let newID = UUID()
            let next = Layout(generation: root.layoutGeneration + 1, sealed: oldLayout.sealed,
                              packs: oldLayout.packs, garbage: oldLayout.garbage,
                              garbagePacks: Array(oldLayout.garbagePacks.dropFirst()))
            let bytes = try JSONEncoder().encode(next)
            try writeNew(bytes, at: layoutURL(newID))
            let updated = Root(storeID: root.storeID, formatDigest: root.formatDigest,
                               sequence: root.sequence, nextRecordSequence: root.nextRecordSequence,
                               active: root.active, activeEnd: root.activeEnd,
                               activeBatches: root.activeBatches, layout: newID,
                               layoutDigest: Self.digest(bytes), layoutGeneration: next.generation,
                               lastFrame: root.lastFrame, lastDigest: root.lastDigest, auditRecordCount: root.auditRecordCount)
            poisoned = true
            try publishRoot(updated, id: UUID())
            poisoned = false
            try? FileManager.default.removeItem(at: rootURL(oldRootID))
            try? FileManager.default.removeItem(at: layoutURL(root.layout))
            return
        }
        guard let segment = oldLayout.garbage.first else { return }
        let url = segmentURL(segment.id)
        try validateManagedDirectory(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            let file = try openRegularFile(url)
            defer { try? file.close() }
            var offset: UInt64 = 0
            while offset < segment.end {
                try file.seek(toOffset: offset)
                guard let header = try file.read(upToCount: 4), header.count == 4 else { throw AgentJournalError.invalidFrame }
                counters.add(read: header.count)
                let length = UInt64(header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }) + 4
                guard length > 4, length <= 32 * 1024 * 1024,
                      offset <= segment.end, length <= segment.end - offset else {
                    throw AgentJournalError.invalidFrame
                }
                let batch = try load(Location(kind: "segment", file: segment.id, offset: offset,
                                              length: UInt32(length), generation: root.layoutGeneration))
                let active: Location? = try pointer(.positions, key: String(batch.sequence), root: root)
                if active == nil || (active?.kind == "segment" && active?.file == segment.id) {
                    let position = indexURL(IndexKind<Location>.positions.name, String(batch.sequence))
                    if FileManager.default.fileExists(atPath: position.path) {
                        try FileManager.default.removeItem(at: position)
                    }
                }
                offset += length
            }
            let bytes = try Self.fileSize(url)
            guard try managedRegularFile(url) else { throw AgentJournalError.invalidRecord }
            try FileManager.default.removeItem(at: url)
            reclaimed += bytes
        }
        for blob in segment.garbageBlobs {
            try removeDiscardedBlob(blob.id, sequence: blob.sequence, root: root)
        }
        let newID = UUID()
        let next = Layout(generation: root.layoutGeneration + 1, sealed: oldLayout.sealed,
                          packs: oldLayout.packs, garbage: Array(oldLayout.garbage.dropFirst()),
                          garbagePacks: oldLayout.garbagePacks)
        let nextBytes = try JSONEncoder().encode(next)
        try writeNew(nextBytes, at: layoutURL(newID))
        let updated = Root(storeID: root.storeID, formatDigest: root.formatDigest,
                           sequence: root.sequence,
                           nextRecordSequence: root.nextRecordSequence, active: root.active,
                           activeEnd: root.activeEnd, activeBatches: root.activeBatches, layout: newID,
                           layoutDigest: Self.digest(nextBytes),
                           layoutGeneration: next.generation, lastFrame: root.lastFrame,
                           lastDigest: root.lastDigest, auditRecordCount: root.auditRecordCount)
        poisoned = true
        try publishRoot(updated, id: UUID())
        poisoned = false
        try? FileManager.default.removeItem(at: rootURL(oldRootID))
        try? FileManager.default.removeItem(at: layoutURL(root.layout))
    }

    /// Inspect at most one bounded pack per maintenance pass. Formal message
    /// updates can make an earlier published pack obsolete after it was live.
    private func cleanupObsoletePack() throws {
        lock.lock()
        defer { lock.unlock() }
        let (root, oldRootID) = try currentRoot()
        let currentLayout = try layout(root)
        guard !currentLayout.packs.isEmpty else { packCursor = 0; return }
        let index = packCursor % currentLayout.packs.count
        let packID = currentLayout.packs[index]
        let url = stateURL(packID)
        let file = try openRegularFile(url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size <= UInt64(policy.maxWorkBytes) else { throw AgentJournalError.invalidFrame }
        var offset: UInt64 = 0
        var oldPositions: [(UInt64, Location)] = []
        var oldBlobs: [GarbageBlob] = []
        while offset < size {
            try file.seek(toOffset: offset)
            guard let header = try file.read(upToCount: 4), header.count == 4 else {
                throw AgentJournalError.invalidFrame
            }
            counters.add(read: header.count)
            let payloadSize = UInt64(header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard payloadSize > 0, payloadSize < 32 * 1024 * 1024,
                  payloadSize + 4 <= size - offset else { throw AgentJournalError.invalidFrame }
            let location = Location(kind: "state", file: packID, offset: offset,
                                    length: UInt32(payloadSize + 4), generation: root.layoutGeneration)
            let (batch, _, blob) = try readFrame(location)
            if try isBatchNeeded(batch, at: location, root: root) {
                packCursor = (index + 1) % currentLayout.packs.count
                return
            }
            let current = try self.location(batch.sequence, root: root)
            guard current.kind == "state", current.file == packID, current.offset == offset else {
                throw AgentJournalError.invalidRecord
            }
            oldPositions.append((batch.sequence, current))
            if let blob { oldBlobs.append(.init(sequence: batch.sequence, id: blob)) }
            offset += payloadSize + 4
        }
        guard offset == size else { throw AgentJournalError.invalidFrame }
        let generation = root.layoutGeneration + 1
        for (sequence, old) in oldPositions {
            let discarded = Location(kind: "discarded", file: packID, offset: old.offset,
                                     length: old.length, generation: generation,
                                     commitID: old.commitID)
            try updateIndex(.positions, key: String(sequence), value: discarded,
                            version: root.sequence, root: root)
        }
        let layoutID = UUID()
        var packs = currentLayout.packs
        packs.remove(at: index)
        let next = Layout(generation: generation, sealed: currentLayout.sealed,
                          packs: packs, garbage: currentLayout.garbage,
                          garbagePacks: currentLayout.garbagePacks + [.init(id: packID, blobs: oldBlobs)])
        let bytes = try JSONEncoder().encode(next)
        try writeNew(bytes, at: layoutURL(layoutID))
        let updated = Root(storeID: root.storeID, formatDigest: root.formatDigest,
                           sequence: root.sequence, nextRecordSequence: root.nextRecordSequence,
                           active: root.active, activeEnd: root.activeEnd,
                           activeBatches: root.activeBatches, layout: layoutID,
                           layoutDigest: Self.digest(bytes), layoutGeneration: next.generation,
                           lastFrame: root.lastFrame, lastDigest: root.lastDigest, auditRecordCount: root.auditRecordCount)
        poisoned = true
        try publishRoot(updated, id: UUID())
        poisoned = false
        packCursor = packs.isEmpty ? 0 : index % packs.count
        try? FileManager.default.removeItem(at: rootURL(oldRootID))
        try? FileManager.default.removeItem(at: layoutURL(root.layout))
        try fault?(.beforePackDelete)
        try FileManager.default.removeItem(at: url)
        for blob in oldBlobs {
            try removeDiscardedBlob(blob.id, sequence: blob.sequence, root: updated)
        }
    }

    private func removeDiscardedBlob(_ blob: UUID, sequence: UInt64, root: Root) throws {
        let key = blob.uuidString
        let referenced: UInt64? = try pointer(.blobIndex, key: key, root: root)
        guard referenced == nil || referenced == sequence else { throw AgentJournalError.invalidRecord }
        if let active: Location = try pointer(.positions, key: String(sequence), root: root),
           active.kind == "state" || active.kind == "segment" {
            return
        }
        let index = indexURL(IndexKind<UInt64>.blobIndex.name, key)
        if FileManager.default.fileExists(atPath: index.path) {
            try FileManager.default.removeItem(at: index)
        }
        let url = blobURL(blob)
        if FileManager.default.fileExists(atPath: url.path) {
            try validateManagedDirectory(url.deletingLastPathComponent())
            guard try managedRegularFile(url) else { throw AgentJournalError.invalidRecord }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func cleanupManagedOrphans() throws {
        lock.lock()
        defer { lock.unlock() }
        try cleanupManagedOrphansLocked()
    }

    private func nextManagedEntries(in directory: URL, key: String, limit: Int) throws -> ([URL], Bool) {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            garbageEnumerators.removeValue(forKey: key)
            return ([], true)
        }
        try validateManagedDirectory(directory)
        let enumerator: FileManager.DirectoryEnumerator
        if let current = garbageEnumerators[key] {
            enumerator = current
        } else {
            guard let created = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsSubdirectoryDescendants]
            ) else { throw AgentJournalError.persistenceUnavailable("cannot enumerate managed directory") }
            enumerator = created
            garbageEnumerators[key] = created
        }
        var files: [URL] = []
        for _ in 0..<limit {
            guard let next = enumerator.nextObject() as? URL else {
                garbageEnumerators.removeValue(forKey: key)
                return (files, true)
            }
            files.append(next)
        }
        return (files, false)
    }

    // Called only under the store owner lock. Never interpret a path from a
    // manifest as a filesystem path; all eligible names are generated UUIDs.
    private func cleanupManagedOrphansLocked() throws {
        let (root, rootID) = try currentRoot()
        let currentLayout = try layout(root)
        let manager = FileManager.default
        let managedPrefix = storeID.uuidString + "_"
        let sets: [(String, String, Set<UUID>)] = [
            ("roots", "json", [rootID]),
            ("layouts", "json", [root.layout]),
            ("segments", "seg", Set([root.active] + currentLayout.sealed.map(\.id) + currentLayout.garbage.map(\.id))),
            ("state", "pack", Set(currentLayout.packs + currentLayout.garbagePacks.map(\.id))),
            ("tmp", "tmp", []),
        ]
        for (kind, suffix, live) in sets {
            let directory = directoryURL.appendingPathComponent(kind)
            let (urls, _) = try nextManagedEntries(in: directory, key: kind, limit: 16)
            for url in urls {
                let stem = url.deletingPathExtension().lastPathComponent
                guard url.pathExtension == suffix, stem.hasPrefix(managedPrefix),
                      let id = UUID(uuidString: String(stem.dropFirst(managedPrefix.count))),
                      !live.contains(id), try managedRegularFile(url) else { continue }
                try manager.removeItem(at: url)
            }
        }
        let shard = String(format: "%02X", garbageShard)
        let directory = directoryURL.appendingPathComponent("blobs/\(shard)")
        let (files, blobDone) = try nextManagedEntries(in: directory, key: "blob-\(shard)", limit: 16)
        for url in files {
            let stem = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "blob", stem.hasPrefix(managedPrefix),
                  let id = UUID(uuidString: String(stem.dropFirst(managedPrefix.count))),
                  id.uuidString.hasPrefix(shard), try managedRegularFile(url) else { continue }
            let published: UInt64? = try pointer(.blobIndex, key: id.uuidString, root: root)
            if published == nil {
                try manager.removeItem(at: url)
                let index = indexURL(IndexKind<UInt64>.blobIndex.name, id.uuidString)
                if manager.fileExists(atPath: index.path), try managedRegularFile(index) {
                    try manager.removeItem(at: index)
                }
            }
        }
        if blobDone {
            garbageShard = (garbageShard + 1) % 256
        }
        try cleanupUnpublishedIndexesLocked(root: root)
    }

    private func cleanupUnpublishedIndexesLocked(root: Root) throws {
        let shard = String(format: "%02x", garbageIndexShard)
        let kinds = AnyIndexKind.all(supportsAdmissionRejections: supportsAdmissionRejections, supportsAuthorizationAudit: supportsAuthorizationAudit, supportsConfirmedNoEffect: supportsConfirmedNoEffect)
        for kind in kinds {
            if finishedIndexKinds.contains(kind.name) { continue }
            let directory = directoryURL.appendingPathComponent("\(kind.name)/\(shard)")
            let (files, finished) = try nextManagedEntries(in: directory,
                key: "index-\(kind.name)-\(shard)", limit: 8)
            for url in files {
                guard url.pathExtension == "json",
                      url.deletingPathExtension().lastPathComponent.hasPrefix(storeID.uuidString + "_"),
                      try managedRegularFile(url) else { continue }
                let slots = try kind.slots(loadIndexPayload(url))
                guard let current = slots.first,
                      url.deletingPathExtension().lastPathComponent ==
                        "\(storeID.uuidString)_\(Self.digest(Data(current.key.utf8)))",
                      slots.allSatisfy({ $0.key == current.key }) else { throw AgentJournalError.invalidRecord }
                let published = slots.contains { $0.version <= root.sequence && $0.generation <= root.layoutGeneration }
                if !published {
                    try FileManager.default.removeItem(at: url)
                }
            }
            if finished { finishedIndexKinds.insert(kind.name) }
        }
        if finishedIndexKinds.count == kinds.count {
            garbageIndexShard = (garbageIndexShard + 1) % 256
            finishedIndexKinds.removeAll()
        }
    }

    private func managedRegularFile(_ url: URL) throws -> Bool {
        let flags = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return flags.isRegularFile == true && flags.isSymbolicLink != true
    }

    private final class View: JournalStoreView {
        let store: SegmentedJournalStore
        var root: Root
        let writable: Bool
        var didPublish = false

        init(store: SegmentedJournalStore, root: Root, writable: Bool) {
            self.store = store
            self.root = root
            self.writable = writable
        }

        private func batch(_ sequence: UInt64) throws -> BatchV2 {
            let position = try store.location(sequence, root: root)
            let batch = try store.load(position)
            guard batch.sequence == sequence else { throw AgentJournalError.invalidRecord }
            return batch
        }

        func header(_ id: UUID) throws -> JournalSessionHeader? {
            guard let sequence: UInt64 = try store.pointer(.sessions, key: id.uuidString, root: root) else { return nil }
            let found = try batch(sequence)
            guard found.sessionID == id, let header = found.header else { throw AgentJournalError.invalidRecord }
            return header.value()
        }

        func session(_ id: UUID) throws -> JournalStoredSession? {
            guard let header = try header(id) else { return nil }
            var content: [ModelMessage] = []
            var ordinal: UInt64 = 0
            while ordinal < header.messageCount {
                let page = try messages(sessionID: id, after: ordinal, limit: 512)
                guard !page.isEmpty else { throw AgentJournalError.invalidRecord }
                content.append(contentsOf: page.map(\.value))
                ordinal += UInt64(page.count)
            }
            return JournalStoredSession(header: header, history: content)
        }

        func identity(_ key: String) throws -> JournalStoredMutation? {
            try indexedMutation(.operations, key: key)
        }

        func mutation(sessionID: UUID, runID: UUID, callID: ToolCallID) throws -> JournalStoredMutation? {
            try indexedMutation(store.callsIndex, key: Self.callKey(sessionID, runID, callID))
        }

        func admissionRejection(sessionID: UUID, runID: UUID,
                                callID: ToolCallID) throws -> JournalAdmissionRejection? {
            guard store.supportsAdmissionRejections else { return nil }
            let key = Self.callKey(sessionID, runID, callID)
            guard let sequence: UInt64 = try store.pointer(.rejections, key: key, root: root) else { return nil }
            let found = try batch(sequence)
            guard found.sessionID == sessionID,
                  let value = try found.admissionRejection?.value(sessionID: sessionID),
                  value.runID == runID, value.callID == callID else {
                throw AgentJournalError.invalidRecord
            }
            return value
        }

        private static func callKey(_ sessionID: UUID, _ runID: UUID, _ callID: ToolCallID) -> String {
            "\(sessionID.uuidString)/\(runID.uuidString)/\(callID.rawValue)"
        }

        private func indexedMutation(_ kind: IndexKind<UInt64>, key: String) throws -> JournalStoredMutation? {
            guard let sequence: UInt64 = try store.pointer(kind, key: key, root: root) else { return nil }
            guard let mutation = try batch(sequence).mutation?.value() else { throw AgentJournalError.invalidRecord }
            let actual = kind.name == IndexKind<UInt64>.operations.name ? mutation.intent.idempotencyKey
                : Self.callKey(mutation.sessionID, mutation.runID, mutation.intent.call.id)
            guard actual == key else { throw AgentJournalError.invalidRecord }
            return mutation
        }

        func pending(sessionID: UUID?) throws -> [JournalStoredMutation] {
            let sessions: [UUID]
            if let sessionID { sessions = [sessionID] }
            else {
                let shards = try FileManager.default.contentsOfDirectory(
                    at: store.directoryURL.appendingPathComponent(IndexKind<UInt64>.sessions.name), includingPropertiesForKeys: nil
                ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                let urls = try shards.flatMap {
                    try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
                }.filter { $0.pathExtension == "json" &&
                    $0.deletingPathExtension().lastPathComponent.hasPrefix(store.storeID.uuidString + "_") }
                sessions = try urls.map { url in
                    let entry: Index<UInt64> = try store.loadIndex(url)
                    guard let id = UUID(uuidString: entry.current.key) else { throw AgentJournalError.invalidRecord }
                    return id
                }
            }
            var result: [JournalStoredMutation] = []
            for id in sessions {
                if let key = try header(id)?.pendingIdentity,
                   let mutation = try identity(key), mutation.sessionID == id,
                   mutation.state == .intent || mutation.state == .needsReconciliation {
                    result.append(mutation)
                }
            }
            return result.sorted { $0.sequence < $1.sequence }
        }

        func hasPending(operationID: String) throws -> Bool {
            guard store.supportsAdmissionRejections else { throw AgentJournalError.unsupportedFormat }
            for key in [SegmentedJournalStore.pendingOperationKey(operationID),
                        SegmentedJournalStore.untypedPendingKey] {
                guard let sessions: [UUID] = try store.pointer(.pendingOperations, key: key, root: root) else {
                    continue
                }
                for sessionID in sessions {
                    guard let pendingIdentity = try header(sessionID)?.pendingIdentity,
                          let mutation = try identity(pendingIdentity),
                          mutation.sessionID == sessionID,
                          mutation.state == .intent || mutation.state == .needsReconciliation else {
                        throw AgentJournalError.invalidRecord
                    }
                    let actual = SegmentedJournalStore.pendingOperationKey(mutation.intent,
                                                                          runID: mutation.runID)
                    guard actual == key else { throw AgentJournalError.invalidRecord }
                    return true
                }
            }
            return false
        }

        func nextRecordSequence() throws -> UInt64 { root.nextRecordSequence }

        func auditHighWater() throws -> UInt64 {
            guard store.supportsAuthorizationAudit, let count = root.auditRecordCount else {
                throw AgentAuthorizationError.auditStoreRequired
            }
            let summary: AuditIndexSummary? = try store.pointer(.auditGroups, key: "all", root: root)
            guard (summary?.count ?? 0) == count, (summary?.lastSequence ?? 0) == count else {
                throw AgentJournalError.invalidRecord
            }
            return count
        }

        func auditRecord(sequence: UInt64) throws -> AuditRecord {
            guard sequence > 0, sequence <= (try auditHighWater()),
                  let pointer: AuditRecordPointer = try store.pointer(.auditRecords, key: String(sequence), root: root) else {
                throw AgentJournalError.invalidRecord
            }
            let found = try batch(pointer.batchSequence)
            guard let records = found.auditRecords, records.indices.contains(pointer.offset) else {
                throw AgentJournalError.invalidRecord
            }
            let record = try records[pointer.offset].value()
            guard record.sequence == sequence, record.links.storeID == store.storeID,
                  record.links.operationDomain == store.operationDomain,
                  record.digest == store.auditDigest(try record.unsignedBytes()) else {
                throw AgentJournalError.invalidRecord
            }
            return record
        }

        func auditGroupCount(_ key: String) throws -> UInt64 {
            _ = try auditHighWater()
            let summary: AuditIndexSummary? = try store.pointer(.auditGroups, key: key, root: root)
            guard let summary else { return 0 }
            guard summary.count > 0, summary.count <= (root.auditRecordCount ?? 0),
                  summary.lastSequence <= (root.auditRecordCount ?? 0),
                  try auditGroupMember(key, ordinal: summary.count) == summary.lastSequence else {
                throw AgentJournalError.invalidRecord
            }
            return summary.count
        }

        func auditGroupMember(_ key: String, ordinal: UInt64) throws -> UInt64 {
            guard ordinal > 0, let sequence: UInt64 = try store.pointer(.auditMembers,
                key: "\(key)/\(ordinal)", root: root), sequence > 0, sequence <= (root.auditRecordCount ?? 0) else {
                throw AgentJournalError.invalidRecord
            }
            return sequence
        }

        func publishAudit(_ change: JournalAuditChange) throws {
            guard writable, !didPublish, store.supportsAuthorizationAudit, !change.records.isEmpty else {
                throw AgentJournalError.invalidRecord
            }
            let batch = BatchV2(schema: 2, commitID: UUID(), sequence: root.sequence + 1,
                sessionID: change.records[0].links.sessionID, header: nil, messageStart: 0, messages: [],
                mutation: nil, admissionRejection: nil, queueHead: nil, queueChanges: [], queueLinks: [],
                recordCount: UInt32(change.records.count), auditRecords: change.records.map(DiskAuditRecordV1.init))
            try publishBatch(batch, updateSession: false, admitsNewWork: change.admitsNewWork)
        }

        func auditExportCheckpoint(_ configurationID: String) throws -> JournalAuditExportCheckpoint? {
            guard store.supportsAuthorizationAudit else { throw AgentAuthorizationError.auditStoreRequired }
            guard let sequence: UInt64 = try store.pointer(.auditExports, key: configurationID, root: root) else { return nil }
            guard let checkpoint = try batch(sequence).auditCheckpoint,
                  checkpoint.configurationID == configurationID,
                  checkpoint.throughSequence <= (try auditHighWater()) else { throw AgentJournalError.invalidRecord }
            return checkpoint
        }

        func publishAuditExport(_ change: JournalAuditExportChange) throws {
            let previous = try auditExportCheckpoint(change.checkpoint.configurationID)
            guard writable, !didPublish, store.supportsAuthorizationAudit,
                  (previous?.throughSequence ?? 0) == change.expectedThroughSequence,
                  change.checkpoint.throughSequence > change.expectedThroughSequence,
                  change.checkpoint.throughSequence <= (try auditHighWater()),
                  previous.map({ $0.configurationDigest == change.checkpoint.configurationDigest }) ?? true else {
                throw AgentAuthorizationError.invalidAcknowledgement
            }
            let batch = BatchV2(schema: 2, commitID: UUID(), sequence: root.sequence + 1,
                sessionID: store.storeID, header: nil, messageStart: 0, messages: [], mutation: nil,
                admissionRejection: nil, queueHead: nil, queueChanges: [], queueLinks: [], recordCount: 0,
                auditRecords: [], auditCheckpoint: change.checkpoint)
            try publishBatch(batch, updateSession: false, admitsNewWork: false)
        }

        func messages(sessionID: UUID, after ordinal: UInt64, limit: Int) throws -> [JournalMessage] {
            try store.fault?(.beforeSessionRead)
            guard (1...1000).contains(limit) else { throw AgentJournalError.invalidRecord }
            guard let header = try header(sessionID), ordinal < header.messageCount else { return [] }
            var result: [JournalMessage] = []
            var cachedSequence: UInt64?
            var cached: BatchV2?
            for index in ordinal..<min(header.messageCount, ordinal + UInt64(limit)) {
                let key = "\(sessionID.uuidString)/\(index)"
                guard let pointer: MessagePointer = try store.pointer(.messages, key: key, root: root) else {
                    throw AgentJournalError.invalidRecord
                }
                if pointer.sequence != cachedSequence {
                    cached = try batch(pointer.sequence)
                    cachedSequence = pointer.sequence
                }
                guard let cached, cached.sessionID == sessionID,
                      cached.messages.indices.contains(pointer.offset) else {
                    throw AgentJournalError.invalidRecord
                }
                result.append(try cached.messages[pointer.offset].value())
            }
            return result
        }

        func followUpHead(sessionID: UUID) throws -> JournalFollowUpHead {
            guard let sequence: UInt64 = try store.pointer(.queueHeads, key: sessionID.uuidString, root: root) else {
                return .init()
            }
            let found = try batch(sequence)
            guard found.sessionID == sessionID, let head = found.queueHead else {
                throw AgentJournalError.invalidRecord
            }
            return try head.value()
        }

        func followUp(sessionID: UUID, inputID: String) throws -> JournalStoredFollowUp? {
            let key = SegmentedJournalStore.followUpKey(sessionID, inputID)
            guard let sequence: UInt64 = try store.pointer(.queueIDs, key: key, root: root) else { return nil }
            let found = try batch(sequence)
            guard found.sessionID == sessionID,
                  var value = try found.queueChanges.first(where: {
                      $0.inputID.utf8.elementsEqual(inputID.utf8)
                  })?.value(), value.sessionID == sessionID else {
                throw AgentJournalError.invalidRecord
            }
            value.nextQueued = try nextQueued(sessionID: sessionID, ordinal: value.ordinal)
            return value
        }

        private func nextQueued(sessionID: UUID, ordinal: UInt64) throws -> UInt64? {
            let key = SegmentedJournalStore.followUpOrdinalKey(sessionID, ordinal)
            guard let sequence: UInt64 = try store.pointer(.queueLinks, key: key, root: root) else {
                throw AgentJournalError.invalidRecord
            }
            let found = try batch(sequence)
            guard found.sessionID == sessionID,
                  let link = try found.queueLinks.first(where: { $0.ordinal == ordinal })?.value() else {
                throw AgentJournalError.invalidRecord
            }
            return link.next
        }

        private func followUp(sessionID: UUID, ordinal: UInt64) throws -> JournalStoredFollowUp? {
            let key = SegmentedJournalStore.followUpOrdinalKey(sessionID, ordinal)
            guard let sequence: UInt64 = try store.pointer(.queueOrder, key: key, root: root) else { return nil }
            let found = try batch(sequence)
            guard found.sessionID == sessionID,
                  var value = try found.queueChanges.first(where: { $0.ordinal == ordinal })?.value(),
                  value.sessionID == sessionID else { throw AgentJournalError.invalidRecord }
            value.nextQueued = try nextQueued(sessionID: sessionID, ordinal: ordinal)
            return value
        }

        func followUps(sessionID: UUID, after ordinal: UInt64, limit: Int) throws -> [JournalStoredFollowUp] {
            guard (1...1000).contains(limit) else { throw AgentJournalError.invalidRecord }
            let head = try followUpHead(sessionID: sessionID)
            guard ordinal < head.nextOrdinal else { return [] }
            let (candidate, overflow) = ordinal.addingReportingOverflow(UInt64(limit))
            let end = min(head.nextOrdinal, overflow ? UInt64.max : candidate)
            return try (ordinal..<end).map { current in
                guard let result = try followUp(sessionID: sessionID, ordinal: current) else {
                    throw AgentJournalError.invalidRecord
                }
                return result
            }
        }

        func publish(_ change: JournalStoreChange) throws {
            guard writable, !didPublish else { throw AgentJournalError.invalidRecord }
            if change.records.contains(where: { if case .pendingMutation = $0.event { return true }; return false }) {
                let unreclaimed = try store.layout(root).sealed.reduce(UInt64(0)) { $0 + $1.end }
                guard unreclaimed < UInt64(store.policy.maxUnreclaimedBytes) else {
                    throw AgentJournalError.maintenanceRequired
                }
            }
            let expected = try header(change.sessionID)?.revision ?? 0
            guard expected == change.expectedRevision, change.header.revision == expected + 1,
                  !change.records.isEmpty,
                  change.records.first?.sequence == root.nextRecordSequence,
                  change.records.last?.sequence == root.nextRecordSequence + UInt64(change.records.count) - 1,
                  change.messageStart <= (try header(change.sessionID)?.messageCount ?? 0),
                  change.header.messageCount == change.messageStart + UInt64(change.messages.count),
                  change.header.messageCount >= (try header(change.sessionID)?.messageCount ?? 0) else {
                throw AgentJournalError.concurrentWriter
            }
            let hasCheckpoint = change.records.contains { if case .checkpoint = $0.event { return true }; return false }
            guard hasCheckpoint || change.messages.isEmpty else { throw AgentJournalError.invalidRecord }
            let rejections = change.records.compactMap { record -> JournalAdmissionRejection? in
                guard case .toolAdmissionRejected(let callID, let name) = record.event,
                      let runID = record.runID else { return nil }
                return .init(sessionID: record.sessionID, runID: runID,
                             callID: callID, toolName: name)
            }
            guard rejections.count <= 1,
                  rejections.isEmpty || store.supportsAdmissionRejections else {
                throw AgentJournalError.unsupportedFormat
            }
            if let rejection = rejections.first {
                guard !rejection.callID.rawValue.isEmpty, !rejection.toolName.isEmpty,
                      hasCheckpoint,
                      change.messages.contains(where: { message in
                          if case .assistant(_, let calls) = message.value {
                              return calls.contains { $0.id == rejection.callID && $0.name == rejection.toolName }
                          }
                          return false
                      }),
                      change.messages.contains(where: { message in
                          if case .tool(let result) = message.value {
                              return result.callID == rejection.callID && result.isError
                          }
                          return false
                      }) else { throw AgentJournalError.invalidRecord }
            }
            let next = root.sequence + 1
            let oldHistoryHead = try header(change.sessionID)?.historyHead
            var finalHeader = change.header
            finalHeader.historyHead = hasCheckpoint ? next : oldHistoryHead
            var queueHead: JournalFollowUpHead?
            var queueChanges: [JournalStoredFollowUp] = []
            var queueLinks: [JournalFollowUpLink] = []
            if let admission = change.followUpAdmission {
                let current = try followUpHead(sessionID: change.sessionID)
                let prior = try followUp(sessionID: change.sessionID, inputID: admission.inputID)
                if let prior, prior.state == .withdrawn {
                    throw JournalFollowUpAdmissionError.withdrawn(
                        storeID: store.storeID, sessionID: change.sessionID,
                        inputID: admission.inputID, ordinal: prior.ordinal)
                }
                guard current.revision == admission.expectedQueueRevision,
                      current.queuedCount > 0, current.firstQueued != nil,
                      let prior,
                      prior.state == .queued, current.firstQueued == prior.ordinal,
                      let runID = change.records.first?.runID,
                      change.records.allSatisfy({ $0.runID == runID }),
                      let last = change.messages.last,
                      case .user(let parts) = last.value, parts.count == 1,
                      case .text(let text) = parts[0],
                      text.utf8.elementsEqual(prior.input.text.utf8),
                      current.queuedBytes >= text.utf8.count else {
                    throw AgentJournalError.concurrentWriter
                }
                var updated = current
                updated.revision += 1
                updated.queuedCount -= 1
                updated.queuedBytes -= text.utf8.count
                updated.firstQueued = prior.nextQueued
                updated.lastAdmitted = prior.ordinal
                if updated.queuedCount == 0 { updated.lastQueued = nil }
                var admitted = prior
                admitted.state = .admitted(runID: runID, formalMessageID: last.id)
                admitted.nextQueued = nil
                queueHead = updated
                queueChanges = [admitted]
                queueLinks = [.init(ordinal: prior.ordinal, next: nil)]
            }
            let admitsNewWork = change.admitsNewWork || change.followUpAdmission != nil
                || change.records.contains { if case .pendingMutation = $0.event { return true }; return false }
            let batch = BatchV2(schema: 2, commitID: UUID(), sequence: next,
                                sessionID: change.sessionID, header: DiskHeaderV1(finalHeader),
                                messageStart: change.messageStart,
                                messages: change.messages.map(DiskMessageV1.init),
                                mutation: try change.mutation.map(DiskMutationV1.init),
                                admissionRejection: rejections.first.map(DiskAdmissionRejectionV1.init),
                                queueHead: queueHead.map(DiskFollowUpHeadV2.init),
                                queueChanges: queueChanges.map(DiskFollowUpV2.init),
                                queueLinks: queueLinks.map(DiskFollowUpLinkV2.init),
                                recordCount: UInt32(change.records.count + change.auditRecords.count),
                                auditRecords: store.supportsAuthorizationAudit ? change.auditRecords.map(DiskAuditRecordV1.init) : nil)
            try publishBatch(batch, updateSession: true, admitsNewWork: admitsNewWork)
        }

        func publishFollowUp(_ change: JournalFollowUpChange) throws {
            guard writable, !didPublish, (0...2).contains(change.records.count),
                  change.links.count <= 2 else {
                throw AgentJournalError.invalidRecord
            }
            let current = try followUpHead(sessionID: change.sessionID)
            guard current.revision == change.expectedRevision,
                  change.head.revision == current.revision + 1,
                  change.records.allSatisfy({ $0.sessionID == change.sessionID && $0.ordinal < change.head.nextOrdinal }),
                  Set(change.records.map(\.ordinal)).count == change.records.count,
                  Set(change.links.map(\.ordinal)).count == change.links.count,
                  change.links.allSatisfy({ link in
                      link.ordinal < change.head.nextOrdinal &&
                          (link.next.map { $0 > link.ordinal && $0 < change.head.nextOrdinal } ?? true)
                  }) else {
                throw AgentJournalError.concurrentWriter
            }
            let batch = BatchV2(schema: 2, commitID: UUID(), sequence: root.sequence + 1,
                                sessionID: change.sessionID, header: nil, messageStart: 0,
                                messages: [], mutation: nil, admissionRejection: nil,
                                queueHead: DiskFollowUpHeadV2(change.head),
                                queueChanges: change.records.map(DiskFollowUpV2.init),
                                queueLinks: change.links.map(DiskFollowUpLinkV2.init), recordCount: 0)
            try publishBatch(batch, updateSession: false, admitsNewWork: change.admitsNewWork)
        }

        private func publishBatch(_ batch: BatchV2, updateSession: Bool, admitsNewWork: Bool) throws {
            let next = root.sequence + 1
            guard batch.sequence == next else { throw AgentJournalError.invalidRecord }
            let auditRecords = batch.auditRecords ?? []
            guard auditRecords.count <= 64, auditRecords.isEmpty || store.supportsAuthorizationAudit,
                  UInt64(batch.recordCount) >= UInt64(auditRecords.count) else { throw AgentJournalError.invalidRecord }
            let firstAudit = try store.supportsAuthorizationAudit ? auditHighWater() + 1 : 1
            let firstJournal = root.nextRecordSequence + UInt64(batch.recordCount) - UInt64(auditRecords.count)
            for (offset, disk) in auditRecords.enumerated() {
                let record = try disk.value()
                guard record.sequence == firstAudit + UInt64(offset),
                      record.journalRecordSequence == firstJournal + UInt64(offset),
                      record.links.storeID == store.storeID, record.links.operationDomain == store.operationDomain,
                      record.digest == store.auditDigest(try record.unsignedBytes()) else { throw AgentJournalError.invalidRecord }
            }
            if admitsNewWork {
                let unreclaimed = try store.layout(root).sealed.reduce(UInt64(0)) { $0 + $1.end }
                guard unreclaimed < UInt64(store.policy.maxUnreclaimedBytes) else { throw AgentJournalError.maintenanceRequired }
            }
            let (bytes, digest, blob) = try store.frameBytes(batch)
            // A failed rotation leaves the active segment past its target size. Until maintenance
            // rotates it, refuse new work and let admitted work settle only within the work budget,
            // so every segment stays readable by maintenance. Nothing is written before these checks.
            if admitsNewWork, root.activeEnd >= UInt64(store.policy.segmentBytes) {
                throw AgentJournalError.maintenanceRequired
            }
            guard root.activeEnd + UInt64(bytes.count) <= UInt64(store.policy.maxWorkBytes) else {
                throw AgentJournalError.maintenanceRequired
            }
            // Before append there is no possibly published batch. A failure
            // here has a definite noncommit result and leaves this handle
            // usable; managed blob candidates are collected as orphans.
            try store.fault?(.beforeAppend)
            // From the first write onward, a failure has a potentially
            // published result. Reopen and inspect the root before retrying.
            store.poisoned = true
            let location = try store.append(bytes, to: root, commitID: batch.commitID)
            try store.updateIndex(.positions, key: String(next), value: location,
                                  version: next, root: root)
            if updateSession {
                try store.updateIndex(.sessions, key: batch.sessionID.uuidString, value: next,
                                      version: next, root: root, commitID: batch.commitID)
                for offset in batch.messages.indices {
                    let key = "\(batch.sessionID.uuidString)/\(batch.messageStart + UInt64(offset))"
                    try store.updateIndex(.messages, key: key,
                                          value: MessagePointer(sequence: next, offset: offset),
                                          version: next, root: root)
                }
            }
            if let mutation = batch.mutation {
                try store.updateIndex(.operations, key: mutation.intent.identity, value: next,
                                      version: next, root: root, commitID: batch.commitID)
                try store.updateIndex(store.callsIndex, key: Self.callKey(mutation.sessionID, mutation.runID,
                    .init(rawValue: mutation.intent.call.id)),
                                      value: next, version: next, root: root, commitID: batch.commitID)
            }
            if let rejection = batch.admissionRejection {
                try store.updateIndex(.rejections,
                    key: Self.callKey(batch.sessionID, rejection.runID,
                                      .init(rawValue: rejection.callID)),
                    value: next, version: next, root: root, commitID: batch.commitID)
            }
            if let mutation = batch.mutation, store.supportsAdmissionRejections {
                if let key = SegmentedJournalStore.pendingOperationKey(try mutation.intent.value(),
                                                                       runID: mutation.runID) {
                    let existing: [UUID] = try store.pointer(.pendingOperations, key: key, root: root) ?? []
                    var sessions = Set(existing)
                    if mutation.state == AgentMutationState.intent.rawValue ||
                       mutation.state == AgentMutationState.needsReconciliation.rawValue {
                        sessions.insert(mutation.sessionID)
                    } else {
                        sessions.remove(mutation.sessionID)
                    }
                    try store.updateIndex(.pendingOperations, key: key,
                        value: sessions.sorted { $0.uuidString < $1.uuidString },
                        version: next, root: root, commitID: batch.commitID)
                }
            }
            if batch.queueHead != nil {
                try store.updateIndex(.queueHeads, key: batch.sessionID.uuidString,
                                      value: next, version: next, root: root, commitID: batch.commitID)
            }
            for record in batch.queueChanges {
                try store.updateIndex(.queueIDs, key: SegmentedJournalStore.followUpKey(batch.sessionID, record.inputID),
                                      value: next, version: next, root: root, commitID: batch.commitID)
                try store.updateIndex(.queueOrder, key: SegmentedJournalStore.followUpOrdinalKey(batch.sessionID, record.ordinal),
                                      value: next, version: next, root: root)
            }
            for link in batch.queueLinks {
                try store.updateIndex(.queueLinks, key: SegmentedJournalStore.followUpOrdinalKey(batch.sessionID, link.ordinal),
                                      value: next, version: next, root: root)
            }
            if let blob {
                try store.updateIndex(.blobIndex, key: blob.uuidString, value: next,
                                      version: next, root: root)
            }
            if !auditRecords.isEmpty {
                var summaries: [String: AuditIndexSummary] = [:]
                for (offset, record) in auditRecords.enumerated() {
                    try store.updateIndex(.auditRecords, key: String(record.sequence),
                        value: AuditRecordPointer(batchSequence: next, offset: offset),
                        version: next, root: root, commitID: batch.commitID)
                    for key in record.links.indexKeys + ["all"] {
                        let prior: AuditIndexSummary
                        if let cached = summaries[key] { prior = cached }
                        else { prior = try store.pointer(.auditGroups, key: key, root: root) ?? .init(count: 0, lastSequence: 0) }
                        let summary = AuditIndexSummary(count: prior.count + 1, lastSequence: record.sequence)
                        summaries[key] = summary
                        try store.updateIndex(.auditMembers, key: "\(key)/\(summary.count)", value: record.sequence,
                            version: next, root: root)
                    }
                }
                for (key, summary) in summaries {
                    try store.updateIndex(.auditGroups, key: key, value: summary,
                        version: next, root: root, commitID: batch.commitID)
                }
            }
            if let checkpoint = batch.auditCheckpoint {
                try store.updateIndex(.auditExports, key: checkpoint.configurationID, value: next,
                    version: next, root: root, commitID: batch.commitID)
            }
            try store.fault?(.afterIndexSync)
            let updated = Root(storeID: root.storeID, formatDigest: root.formatDigest,
                               sequence: next,
                               nextRecordSequence: root.nextRecordSequence + UInt64(batch.recordCount),
                               active: root.active, activeEnd: root.activeEnd + UInt64(bytes.count),
                               activeBatches: root.activeBatches + 1,
                               layout: root.layout, layoutDigest: root.layoutDigest,
                               layoutGeneration: root.layoutGeneration,
                               lastFrame: location, lastDigest: digest,
                               auditRecordCount: root.auditRecordCount.map { $0 + UInt64((batch.auditRecords ?? []).count) })
            let (_, oldRootID) = try store.currentRoot()
            try store.publishRoot(updated, id: UUID())
            store.poisoned = false
            store.counters.add(committed: 1)
            root = updated
            didPublish = true
            try? FileManager.default.removeItem(at: store.rootURL(oldRootID))
            do { try store.rotateIfNeeded(updated) }
            catch { store.lastMaintenanceError = String(describing: error) }
        }
    }
}

private func DarwinOrGlibcOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
    path.withCString { open($0, flags, mode) }
}
private func DarwinOrGlibcClose(_ fd: Int32) -> Int32 { close(fd) }
private func DarwinOrGlibcWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { write(fd, buffer, count) }
