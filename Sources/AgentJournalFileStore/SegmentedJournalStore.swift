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

    public init(segmentBytes: Int = 2 * 1024 * 1024,
                maxWorkBytes: Int = 4 * 1024 * 1024,
                maxUnreclaimedBytes: Int = 64 * 1024 * 1024,
                maxSegmentBatches: Int = 128) throws {
        guard segmentBytes >= 1024, maxWorkBytes >= segmentBytes,
              maxUnreclaimedBytes >= maxWorkBytes, (1...1024).contains(maxSegmentBatches) else {
            throw AgentJournalError.invalidRecord
        }
        self.segmentBytes = segmentBytes
        self.maxWorkBytes = maxWorkBytes
        self.maxUnreclaimedBytes = maxUnreclaimedBytes
        self.maxSegmentBatches = maxSegmentBatches
    }

    public static let `default` = try! JournalMaintenancePolicy()
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
    case beforeClose
    case beforeSessionRead
}

public enum AgentIncrementalJournal {
    private static let openingQueue = DispatchQueue(label: "SwiftAgent.JournalFileStore.open",
                                                     qos: .utility, attributes: .concurrent)

    fileprivate static func normalized(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? AgentJournalError { return error }
        if error is DecodingError { return AgentJournalError.invalidRecord }
        return AgentJournalError.persistenceUnavailable(error.localizedDescription)
    }

