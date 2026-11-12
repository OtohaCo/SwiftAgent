import AgentCore
import AgentModels
import AgentTools
import Crypto
import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum DarwinOrPosix {
    static func openFD(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.open(path, flags, mode)
        #else
        return Glibc.open(path, flags, mode)
        #endif
    }

    static func closeFD(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(fd)
        #else
        return Glibc.close(fd)
        #endif
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension AgentJournalSQLiteStore {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AgentJournalError.invalidRecord
        }
    }

    static func acquireExclusiveLock(
        at lockURL: URL,
        retry: (@Sendable () throws -> Void)?
    ) throws -> Int32 {
        let fd = DarwinOrPosix.openFD(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw AgentJournalError.persistenceUnavailable("unable to open writer lock file")
        }
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return fd
            }
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                if let retry {
                    do {
                        try retry()
                        continue
                    } catch {
                        _ = DarwinOrPosix.closeFD(fd)
                        throw error
                    }
                }
                _ = DarwinOrPosix.closeFD(fd)
                throw AgentJournalError.storeInUse
            }
            _ = DarwinOrPosix.closeFD(fd)
            throw AgentJournalError.persistenceUnavailable("writer lock failed: errno \(code)")
        }
    }

    static func openConnection(
        at dbURL: URL,
        readOnly: Bool,
        durability: SQLiteJournalDurability
    ) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_EXRESCODE)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_EXRESCODE)
        let rc = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let db = handle else {
            if let db = handle { sqlite3_close_v2(db) }
            throw AgentJournalError.persistenceUnavailable("sqlite open failed: \(rc)")
        }
        sqlite3_busy_timeout(db, 5_000)
        do {
            if !readOnly {
                #if canImport(Darwin)
                if durability == .appleFullFsync {
                    try exec(on: db, "PRAGMA fullfsync = ON;")
                    try exec(on: db, "PRAGMA checkpoint_fullfsync = ON;")
                }
                #endif
                try exec(on: db, "PRAGMA journal_mode = WAL;")
                try exec(on: db, "PRAGMA synchronous = FULL;")
                try exec(on: db, "PRAGMA foreign_keys = ON;")
            } else {
                try exec(on: db, "PRAGMA query_only = ON;")
            }
            return db
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
    }

    static func initializeSchema(on db: OpaquePointer) throws {
        let ddl = """
        CREATE TABLE IF NOT EXISTS store_meta (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            magic TEXT NOT NULL,
            schema_version INTEGER NOT NULL,
            store_id TEXT NOT NULL,
            domain TEXT NOT NULL,
            capabilities_json BLOB NOT NULL,
            logical_sequence INTEGER NOT NULL,
            next_record_sequence INTEGER NOT NULL,
            layout_generation INTEGER NOT NULL,
            audit_high_water INTEGER NOT NULL,
            digest TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
            session_id TEXT PRIMARY KEY,
            revision INTEGER NOT NULL,
            header_json BLOB NOT NULL,
            digest TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS session_messages (
            session_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            message_id TEXT NOT NULL,
            message_json BLOB NOT NULL,
            digest TEXT NOT NULL,
            PRIMARY KEY (session_id, ordinal)
        );
        CREATE TABLE IF NOT EXISTS images (
            digest TEXT PRIMARY KEY,
            media_type TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            data BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS mutations (
            idempotency_key TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            call_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            state TEXT NOT NULL,
            operation_id TEXT,
            mutation_json BLOB NOT NULL,
            digest TEXT NOT NULL,
            UNIQUE (session_id, run_id, call_id)
        );
        CREATE INDEX IF NOT EXISTS idx_mutations_pending ON mutations (state, sequence);
        CREATE INDEX IF NOT EXISTS idx_mutations_operation ON mutations (operation_id);
        CREATE TABLE IF NOT EXISTS admission_rejections (
            session_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            call_id TEXT NOT NULL,
            tool_name TEXT NOT NULL,
            digest TEXT NOT NULL,
            PRIMARY KEY (session_id, run_id, call_id)
        );
        CREATE TABLE IF NOT EXISTS followup_heads (
            session_id TEXT PRIMARY KEY,
            revision INTEGER NOT NULL,
            head_json BLOB NOT NULL,
            digest TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS followups (
            session_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            input_id TEXT NOT NULL,
            next_queued INTEGER,
            followup_json BLOB NOT NULL,
            digest TEXT NOT NULL,
            PRIMARY KEY (session_id, ordinal),
            UNIQUE (session_id, input_id)
        );
        CREATE TABLE IF NOT EXISTS run_records (
            session_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            correlation_key TEXT,
            formal_ordinal INTEGER NOT NULL,
            payload_fingerprint TEXT NOT NULL,
            run_json BLOB NOT NULL,
            terminal_json BLOB,
            digest TEXT NOT NULL,
            PRIMARY KEY (session_id, run_id)
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_run_correlations
            ON run_records (session_id, correlation_key)
            WHERE correlation_key IS NOT NULL;
        CREATE TABLE IF NOT EXISTS audit_records (
            sequence INTEGER PRIMARY KEY,
            record_json BLOB NOT NULL,
            digest TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS audit_groups (
            group_key TEXT PRIMARY KEY,
            member_count INTEGER NOT NULL,
            last_sequence INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS audit_members (
            group_key TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            audit_sequence INTEGER NOT NULL,
            PRIMARY KEY (group_key, ordinal)
        );
        CREATE TABLE IF NOT EXISTS audit_exports (
            configuration_id TEXT PRIMARY KEY,
            through_sequence INTEGER NOT NULL,
            checkpoint_json BLOB NOT NULL,
            digest TEXT NOT NULL
        );
        """
        try exec(on: db, ddl)
    }

    static func computeMetaDigest(
        magic: String,
        schemaVersion: Int,
        storeID: UUID,
        domain: String,
        capabilitiesBytes: Data,
        logicalSequence: UInt64,
        nextRecordSequence: UInt64,
        layoutGeneration: UInt64,
        auditHighWater: UInt64
    ) -> String {
        var payload = Data("meta:\(magic):\(schemaVersion):\(storeID.uuidString):\(domain):\(logicalSequence):\(nextRecordSequence):\(layoutGeneration):\(auditHighWater):".utf8)
        payload.append(capabilitiesBytes)
        return sha256Hex(payload)
    }

    static func rowDigest(prefix: String, payload: Data) -> String {
        var bytes = Data(prefix.utf8)
        bytes.append(payload)
        return sha256Hex(bytes)
    }

    static func loadStoreIdentityAndCapabilities(
        on db: OpaquePointer
    ) throws -> (storeID: UUID, domain: String, capabilities: CapabilitiesRecord) {
        return try withPrepared(
            on: db,
            sql: """
            SELECT magic, schema_version, store_id, domain, capabilities_json,
                   logical_sequence, next_record_sequence, layout_generation, audit_high_water, digest
            FROM store_meta WHERE singleton = 1;
            """
        ) { stmt in
            guard try stepRow(stmt, on: db) else {
                throw AgentJournalError.invalidHeader
            }
            let rowMagic = columnText(stmt, 0)
            let version = Int(sqlite3_column_int64(stmt, 1))
            guard rowMagic == magic else {
                throw AgentJournalError.invalidHeader
            }
            guard version == supportedSchemaVersion else {
                throw AgentJournalError.unsupportedFormat
            }
            guard let id = UUID(uuidString: columnText(stmt, 2)) else {
                throw AgentJournalError.invalidHeader
            }
            let domain = columnText(stmt, 3)
            let capsBytes = columnBlob(stmt, 4)
            let logicalSeq = UInt64(bitPattern: sqlite3_column_int64(stmt, 5))
            let nextRecordSeq = UInt64(bitPattern: sqlite3_column_int64(stmt, 6))
            let layoutGen = UInt64(bitPattern: sqlite3_column_int64(stmt, 7))
            let auditHW = UInt64(bitPattern: sqlite3_column_int64(stmt, 8))
            let storedDigest = columnText(stmt, 9)
            let expectedDigest = computeMetaDigest(
                magic: rowMagic,
                schemaVersion: version,
                storeID: id,
                domain: domain,
                capabilitiesBytes: capsBytes,
                logicalSequence: logicalSeq,
                nextRecordSequence: nextRecordSeq,
                layoutGeneration: layoutGen,
                auditHighWater: auditHW
            )
            guard storedDigest == expectedDigest else {
                throw AgentJournalError.checksumMismatch
            }
            let caps = try decodeJSON(CapabilitiesRecord.self, from: capsBytes)
            return (id, domain, caps)
        }
    }

    func loadMetaState(on db: OpaquePointer) throws -> MetaState {
        try Self.withPrepared(
            on: db,
            sql: """
            SELECT magic, schema_version, store_id, domain, capabilities_json,
                   logical_sequence, next_record_sequence, layout_generation, audit_high_water, digest
            FROM store_meta WHERE singleton = 1;
            """
        ) { stmt in
            guard try Self.stepRow(stmt, on: db) else {
                throw AgentJournalError.invalidRecord
            }
            let rowMagic = Self.columnText(stmt, 0)
            let version = Int(sqlite3_column_int64(stmt, 1))
            let rowStoreID = Self.columnText(stmt, 2)
            let domain = Self.columnText(stmt, 3)
            let capsBytes = Self.columnBlob(stmt, 4)
            let logicalSeq = UInt64(bitPattern: sqlite3_column_int64(stmt, 5))
            let nextRecordSeq = UInt64(bitPattern: sqlite3_column_int64(stmt, 6))
            let layoutGen = UInt64(bitPattern: sqlite3_column_int64(stmt, 7))
            let auditHW = UInt64(bitPattern: sqlite3_column_int64(stmt, 8))
            let storedDigest = Self.columnText(stmt, 9)
            guard rowMagic == Self.magic, version == Self.supportedSchemaVersion,
                  rowStoreID == storeID.uuidString, domain == operationDomain else {
                throw AgentJournalError.invalidRecord
            }
            let expected = Self.computeMetaDigest(
                magic: rowMagic,
                schemaVersion: version,
                storeID: storeID,
                domain: operationDomain,
                capabilitiesBytes: capsBytes,
                logicalSequence: logicalSeq,
                nextRecordSequence: nextRecordSeq,
                layoutGeneration: layoutGen,
                auditHighWater: auditHW
            )
            guard storedDigest == expected else {
                throw AgentJournalError.checksumMismatch
            }
            return MetaState(
                logicalSequence: logicalSeq,
                nextRecordSequence: nextRecordSeq,
                layoutGeneration: layoutGen,
                auditHighWater: auditHW
            )
        }
    }

    func saveMetaState(_ state: MetaState, on db: OpaquePointer) throws {
        let capsBytes: Data = try Self.withPrepared(
            on: db,
            sql: "SELECT capabilities_json FROM store_meta WHERE singleton = 1;"
        ) { stmt in
            guard try Self.stepRow(stmt, on: db) else { throw AgentJournalError.invalidRecord }
            return Self.columnBlob(stmt, 0)
        }
        let digest = Self.computeMetaDigest(
            magic: Self.magic,
            schemaVersion: Self.supportedSchemaVersion,
            storeID: storeID,
            domain: operationDomain,
            capabilitiesBytes: capsBytes,
            logicalSequence: state.logicalSequence,
            nextRecordSequence: state.nextRecordSequence,
            layoutGeneration: state.layoutGeneration,
            auditHighWater: state.auditHighWater
        )
        try Self.withPrepared(
            on: db,
            sql: """
            UPDATE store_meta
            SET logical_sequence = ?, next_record_sequence = ?, layout_generation = ?, audit_high_water = ?, digest = ?
            WHERE singleton = 1;
            """
        ) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(bitPattern: state.logicalSequence))
            sqlite3_bind_int64(stmt, 2, Int64(bitPattern: state.nextRecordSequence))
            sqlite3_bind_int64(stmt, 3, Int64(bitPattern: state.layoutGeneration))
            sqlite3_bind_int64(stmt, 4, Int64(bitPattern: state.auditHighWater))
            Self.bindText(stmt, 5, digest)
            try Self.stepDone(stmt, on: db)
        }
    }

    func storeImage(_ image: ModelImage, on db: OpaquePointer) throws -> Int {
        guard supportsImageContent else { throw AgentJournalError.unsupportedFormat }
        guard Self.sha256Hex(image.data) == image.digest else {
            throw AgentJournalError.checksumMismatch
        }
        let exists = try Self.withPrepared(
            on: db,
            sql: "SELECT byte_count, data FROM images WHERE digest = ?;"
        ) { stmt in
            Self.bindText(stmt, 1, image.digest)
            guard try Self.stepRow(stmt, on: db) else { return false }
            let count = Int(sqlite3_column_int64(stmt, 0))
            let bytes = Self.columnBlob(stmt, 1)
            guard count == image.data.count, Self.sha256Hex(bytes) == image.digest else {
                throw AgentJournalError.checksumMismatch
            }
            return true
        }
        if exists { return 0 }
        try Self.withPrepared(
            on: db,
            sql: "INSERT INTO images (digest, media_type, byte_count, data) VALUES (?, ?, ?, ?);"
        ) { stmt in
            Self.bindText(stmt, 1, image.digest)
            Self.bindText(stmt, 2, image.mediaType.rawValue)
            sqlite3_bind_int64(stmt, 3, Int64(image.data.count))
            Self.bindBlob(stmt, 4, image.data)
            try Self.stepDone(stmt, on: db)
        }
        return image.data.count
    }

    func loadImage(_ reference: SQLiteImageRef, on db: OpaquePointer) throws -> ModelImage {
        guard supportsImageContent else { throw AgentJournalError.unsupportedFormat }
        guard let mediaType = ModelImage.MediaType(rawValue: reference.mediaType) else {
            throw AgentJournalError.invalidRecord
        }
        return try Self.withPrepared(
            on: db,
            sql: "SELECT byte_count, data FROM images WHERE digest = ?;"
        ) { stmt in
            Self.bindText(stmt, 1, reference.digest)
            guard try Self.stepRow(stmt, on: db) else {
                throw AgentJournalError.invalidRecord
            }
            let storedCount = Int(sqlite3_column_int64(stmt, 0))
            let data = Self.columnBlob(stmt, 1)
            noteReadBytes(data.count, decoded: 0)
            guard storedCount == reference.byteCount,
                  data.count == reference.byteCount,
                  Self.sha256Hex(data) == reference.digest else {
                throw AgentJournalError.checksumMismatch
            }
            do {
                return try ModelImage(
                    data: data,
                    mediaType: mediaType,
                    description: reference.description,
                    verifiedDigest: reference.digest
                )
            } catch {
                throw AgentJournalError.invalidRecord
            }
        }
    }

    // MARK: Low-level SQLite wrappers

    static func exec(on db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let detail = errorMessage.map { String(cString: $0) } ?? "rc=\(rc)"
            if let errorMessage { sqlite3_free(errorMessage) }
            if (rc & 0xff) == SQLITE_CORRUPT || (rc & 0xff) == SQLITE_NOTADB {
                throw AgentJournalError.checksumMismatch
            }
            throw AgentJournalError.persistenceUnavailable("sqlite exec failed: \(detail)")
        }
    }

    static func withPrepared<T>(
        on db: OpaquePointer,
        sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw sqliteError(on: db, context: "prepare", code: rc)
        }
        defer { sqlite3_finalize(prepared) }
        return try body(prepared)
    }

    static func stepRow(_ stmt: OpaquePointer, on db: OpaquePointer) throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw sqliteError(on: db, context: "step", code: rc)
    }

    static func stepDone(_ stmt: OpaquePointer, on db: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw sqliteError(on: db, context: "stepDone", code: rc)
        }
    }

    static func sqliteError(on db: OpaquePointer, context: String, code: Int32? = nil) -> AgentJournalError {
        let rc = code ?? sqlite3_errcode(db)
        if (rc & 0xff) == SQLITE_CORRUPT || (rc & 0xff) == SQLITE_NOTADB {
            return .checksumMismatch
        }
        let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "rc=\(rc)"
        return .persistenceUnavailable("\(context): \(message)")
    }

    static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        _ = value.withCString { ptr in
            sqlite3_bind_text(stmt, index, ptr, -1, sqliteTransient)
        }
    }

    static func bindOptionalText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, !raw.isEmpty {
                _ = sqlite3_bind_blob(stmt, index, base, Int32(raw.count), sqliteTransient)
            } else {
                var empty: UInt8 = 0
                _ = sqlite3_bind_blob(stmt, index, &empty, 0, sqliteTransient)
            }
        }
    }

    static func bindOptionalBlob(_ stmt: OpaquePointer, _ index: Int32, _ data: Data?) {
        if let data {
            bindBlob(stmt, index, data)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: ptr)
    }

    static func columnOptionalText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    static func columnBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0, let ptr = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: ptr, count: count)
    }

    static func columnOptionalBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return columnBlob(stmt, index)
    }
}

