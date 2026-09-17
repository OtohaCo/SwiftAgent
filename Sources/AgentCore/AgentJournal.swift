import AgentModels
import AgentTools
import Foundation

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
              !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
        try ToolResource.validate(resources)
    }
}

public struct AgentJournalRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

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

public enum AgentJournalDurability: Sendable {
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
    case persistenceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader: "Agent journal header is invalid."
        case .invalidFrame: "Agent journal frame is invalid."
        case .invalidRecord: "Agent journal record is invalid."
        case .checksumMismatch: "Agent journal checksum verification failed."
        case .concurrentWriter: "Agent journal changed outside this instance."
        case .invalidMutationIntent: "Mutation intent is incomplete or invalid."
        case .persistenceUnavailable(let message): "Agent journal persistence is unavailable: \(message)"
        }
    }
}

/// A single-writer, typed append-only journal. Durable frames are fsync'ed before memory is advanced.
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

    private var records: [AgentJournalRecord]
    private var nextSequence: UInt64
    private var persistenceURL: URL?
    private var recoveryState: AgentJournalRecovery

    public init() {
        records = []
        nextSequence = 1
        persistenceURL = nil
        recoveryState = .clean
    }

    /// Opens an existing journal or prepares a new journal at the supplied URL.
    public init(persistenceURL: URL) throws {
        let loaded = try Self.read(from: persistenceURL)
        records = loaded.records
        nextSequence = (loaded.records.last?.sequence ?? 0) + 1
        self.persistenceURL = persistenceURL
        recoveryState = loaded.recovery
    }

    public static func load(from url: URL) throws -> AgentJournal {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentJournalError.persistenceUnavailable("journal file does not exist")
        }
        return try AgentJournal(persistenceURL: url)
    }

    public func snapshot() -> [AgentJournalRecord] { records }

    public var recovery: AgentJournalRecovery { recoveryState }

    @discardableResult
    public func append(
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
    public func appendCheckpoint(
        _ events: [AgentJournalEvent],
        sessionID: UUID,
        runID: UUID? = nil,
        timestamp: Date = Date(),
        durability: AgentJournalDurability = .memory
    ) throws -> [AgentJournalRecord] {
        guard !events.isEmpty else { return [] }
        for event in events {
            if case .pendingMutation(let intent) = event { try intent.validate() }
        }
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
        return committed
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
            guard frame.schemaVersion == AgentJournalRecord.schemaVersion,
                  !frame.records.isEmpty,
                  frame.records.allSatisfy({ $0.checkpointID == frame.records[0].checkpointID }) else {
                throw AgentJournalError.invalidRecord
            }
            for record in frame.records {
                guard record.schemaVersion == AgentJournalRecord.schemaVersion,
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
        } catch {
            throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(5)
        while true {
            do {
                try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
                break
            } catch {
                guard FileManager.default.fileExists(atPath: lockURL.path) else {
                    throw AgentJournalError.persistenceUnavailable(error.localizedDescription)
                }
                guard Date() < deadline else {
                    throw AgentJournalError.persistenceUnavailable("journal lock is busy")
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        defer { try? FileManager.default.removeItem(at: lockURL) }
        return try body()
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