    /// Use from UI and actor callers. A cancellation request after I/O starts
    /// still waits for the owned file operation to finish before returning.
    public static func createAsync(at directory: URL, operationDomain: String,
                                   policy: JournalMaintenancePolicy = .default,
                                   deadline: ContinuousClock.Instant? = nil) async throws -> AgentJournal {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw AgentJournalError.deadlineExceeded }
        let journal = try await openOwned(deadline: deadline) {
            try SegmentedJournalStore.create(at: directory, domain: operationDomain, policy: policy)
        }
        try Task.checkCancellation()
        return journal
    }

    public static func openAsync(at directory: URL,
                                 policy: JournalMaintenancePolicy = .default,
                                 deadline: ContinuousClock.Instant? = nil) async throws -> AgentJournal {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw AgentJournalError.deadlineExceeded }
        let journal = try await openOwned(deadline: deadline) {
            try SegmentedJournalStore.open(at: directory, policy: policy)
        }
        try Task.checkCancellation()
        return journal
    }

    private static func openOwned(deadline: ContinuousClock.Instant?,
                                  operation: @escaping @Sendable () throws -> SegmentedJournalStore) async throws -> AgentJournal {
        let cancellation = OpeningCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                openingQueue.async {
                    do {
                        if cancellation.isCancelled { throw CancellationError() }
                        if let deadline, ContinuousClock.now >= deadline { throw AgentJournalError.deadlineExceeded }
                        let store = try operation()
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
                              policy: JournalMaintenancePolicy = .default) throws -> AgentJournal {
        do {
            return AgentJournal(store: try SegmentedJournalStore.create(at: directory, domain: operationDomain, policy: policy))
        } catch { throw normalized(error) }
    }

    public static func open(at directory: URL,
                            policy: JournalMaintenancePolicy = .default) throws -> AgentJournal {
        do { return AgentJournal(store: try SegmentedJournalStore.open(at: directory, policy: policy)) }
        catch { throw normalized(error) }
    }

    package static func createForTesting(at directory: URL, operationDomain: String,
                                         policy: JournalMaintenancePolicy = .default,
                                         fault: @escaping @Sendable (JournalFileFaultStage) throws -> Void) throws -> AgentJournal {
        AgentJournal(store: try SegmentedJournalStore.create(at: directory, domain: operationDomain,
                                                              policy: policy, fault: fault))
    }
}

private final class OpeningCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
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

private struct Segment: Codable {
    let id: UUID
    let end: UInt64
}

private struct Layout: Codable {
    let generation: UInt64
    let sealed: [Segment]
    let packs: [UUID]
    let garbage: [Segment]
}

private struct Root: Codable {
    let storeID: UUID
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
}

private struct Current: Codable {
    let root: UUID
    let digest: String
}

// A frozen v1 disk DTO: changes to public enum Codable conformance require
// a new schema and an explicit conversion here.
private struct BatchV1: Codable {
    let schema: Int
    let commitID: UUID
    let sequence: UInt64
    let sessionID: UUID
    let header: DiskHeaderV1
    let historyParent: UInt64?
    let messages: [DiskMessageV1]
    let mutation: DiskMutationV1?
    let recordCount: UInt32
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
    private var writeLock: UInt64 = 0
    private var maintenance: UInt64 = 0

    func add(read bytes: Int = 0, decoded batches: Int = 0, written output: Int = 0,
             committed publications: Int = 0, writeLockNanoseconds: UInt64 = 0,
             maintenanceNanoseconds: UInt64 = 0) {
        lock.lock()
        read += UInt64(bytes)
        decoded += UInt64(batches)
        written += UInt64(output)
        committed += UInt64(publications)
        writeLock += writeLockNanoseconds
        maintenance += maintenanceNanoseconds
        lock.unlock()
    }

    func snapshot() -> JournalStorageMetrics {
        lock.lock()
        defer { lock.unlock() }
        return JournalStorageMetrics(bytesRead: read, decodedBatches: decoded,
                                     bytesWritten: written, committedBatches: committed,
                                     writeLockNanoseconds: writeLock,
                                     maintenanceNanoseconds: maintenance)
    }
}

private final class SegmentedJournalStore: JournalStore, @unchecked Sendable {
    let directoryURL: URL
    let storeID: UUID
    let operationDomain: String
    private let policy: JournalMaintenancePolicy
    private let lock = NSLock()
    private var descriptor: Int32
    private var closed = false
    private var poisoned = false
    private var reclaimed: UInt64 = 0
    private var lastMaintenanceError: String?
    private let counters = MetricsBox()
    private let maintenanceQueue = DispatchQueue(label: "SwiftAgent.JournalFileStore.maintenance", qos: .utility)
    private let fault: (@Sendable (JournalFileFaultStage) throws -> Void)?
    private var garbageShard = 0
    private var garbageIndexShard = 0
    private var garbageEnumerators: [String: FileManager.DirectoryEnumerator] = [:]
    private var finishedIndexKinds: Set<String> = []

    private init(directoryURL: URL, format: Format, descriptor: Int32,
                 policy: JournalMaintenancePolicy,
                 fault: (@Sendable (JournalFileFaultStage) throws -> Void)? = nil) {
        self.directoryURL = directoryURL
        storeID = format.storeID
        operationDomain = format.domain
        self.descriptor = descriptor
        self.policy = policy
        self.fault = fault
    }

    deinit { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); _ = DarwinOrGlibcClose(descriptor) } }

    static func create(at url: URL, domain: String, policy: JournalMaintenancePolicy,
                       fault: (@Sendable (JournalFileFaultStage) throws -> Void)? = nil) throws -> SegmentedJournalStore {
        guard !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentJournalError.invalidRecord
        }
        let directory = canonical(url)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw AgentJournalError.persistenceUnavailable("create requires a new directory")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["roots", "layouts", "segments", "sessions", "operations", "calls", "messages", "positions", "state", "blobs", "blob-index", "tmp"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        let descriptor = try lockStore(directory)
        let format = Format(magic: "SWIFTAGENT-SEGMENTED-JOURNAL", schema: 1,
                            storeID: UUID(), domain: domain)
        let store = SegmentedJournalStore(directoryURL: directory, format: format,
                                          descriptor: descriptor, policy: policy, fault: fault)
        do {
            try store.writeNew(JSONEncoder().encode(format), at: directory.appendingPathComponent("format.json"))
            let segment = UUID(), layoutID = UUID(), rootID = UUID()
            try store.writeNew(Data(), at: store.segmentURL(segment))
            let layoutBytes = try JSONEncoder().encode(Layout(generation: 0, sealed: [], packs: [], garbage: []))
            try store.writeNew(layoutBytes, at: store.layoutURL(layoutID))
            let root = Root(storeID: format.storeID, sequence: 0, nextRecordSequence: 1,
                            active: segment, activeEnd: 0, activeBatches: 0, layout: layoutID,
                            layoutDigest: Self.digest(layoutBytes), layoutGeneration: 0,
                            lastFrame: nil, lastDigest: nil)
            try store.publishRoot(root, id: rootID)
            try Self.syncDirectory(directory.deletingLastPathComponent())
            return store
        } catch {
            try? store.close()
            throw error
        }
    }

    static func open(at url: URL, policy: JournalMaintenancePolicy) throws -> SegmentedJournalStore {
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
        do {
            format = try JSONDecoder().decode(Format.self, from: Data(contentsOf: formatURL))
        } catch is DecodingError {
            throw AgentJournalError.invalidHeader
        } catch {
            throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }
        guard format.magic == "SWIFTAGENT-SEGMENTED-JOURNAL", !format.domain.isEmpty else {
            throw AgentJournalError.invalidHeader
        }
        guard format.schema == 1 else { throw AgentJournalError.unsupportedFormat }
        let descriptor = try lockStore(directory)
        let store = SegmentedJournalStore(directoryURL: directory, format: format, descriptor: descriptor, policy: policy)
        do {
            let (root, _) = try store.currentRoot()
            _ = try store.layout(root)
            if let location = root.lastFrame {
                let batch = try store.load(location)
                guard batch.sequence == root.sequence,
                      try store.frameDigest(location) == root.lastDigest else { throw AgentJournalError.invalidRecord }
            }
            let activeURL = store.segmentURL(root.active)
            let size = try Self.fileSize(activeURL)
            guard size >= root.activeEnd else { throw AgentJournalError.invalidFrame }
            // The exclusive owner can remove only bytes beyond the committed
            // root. A complete but unpublished tail was never admitted.
            if size > root.activeEnd { try Self.truncate(activeURL, to: root.activeEnd) }
            return store
        } catch {
            try? store.close()
            if let error = error as? AgentJournalError { throw error }
            if error is DecodingError { throw AgentJournalError.invalidRecord }
            throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func lockStore(_ directory: URL) throws -> Int32 {
        let path = directory.appendingPathComponent(".writer.lock").path
        let fd = DarwinOrGlibcOpen(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw ioError("open writer lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = DarwinOrGlibcClose(fd)
            throw AgentJournalError.storeInUse
        }
        return fd
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        guard !poisoned else { throw AgentJournalError.commitUnknown }
        try fault?(.beforeClose)
        closed = true
        let fd = descriptor
        descriptor = -1
        guard flock(fd, LOCK_UN) == 0, DarwinOrGlibcClose(fd) == 0 else { throw Self.ioError("close writer lock") }
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
            if error is DecodingError { throw AgentJournalError.invalidRecord }
            throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }
    }

    func maintenanceStatus() throws -> JournalMaintenanceStatus {
        lock.lock()
        defer { lock.unlock() }
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
        do {
            let (root, _) = try currentRoot()
            let current = try layout(root)
            return JournalStoreStatus(
                identity: .init(storeID: storeID, operationDomain: operationDomain),
                logicalSequence: root.sequence, layoutGeneration: root.layoutGeneration,
                activeSegmentBytes: root.activeEnd, sealedSegments: current.sealed.count,
                pendingGarbageSegments: current.garbage.count
            )
        } catch { throw AgentIncrementalJournal.normalized(error) }
    }

    func metrics() -> JournalStorageMetrics { counters.snapshot() }

    private func readData(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        counters.add(read: data.count)
        return data
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

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func currentRoot() throws -> (Root, UUID) {
        let current = try JSONDecoder().decode(Current.self,
            from: readData(directoryURL.appendingPathComponent("CURRENT")))
        let bytes = try readData(rootURL(current.root))
        guard Self.digest(bytes) == current.digest else { throw AgentJournalError.checksumMismatch }
        let root = try JSONDecoder().decode(Root.self, from: bytes)
        guard root.storeID == storeID, root.nextRecordSequence > 0 else { throw AgentJournalError.invalidHeader }
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
        try atomicWrite(JSONEncoder().encode(Current(root: id, digest: Self.digest(bytes))),
                        at: directoryURL.appendingPathComponent("CURRENT"))
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
        let fd = DarwinOrGlibcOpen(url.path, O_RDWR, 0)
        guard fd >= 0 else { throw ioError("open segment") }
        defer { _ = DarwinOrGlibcClose(fd) }
        guard ftruncate(fd, off_t(offset)) == 0, fsync(fd) == 0 else { throw ioError("truncate unpublished tail") }
    }

    private func writeNew(_ data: Data, at url: URL) throws {
        let fd = DarwinOrGlibcOpen(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Self.ioError("create managed file") }
        defer { _ = DarwinOrGlibcClose(fd) }
        try fault?(.beforeManagedWrite)
        try writeAll(data, fd: fd)
        try fault?(.beforeManagedSync)
        guard fsync(fd) == 0 else { throw Self.ioError("sync managed file") }
        try Self.syncDirectory(url.deletingLastPathComponent())
    }

    private func atomicWrite(_ data: Data, at url: URL) throws {
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

    private static func syncDirectory(_ url: URL) throws {
        let fd = DarwinOrGlibcOpen(url.path, O_RDONLY, 0)
        guard fd >= 0 else { throw ioError("open managed directory") }
        defer { _ = DarwinOrGlibcClose(fd) }
        guard fsync(fd) == 0 else { throw ioError("sync managed directory") }
    }

    private func frameBytes(_ batch: BatchV1) throws -> (Data, String, UUID?) {
        let payload = try JSONEncoder().encode(batch)
        let digest = Self.digest(payload)
        let frame: Frame
        if payload.count > min(policy.segmentBytes / 2, 256 * 1024) {
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

    private func readFrame(_ location: Location) throws -> (BatchV1, String) {
        guard location.length >= 4, location.length <= 32 * 1024 * 1024,
              location.kind == "segment" || location.kind == "state" else { throw AgentJournalError.invalidFrame }
        let url = location.kind == "segment" ? segmentURL(location.file) : stateURL(location.file)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: location.offset)
        guard let data = try handle.read(upToCount: Int(location.length)), data.count == location.length else {
            throw AgentJournalError.invalidFrame
        }
        counters.add(read: data.count)
        let length = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length + 4 == location.length else { throw AgentJournalError.invalidFrame }
        let frame = try JSONDecoder().decode(Frame.self, from: Data(data.dropFirst(4)))
        guard (frame.payload == nil) != (frame.blob == nil) else { throw AgentJournalError.invalidFrame }
        let payload = try frame.payload ?? readData(blobURL(frame.blob!))
        guard Self.digest(payload) == frame.digest else { throw AgentJournalError.checksumMismatch }
        let batch = try JSONDecoder().decode(BatchV1.self, from: payload)
        counters.add(decoded: 1)
        guard batch.schema == 1 else { throw AgentJournalError.invalidRecord }
        return (batch, frame.digest)
    }

    private func load(_ location: Location) throws -> BatchV1 { try readFrame(location).0 }
    private func frameDigest(_ location: Location) throws -> String { try readFrame(location).1 }

    private func pointer<Value: Codable>(_ kind: String, key: String, root: Root) throws -> Value? {
        let url = indexURL(kind, key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let index: Index<Value> = try loadIndex(url)
        for slot in [index.current, index.previous].compactMap({ $0 }) {
            guard slot.key == key else { throw AgentJournalError.invalidRecord }
            let published = slot.version <= root.sequence &&
                (kind != "positions" || ((slot.value as? Location)?.generation ?? UInt64.max) <= root.layoutGeneration)
            if published { return slot.value }
        }
        return nil
    }

    private func updateIndex<Value: Codable>(_ kind: String, key: String, value: Value,
                                              version: UInt64, root: Root) throws {
        let url = indexURL(kind, key)
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
        let previous = [old?.current, old?.previous].compactMap { $0 }.first { slot in
            slot.key == key && slot.version <= root.sequence &&
                (kind != "positions" || ((slot.value as? Location)?.generation ?? UInt64.max) <= root.layoutGeneration)
        }
        if let old, old.current.key != key { throw AgentJournalError.invalidRecord }
        let index = Index(current: Slot(key: key, version: version, value: value), previous: previous)
        let bytes = try JSONEncoder().encode(index)
        try atomicWrite(JSONEncoder().encode(IndexEnvelope(storeID: storeID,
            digest: Self.digest(bytes), payload: bytes)), at: url)
    }

    private func loadIndex<Value: Codable>(_ url: URL) throws -> Index<Value> {
        let wrapped = try JSONDecoder().decode(IndexEnvelope.self, from: readData(url))
        guard wrapped.storeID == storeID,
              Self.digest(wrapped.payload) == wrapped.digest else { throw AgentJournalError.checksumMismatch }
        return try JSONDecoder().decode(Index<Value>.self, from: wrapped.payload)
    }

    private func location(_ sequence: UInt64, root: Root) throws -> Location {
        guard sequence > 0, sequence <= root.sequence,
              let location: Location = try pointer("positions", key: String(sequence), root: root) else {
            throw AgentJournalError.invalidRecord
        }
        return location
    }

    private func append(_ data: Data, to root: Root) throws -> Location {
        try fault?(.beforeAppend)
        let url = segmentURL(root.active)
        guard try Self.fileSize(url) == root.activeEnd else {
            throw AgentJournalError.persistenceUnavailable("active segment length changed outside the owner")
        }
        let fd = DarwinOrGlibcOpen(url.path, O_WRONLY | O_APPEND, 0)
        guard fd >= 0 else { throw Self.ioError("open active segment") }
        defer { _ = DarwinOrGlibcClose(fd) }
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
                        length: UInt32(data.count), generation: root.layoutGeneration)
    }

    private func rotateIfNeeded(_ root: Root) throws {
        guard root.activeEnd >= policy.segmentBytes || root.activeBatches >= policy.maxSegmentBatches else { return }
        try fault?(.beforeRotation)
        let oldLayout = try layout(root)
        let nextSegment = UUID(), nextLayoutID = UUID()
        try writeNew(Data(), at: segmentURL(nextSegment))
        let nextLayout = Layout(generation: root.layoutGeneration + 1,
                                sealed: oldLayout.sealed + [Segment(id: root.active, end: root.activeEnd)],
                                packs: oldLayout.packs, garbage: oldLayout.garbage)
        let nextLayoutBytes = try JSONEncoder().encode(nextLayout)
        try writeNew(nextLayoutBytes, at: layoutURL(nextLayoutID))
        let nextRoot = Root(storeID: storeID, sequence: root.sequence,
                            nextRecordSequence: root.nextRecordSequence, active: nextSegment,
                            activeEnd: 0, activeBatches: 0, layout: nextLayoutID,
                            layoutDigest: Self.digest(nextLayoutBytes),
                            layoutGeneration: nextLayout.generation,
                            lastFrame: root.lastFrame, lastDigest: root.lastDigest)
        let (_, oldRootID) = try currentRoot()
        try publishRoot(nextRoot, id: UUID())
        try? FileManager.default.removeItem(at: rootURL(oldRootID))
        try? FileManager.default.removeItem(at: layoutURL(root.layout))
    }

    func maintain() async throws -> JournalMaintenanceStatus {
        try await withCheckedThrowingContinuation { continuation in
            maintenanceQueue.async { [self] in
                do { continuation.resume(returning: try performMaintenance()) }
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
        struct Candidate {
            let segment: Segment
            let rootSequence: UInt64
            let data: Data
            let offsets: [(UInt64, UInt64, UInt32)]
            let discarded: [UInt64]
        }
        // Pin one sealed segment by owning the only maintenance candidate.
        // Foreground commits can proceed while immutable bytes are copied.
        let snapshot: (Root, Segment)?
        lock.lock()
        do {
            guard !closed, !poisoned else {
                throw AgentJournalError.persistenceUnavailable("store is closed or requires recovery")
            }
            let (root, _) = try currentRoot()
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
            let file = try FileHandle(forReadingFrom: segmentURL(segment.id))
            defer { try? file.close() }
            var sourceOffset: UInt64 = 0
            var packed = Data()
            var positions: [(UInt64, UInt64, UInt32)] = []
            var discarded: [UInt64] = []
            while sourceOffset < segment.end {
                try Task.checkCancellation()
                try file.seek(toOffset: sourceOffset)
                guard let header = try file.read(upToCount: 4), header.count == 4 else {
                    throw AgentJournalError.invalidFrame
                }
                let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard size > 0, size < 32 * 1024 * 1024,
                      sourceOffset + UInt64(size) + 4 <= segment.end else {
                    throw AgentJournalError.invalidFrame
                }
                let source = Location(kind: "segment", file: segment.id, offset: sourceOffset,
                                      length: size + 4, generation: root.layoutGeneration)
                let batch = try load(source)
                let sessionHead: UInt64? = try pointer("sessions", key: batch.sessionID.uuidString, root: root)
                let callHead: UInt64?
                if let mutation = batch.mutation {
                    let key = "\(mutation.sessionID.uuidString)/\(mutation.runID.uuidString)/\(mutation.intent.call.id)"
                    callHead = try pointer("calls", key: key, root: root)
                } else { callHead = nil }
                let isLast = root.lastFrame?.file == segment.id && root.lastFrame?.offset == sourceOffset
                if !batch.messages.isEmpty || sessionHead == batch.sequence || callHead == batch.sequence || isLast {
                    try file.seek(toOffset: sourceOffset)
                    guard let bytes = try file.read(upToCount: Int(size + 4)), bytes.count == size + 4 else {
                        throw AgentJournalError.invalidFrame
                    }
                    positions.append((batch.sequence, UInt64(packed.count), size + 4))
                    packed.append(bytes)
                } else { discarded.append(batch.sequence) }
                sourceOffset += UInt64(size) + 4
            }
            candidate = Candidate(segment: segment, rootSequence: root.sequence,
                                  data: packed, offsets: positions, discarded: discarded)
        } else { candidate = nil }

        guard let candidate else {
            try cleanupGarbage()
            try cleanupManagedOrphans()
            return try maintenanceStatus()
        }
        try Task.checkCancellation()
        let packID = UUID()
        try writeNew(candidate.data, at: stateURL(packID))
        lock.lock()
        defer { lock.unlock() }
        do {
            let (root, oldRootID) = try currentRoot()
            let currentLayout = try layout(root)
            guard currentLayout.sealed.contains(where: { $0.id == candidate.segment.id }),
                  root.sequence >= candidate.rootSequence else {
                try? FileManager.default.removeItem(at: stateURL(packID))
                throw AgentJournalError.concurrentWriter
            }
            try Task.checkCancellation()
            let generation = root.layoutGeneration + 1
            var relocatedLast = root.lastFrame
            for (sequence, offset, length) in candidate.offsets {
                let old = try location(sequence, root: root)
                guard old.kind == "segment", old.file == candidate.segment.id else {
                    throw AgentJournalError.concurrentWriter
                }
                let new = Location(kind: "state", file: packID, offset: offset,
                                   length: length, generation: generation)
                try updateIndex("positions", key: String(sequence), value: new,
                                version: root.sequence, root: root)
                if root.lastFrame?.file == old.file && root.lastFrame?.offset == old.offset {
                    relocatedLast = new
                }
            }
            guard relocatedLast?.file != candidate.segment.id else { throw AgentJournalError.invalidRecord }
            let nextLayoutID = UUID()
            let nextLayout = Layout(generation: generation,
                                    sealed: currentLayout.sealed.filter { $0.id != candidate.segment.id },
                                    packs: currentLayout.packs + [packID],
                                    garbage: currentLayout.garbage + [candidate.segment])
            let nextLayoutBytes = try JSONEncoder().encode(nextLayout)
            try writeNew(nextLayoutBytes, at: layoutURL(nextLayoutID))
            let updated = Root(storeID: root.storeID, sequence: root.sequence,
                               nextRecordSequence: root.nextRecordSequence,
                               active: root.active, activeEnd: root.activeEnd,
                               activeBatches: root.activeBatches,
                               layout: nextLayoutID, layoutDigest: Self.digest(nextLayoutBytes),
                               layoutGeneration: generation,
                               lastFrame: relocatedLast, lastDigest: root.lastDigest)
            poisoned = true
            try fault?(.beforeMaintenancePublish)
            try publishRoot(updated, id: UUID())
            poisoned = false
            try? FileManager.default.removeItem(at: rootURL(oldRootID))
            try? FileManager.default.removeItem(at: layoutURL(root.layout))
            for sequence in candidate.discarded {
                let pointer: Location? = try pointer("positions", key: String(sequence), root: updated)
                if pointer?.kind == "segment" && pointer?.file == candidate.segment.id {
                    try FileManager.default.removeItem(at: indexURL("positions", String(sequence)))
                }
            }
            let oldSize = try Self.fileSize(segmentURL(candidate.segment.id))
            try fault?(.beforeSegmentDelete)
            try FileManager.default.removeItem(at: segmentURL(candidate.segment.id))
            reclaimed += oldSize
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
        guard let segment = oldLayout.garbage.first else { return }
        let url = segmentURL(segment.id)
        if FileManager.default.fileExists(atPath: url.path) {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var offset: UInt64 = 0
            while offset < segment.end {
                try file.seek(toOffset: offset)
                guard let header = try file.read(upToCount: 4), header.count == 4 else { throw AgentJournalError.invalidFrame }
                let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } + 4
                guard length > 4, offset + UInt64(length) <= segment.end else { throw AgentJournalError.invalidFrame }
                let batch = try load(Location(kind: "segment", file: segment.id, offset: offset,
                                              length: length, generation: root.layoutGeneration))
                let active: Location? = try pointer("positions", key: String(batch.sequence), root: root)
                if active?.kind == "segment" && active?.file == segment.id {
                    try FileManager.default.removeItem(at: indexURL("positions", String(batch.sequence)))
                }
                offset += UInt64(length)
            }
            let bytes = try Self.fileSize(url)
            try FileManager.default.removeItem(at: url)
            reclaimed += bytes
        }
        let newID = UUID()
        let next = Layout(generation: root.layoutGeneration + 1, sealed: oldLayout.sealed,
                          packs: oldLayout.packs, garbage: Array(oldLayout.garbage.dropFirst()))
        let nextBytes = try JSONEncoder().encode(next)
        try writeNew(nextBytes, at: layoutURL(newID))
        let updated = Root(storeID: root.storeID, sequence: root.sequence,
                           nextRecordSequence: root.nextRecordSequence, active: root.active,
                           activeEnd: root.activeEnd, activeBatches: root.activeBatches, layout: newID,
                           layoutDigest: Self.digest(nextBytes),
                           layoutGeneration: next.generation, lastFrame: root.lastFrame,
                           lastDigest: root.lastDigest)
        poisoned = true
        try publishRoot(updated, id: UUID())
        poisoned = false
        try? FileManager.default.removeItem(at: rootURL(oldRootID))
        try? FileManager.default.removeItem(at: layoutURL(root.layout))
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
            ("state", "pack", Set(currentLayout.packs)),
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
            let published: UInt64? = try pointer("blob-index", key: id.uuidString, root: root)
            if published == nil {
                try manager.removeItem(at: url)
                let index = indexURL("blob-index", id.uuidString)
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
        let kinds = ["sessions", "operations", "calls", "messages", "positions", "blob-index"]
        for kind in kinds {
            if finishedIndexKinds.contains(kind) { continue }
            let directory = directoryURL.appendingPathComponent("\(kind)/\(shard)")
            let (files, finished) = try nextManagedEntries(in: directory,
                key: "index-\(kind)-\(shard)", limit: 8)
            for url in files {
                guard url.pathExtension == "json",
                      url.deletingPathExtension().lastPathComponent.hasPrefix(storeID.uuidString + "_"),
                      try managedRegularFile(url) else { continue }
                let slots: (String, UInt64, UInt64?, String?, UInt64?, UInt64?)
                switch kind {
                case "messages":
                    let index: Index<MessagePointer> = try loadIndex(url)
                    slots = (index.current.key, index.current.version, nil,
                             index.previous?.key, index.previous?.version, nil)
                case "positions":
                    let index: Index<Location> = try loadIndex(url)
                    slots = (index.current.key, index.current.version, index.current.value.generation,
                             index.previous?.key, index.previous?.version, index.previous?.value.generation)
                default:
                    let index: Index<UInt64> = try loadIndex(url)
                    slots = (index.current.key, index.current.version, nil,
                             index.previous?.key, index.previous?.version, nil)
                }
                guard url.deletingPathExtension().lastPathComponent ==
                    "\(storeID.uuidString)_\(Self.digest(Data(slots.0.utf8)))",
                      slots.3 == nil || slots.3 == slots.0 else { throw AgentJournalError.invalidRecord }
                let currentPublished = slots.1 <= root.sequence && (slots.2 ?? 0) <= root.layoutGeneration
                let previousPublished = slots.4.map { $0 <= root.sequence && (slots.5 ?? 0) <= root.layoutGeneration } ?? false
                if !currentPublished && !previousPublished {
                    try FileManager.default.removeItem(at: url)
                }
            }
            if finished { finishedIndexKinds.insert(kind) }
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

        private func batch(_ sequence: UInt64) throws -> BatchV1 {
            let batch = try store.load(store.location(sequence, root: root))
            guard batch.sequence == sequence else { throw AgentJournalError.invalidRecord }
            return batch
        }

        func header(_ id: UUID) throws -> JournalSessionHeader? {
            guard let sequence: UInt64 = try store.pointer("sessions", key: id.uuidString, root: root) else { return nil }
            let found = try batch(sequence)
            guard found.sessionID == id else { throw AgentJournalError.invalidRecord }
            return found.header.value()
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
            try indexedMutation("operations", key: key)
        }

        func mutation(sessionID: UUID, runID: UUID, callID: ToolCallID) throws -> JournalStoredMutation? {
            try indexedMutation("calls", key: Self.callKey(sessionID, runID, callID))
        }

        private static func callKey(_ sessionID: UUID, _ runID: UUID, _ callID: ToolCallID) -> String {
            "\(sessionID.uuidString)/\(runID.uuidString)/\(callID.rawValue)"
        }

        private func indexedMutation(_ kind: String, key: String) throws -> JournalStoredMutation? {
            guard let sequence: UInt64 = try store.pointer(kind, key: key, root: root) else { return nil }
            guard let mutation = try batch(sequence).mutation?.value() else { throw AgentJournalError.invalidRecord }
            let actual = kind == "operations" ? mutation.intent.idempotencyKey
                : Self.callKey(mutation.sessionID, mutation.runID, mutation.intent.call.id)
            guard actual == key else { throw AgentJournalError.invalidRecord }
            return mutation
        }

        func pending(sessionID: UUID?) throws -> [JournalStoredMutation] {
            let sessions: [UUID]
            if let sessionID { sessions = [sessionID] }
            else {
                let shards = try FileManager.default.contentsOfDirectory(
                    at: store.directoryURL.appendingPathComponent("sessions"), includingPropertiesForKeys: nil
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

        func nextRecordSequence() throws -> UInt64 { root.nextRecordSequence }

        func messages(sessionID: UUID, after ordinal: UInt64, limit: Int) throws -> [JournalMessage] {
            try store.fault?(.beforeSessionRead)
            guard (1...1000).contains(limit) else { throw AgentJournalError.invalidRecord }
            guard let header = try header(sessionID), ordinal < header.messageCount else { return [] }
            var result: [JournalMessage] = []
            var cachedSequence: UInt64?
            var cached: BatchV1?
            for index in ordinal..<min(header.messageCount, ordinal + UInt64(limit)) {
                let key = "\(sessionID.uuidString)/\(index)"
                guard let pointer: MessagePointer = try store.pointer("messages", key: key, root: root) else {
                    throw AgentJournalError.invalidRecord
                }
                if pointer.sequence != cachedSequence {
                    cached = try batch(pointer.sequence)
                    cachedSequence = pointer.sequence
                }
                guard let cached, cached.sessionID == sessionID,
                      cached.messages.indices.contains(pointer.offset) else { throw AgentJournalError.invalidRecord }
                result.append(try cached.messages[pointer.offset].value())
            }
            return result
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
                  change.header.messageCount == (try header(change.sessionID)?.messageCount ?? 0) + UInt64(change.messages.count) else {
                throw AgentJournalError.concurrentWriter
            }
            let hasCheckpoint = change.records.contains { if case .checkpoint = $0.event { return true }; return false }
            guard hasCheckpoint || change.messages.isEmpty else { throw AgentJournalError.invalidRecord }
            let next = root.sequence + 1
            let oldHistoryHead = try header(change.sessionID)?.historyHead
            var finalHeader = change.header
            finalHeader.historyHead = hasCheckpoint ? next : oldHistoryHead
            let batch = BatchV1(schema: 1, commitID: UUID(), sequence: next,
                                sessionID: change.sessionID, header: DiskHeaderV1(finalHeader),
                                historyParent: hasCheckpoint ? oldHistoryHead : nil,
                                messages: change.messages.map(DiskMessageV1.init),
                                mutation: try change.mutation.map(DiskMutationV1.init),
                                recordCount: UInt32(change.records.count))
            let (bytes, digest, blob) = try store.frameBytes(batch)
            // From the first write onward, a failure has a potentially
            // published result. Reopen and inspect the root before retrying.
            store.poisoned = true
            let location = try store.append(bytes, to: root)
            try store.updateIndex("positions", key: String(next), value: location,
                                  version: next, root: root)
            try store.updateIndex("sessions", key: change.sessionID.uuidString, value: next,
                                  version: next, root: root)
            let firstOrdinal = finalHeader.messageCount - UInt64(change.messages.count)
            for offset in change.messages.indices {
                let key = "\(change.sessionID.uuidString)/\(firstOrdinal + UInt64(offset))"
                try store.updateIndex("messages", key: key,
                                      value: MessagePointer(sequence: next, offset: offset),
                                      version: next, root: root)
            }
            if let mutation = change.mutation {
                try store.updateIndex("operations", key: mutation.intent.idempotencyKey, value: next,
                                      version: next, root: root)
                try store.updateIndex("calls", key: Self.callKey(mutation.sessionID, mutation.runID, mutation.intent.call.id),
                                      value: next, version: next, root: root)
            }
            if let blob {
                try store.updateIndex("blob-index", key: blob.uuidString, value: next,
                                      version: next, root: root)
            }
            try store.fault?(.afterIndexSync)
            let updated = Root(storeID: root.storeID, sequence: next,
                               nextRecordSequence: root.nextRecordSequence + UInt64(change.records.count),
                               active: root.active, activeEnd: root.activeEnd + UInt64(bytes.count),
                               activeBatches: root.activeBatches + 1,
                               layout: root.layout, layoutDigest: root.layoutDigest,
                               layoutGeneration: root.layoutGeneration,
                               lastFrame: location, lastDigest: digest)
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