struct SQLiteImageRef: Codable, Equatable {
    let digest: String
    let mediaType: String
    let byteCount: Int
    let description: String
}

struct SQLiteContentEnvelope: Codable {
    let kind: String
    let text: String?
    let json: JSONValue?
    let continuation: ModelProviderContinuation?
    let image: SQLiteImageRef?
    let file: ModelFileReference?

    init(_ part: ModelContent) {
        switch part {
        case .text(let value):
            kind = "text"; text = value; json = nil; continuation = nil; image = nil; file = nil
        case .reasoning(let value):
            kind = "reasoning"; text = value; json = nil; continuation = nil; image = nil; file = nil
        case .json(let value):
            kind = "json"; text = nil; json = value; continuation = nil; image = nil; file = nil
        case .providerContinuation(let value):
            kind = "continuation"; text = nil; json = nil; continuation = value; image = nil; file = nil
        case .image(let value):
            kind = "image"; text = nil; json = nil; continuation = nil
            image = SQLiteImageRef(
                digest: value.digest,
                mediaType: value.mediaType.rawValue,
                byteCount: value.data.count,
                description: value.description
            )
            file = nil
        case .file(let value):
            kind = "file"; text = nil; json = nil; continuation = nil; image = nil; file = value
        }
    }

    func decode(loadImage: (SQLiteImageRef) throws -> ModelImage) throws -> ModelContent {
        switch kind {
        case "text":
            guard let text else { throw AgentJournalError.invalidRecord }
            return .text(text)
        case "reasoning":
            guard let text else { throw AgentJournalError.invalidRecord }
            return .reasoning(text)
        case "json":
            guard let json else { throw AgentJournalError.invalidRecord }
            return .json(json)
        case "continuation":
            guard let continuation else { throw AgentJournalError.invalidRecord }
            return .providerContinuation(continuation)
        case "image":
            guard let image else { throw AgentJournalError.invalidRecord }
            return .image(try loadImage(image))
        case "file":
            guard let file else { throw AgentJournalError.invalidRecord }
            return .file(file)
        default:
            throw AgentJournalError.unsupportedFormat
        }
    }
}

struct SQLiteToolResultEnvelope: Codable {
    let callID: ToolCallID
    let content: [SQLiteContentEnvelope]
    let isError: Bool

    init(_ result: ToolResultMessage) {
        callID = result.callID
        content = result.content.map(SQLiteContentEnvelope.init)
        isError = result.isError
    }

    func decode(loadImage: (SQLiteImageRef) throws -> ModelImage) throws -> ToolResultMessage {
        ToolResultMessage(
            callID: callID,
            content: try content.map { try $0.decode(loadImage: loadImage) },
            isError: isError
        )
    }
}

struct SQLiteMessageEnvelope: Codable {
    let role: String
    let instructions: String?
    let content: [SQLiteContentEnvelope]
    let toolCalls: [ToolCall]
    let toolResult: SQLiteToolResultEnvelope?

    init(_ message: ModelMessage) {
        switch message {
        case .system(let value):
            role = "system"; instructions = value; content = []; toolCalls = []; toolResult = nil
        case .developer(let value):
            role = "developer"; instructions = value; content = []; toolCalls = []; toolResult = nil
        case .user(let parts):
            role = "user"; instructions = nil; content = parts.map(SQLiteContentEnvelope.init); toolCalls = []; toolResult = nil
        case .assistant(let parts, let calls):
            role = "assistant"; instructions = nil; content = parts.map(SQLiteContentEnvelope.init); toolCalls = calls; toolResult = nil
        case .tool(let result):
            role = "tool"; instructions = nil; content = []; toolCalls = []; toolResult = SQLiteToolResultEnvelope(result)
        }
    }

    func decode(loadImage: (SQLiteImageRef) throws -> ModelImage) throws -> ModelMessage {
        switch role {
        case "system":
            guard let instructions else { throw AgentJournalError.invalidRecord }
            return .system(instructions)
        case "developer":
            guard let instructions else { throw AgentJournalError.invalidRecord }
            return .developer(instructions)
        case "user":
            return .user(try content.map { try $0.decode(loadImage: loadImage) })
        case "assistant":
            return .assistant(content: try content.map { try $0.decode(loadImage: loadImage) }, toolCalls: toolCalls)
        case "tool":
            guard let toolResult else { throw AgentJournalError.invalidRecord }
            return .tool(try toolResult.decode(loadImage: loadImage))
        default:
            throw AgentJournalError.unsupportedFormat
        }
    }
}
