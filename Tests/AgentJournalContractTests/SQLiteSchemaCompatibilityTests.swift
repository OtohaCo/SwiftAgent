@testable import AgentCore
@testable import AgentJournalSQLiteStore
import AgentModels
import AgentTools
import Foundation
import Testing
#if canImport(SQLite3)
import SQLite3
#else
import CAgentSQLite
#endif

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@Suite struct SQLiteSchemaCompatibilityTests {
    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("journal-sqlite-schema-\(label)-\(UUID())")
    }

    private struct SchemaV1Capabilities: Encodable {
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

    private struct SchemaV1ContentEnvelope: Encodable {
        let kind: String
        let text: String?
    }

    private struct SchemaV1MessageEnvelope: Encodable {
        let role: String
        let content: [SchemaV1ContentEnvelope]
        let toolCalls: [ToolCall]
    }

    private struct StoredCallIdentity: Equatable {
        let sessionID: String
        let runID: String
        let callID: String
    }

    private struct SchemaV1Fixture {
        let storeID: UUID
        let operationDomain: String
        let metaDigest: String
        let sessionA: UUID
        let sessionB: UUID
        let message0ID: UUID
        let message1ID: UUID
        let legacyHistory: [ModelMessage]
        let legacyRunA: UUID
        let legacyCallA: ToolCallID
        let legacyKeyA: String
        let targetA: EvidenceReference
        let expectationA: ToolReceiptExpectation
        let legacyRunB: UUID
        let legacyCallB: ToolCallID
        let legacyKeyB: String
        let targetB: EvidenceReference
        let expectationB: ToolReceiptExpectation
        let legacyConfirmationB: AgentNoEffectConfirmation
    }

    private static let schemaV1DDL = """
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

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func v1RowDigest(prefix: String, payload: Data) -> String {
        var bytes = Data(prefix.utf8)
        bytes.append(payload)
        return AgentJournalSQLiteStore.sha256Hex(bytes)
    }

    private static func v1MetaDigest(
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
        var payload = Data(
            "meta:\(magic):\(schemaVersion):\(storeID.uuidString):\(domain):\(logicalSequence):\(nextRecordSequence):\(layoutGeneration):\(auditHighWater):"
                .utf8
        )
        payload.append(capabilitiesBytes)
        return AgentJournalSQLiteStore.sha256Hex(payload)
    }

    private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        _ = value.withCString { ptr in
            sqlite3_bind_text(stmt, index, ptr, -1, sqliteTransientDestructor)
        }
    }

    private static func bindOptionalText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, !raw.isEmpty {
                _ = sqlite3_bind_blob(stmt, index, base, Int32(raw.count), sqliteTransientDestructor)
            } else {
                var empty: UInt8 = 0
                _ = sqlite3_bind_blob(stmt, index, &empty, 0, sqliteTransientDestructor)
            }
        }
    }

    private static func execSQL(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let detail = errorMessage.map { String(cString: $0) } ?? "rc=\(rc)"
            if let errorMessage { sqlite3_free(errorMessage) }
            throw AgentJournalError.persistenceUnavailable("fixture sqlite exec failed: \(detail)")
        }
    }

    private static func withPrepared(
        _ db: OpaquePointer,
        _ sql: String,
        _ body: (OpaquePointer) throws -> Void
    ) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw AgentJournalError.persistenceUnavailable("fixture prepare failed: \(rc)")
        }
        defer { sqlite3_finalize(prepared) }
        try body(prepared)
        let stepRC = sqlite3_step(prepared)
        guard stepRC == SQLITE_DONE else {
            throw AgentJournalError.persistenceUnavailable("fixture step failed: \(stepRC)")
        }
    }

    private static func withReadOnlyDB<T>(at directory: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let dbURL = directory.appendingPathComponent("journal.sqlite3")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw AgentJournalError.persistenceUnavailable("unable to open sqlite file for inspection")
        }
        defer { sqlite3_close_v2(db) }
        return try body(db)
    }

    private static func readStoreMetaVersionAndDigest(at directory: URL) throws -> (schemaVersion: Int, digest: String) {
        try withReadOnlyDB(at: directory) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT schema_version, digest FROM store_meta WHERE singleton = 1;", -1, &stmt, nil) == SQLITE_OK,
                  let prepared = stmt else {
                if let stmt { sqlite3_finalize(stmt) }
                throw AgentJournalError.persistenceUnavailable("unable to prepare store_meta query")
            }
            defer { sqlite3_finalize(prepared) }
            guard sqlite3_step(prepared) == SQLITE_ROW else {
                throw AgentJournalError.invalidHeader
            }
            let version = Int(sqlite3_column_int64(prepared, 0))
            let digest = sqlite3_column_text(prepared, 1).map { String(cString: $0) } ?? ""
            return (version, digest)
        }
    }

    private static func tableExists(_ name: String, at directory: URL) throws -> Bool {
        try withReadOnlyDB(at: directory) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;", -1, &stmt, nil) == SQLITE_OK,
                  let prepared = stmt else {
                if let stmt { sqlite3_finalize(stmt) }
                throw AgentJournalError.persistenceUnavailable("unable to prepare sqlite_master query")
            }
            defer { sqlite3_finalize(prepared) }
            bindText(prepared, 1, name)
            return sqlite3_step(prepared) == SQLITE_ROW
        }
    }

    private static func rowCount(table: String, at directory: URL) throws -> Int {
        try withReadOnlyDB(at: directory) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table);", -1, &stmt, nil) == SQLITE_OK,
                  let prepared = stmt else {
                if let stmt { sqlite3_finalize(stmt) }
                throw AgentJournalError.persistenceUnavailable("unable to prepare row count query for \(table)")
            }
            defer { sqlite3_finalize(prepared) }
            guard sqlite3_step(prepared) == SQLITE_ROW else {
                throw AgentJournalError.invalidRecord
            }
            return Int(sqlite3_column_int64(prepared, 0))
        }
    }

    private static func storedCalls(table: String, at directory: URL) throws -> [StoredCallIdentity] {
        try withReadOnlyDB(at: directory) { db in
            var stmt: OpaquePointer?
            let sql = "SELECT session_id, run_id, call_id FROM \(table) ORDER BY session_id, run_id, call_id;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
                if let stmt { sqlite3_finalize(stmt) }
                throw AgentJournalError.persistenceUnavailable("unable to prepare call query for \(table)")
            }
            defer { sqlite3_finalize(prepared) }
            var rows: [StoredCallIdentity] = []
            while sqlite3_step(prepared) == SQLITE_ROW {
                let sessionID = sqlite3_column_text(prepared, 0).map { String(cString: $0) } ?? ""
                let runID = sqlite3_column_text(prepared, 1).map { String(cString: $0) } ?? ""
                let callID = sqlite3_column_text(prepared, 2).map { String(cString: $0) } ?? ""
                rows.append(StoredCallIdentity(sessionID: sessionID, runID: runID, callID: callID))
            }
            return rows
        }
    }

    /// Constructs an authentic pre-change schema-v1 SQLite journal on disk directly using the v1 DDL
    /// (without `mutation_calls`) and row digests, without invoking the store's creation code.
    private static func createSchemaV1Database(at directory: URL) throws -> SchemaV1Fixture {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("journal.sqlite3")
        var handle: OpaquePointer?
        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(dbURL.path, &handle, openFlags, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw AgentJournalError.persistenceUnavailable("unable to create v1 fixture sqlite file")
        }
        defer {
            _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            sqlite3_close_v2(db)
        }

        try execSQL(db, "PRAGMA journal_mode = WAL;")
        try execSQL(db, "PRAGMA synchronous = FULL;")
        try execSQL(db, "PRAGMA foreign_keys = ON;")
        try execSQL(db, schemaV1DDL)

        let storeID = UUID()
        let domain = "schema-v1-compat"
        let sessionA = UUID()
        let sessionB = UUID()
        let message0ID = UUID()
        let message1ID = UUID()
        let legacyHistory: [ModelMessage] = [
            .user([.text("legacy-v1-prompt")]),
            .assistant(content: [.text("legacy-v1-reply")], toolCalls: []),
        ]

        let legacyRunA = UUID()
        let legacyCallA = ToolCallID(rawValue: "legacy-call-a")
        let targetA = EvidenceReference(namespace: "fixture", id: "legacy-target-a")
        let expectationA = try ToolReceiptExpectation(targets: [targetA], revision: .present)
        let legacyKeyA = "legacy-op-a/write/{\"id\":\"a\"}"
        let intentA = try PendingMutationIntent(
            call: ToolCall(id: legacyCallA, name: "write", argumentsJSON: #"{"id":"a"}"#, completeness: .complete),
            resources: [.named(targetA)],
            idempotencyKey: legacyKeyA,
            receiptExpectation: expectationA
        )
        let storedMutationA = JournalStoredMutation(
            sessionID: sessionA,
            runID: legacyRunA,
            intent: intentA,
            sequence: 3,
            state: .needsReconciliation
        )

        let legacyRunB = UUID()
        let legacyCallB = ToolCallID(rawValue: "legacy-call-b")
        let targetB = EvidenceReference(namespace: "fixture", id: "legacy-target-b")
        let expectationB = try ToolReceiptExpectation(targets: [targetB], revision: .present)
        let legacyKeyB = "legacy-op-b/write/{\"id\":\"b\"}"
        let legacyConfirmationB = try AgentNoEffectConfirmation(basis: "legacy host confirmed absent on target")
        let intentB = try PendingMutationIntent(
            call: ToolCall(id: legacyCallB, name: "write", argumentsJSON: #"{"id":"b"}"#, completeness: .complete),
            resources: [.named(targetB)],
            idempotencyKey: legacyKeyB,
            receiptExpectation: expectationB
        )
        let storedMutationB = JournalStoredMutation(
            sessionID: sessionB,
            runID: legacyRunB,
            intent: intentB,
            sequence: 4,
            state: .aborted,
            abortConfirmation: legacyConfirmationB
        )

        let capabilities = SchemaV1Capabilities(
            supportsAdmissionRejections: true,
            supportsAuthorizationAudit: true,
            supportsConfirmedNoEffect: true,
            noEffectProofVersion: 2,
            supportsPerCallFollowUps: true,
            supportsRunRecords: true,
            supportsImageContent: false,
            supportsFileContent: false,
            supportsNativeContext: false,
            supportsContextHandoff: false,
            supportsIncompleteContextHandoff: false
        )
        let capsBytes = try canonicalJSON(capabilities)
        let logicalSequence: UInt64 = 4
        let nextRecordSequence: UInt64 = 10
        let layoutGeneration: UInt64 = 0
        let auditHighWater: UInt64 = 0
        let metaDigest = v1MetaDigest(
            magic: "SWIFTAGENT-SQLITE-JOURNAL",
            schemaVersion: 1,
            storeID: storeID,
            domain: domain,
            capabilitiesBytes: capsBytes,
            logicalSequence: logicalSequence,
            nextRecordSequence: nextRecordSequence,
            layoutGeneration: layoutGeneration,
            auditHighWater: auditHighWater
        )

        try execSQL(db, "BEGIN IMMEDIATE TRANSACTION;")

        try withPrepared(
            db,
            """
            INSERT INTO store_meta (
                singleton, magic, schema_version, store_id, domain, capabilities_json,
                logical_sequence, next_record_sequence, layout_generation, audit_high_water, digest
            ) VALUES (1, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        ) { stmt in
            bindText(stmt, 1, "SWIFTAGENT-SQLITE-JOURNAL")
            bindText(stmt, 2, storeID.uuidString)
            bindText(stmt, 3, domain)
            bindBlob(stmt, 4, capsBytes)
            sqlite3_bind_int64(stmt, 5, Int64(bitPattern: logicalSequence))
            sqlite3_bind_int64(stmt, 6, Int64(bitPattern: nextRecordSequence))
            sqlite3_bind_int64(stmt, 7, Int64(bitPattern: layoutGeneration))
            sqlite3_bind_int64(stmt, 8, Int64(bitPattern: auditHighWater))
            bindText(stmt, 9, metaDigest)
        }

        // Insert sessionA header and messages.
        let headerA = JournalSessionHeader(
            revision: 2,
            created: true,
            lastRunID: legacyRunA,
            steeringIDs: [],
            historyHead: 1,
            messageCount: 2,
            pendingIdentity: legacyKeyA
        )
        let headerABytes = try canonicalJSON(headerA)
        let headerADigest = v1RowDigest(
            prefix: "session:\(storeID.uuidString):\(sessionA.uuidString):2:",
            payload: headerABytes
        )
        try withPrepared(
            db,
            "INSERT INTO sessions (session_id, revision, header_json, digest) VALUES (?, 2, ?, ?);"
        ) { stmt in
            bindText(stmt, 1, sessionA.uuidString)
            bindBlob(stmt, 2, headerABytes)
            bindText(stmt, 3, headerADigest)
        }

        let legacyEnvelopes: [(UInt64, UUID, SchemaV1MessageEnvelope)] = [
            (0, message0ID, SchemaV1MessageEnvelope(role: "user", content: [.init(kind: "text", text: "legacy-v1-prompt")], toolCalls: [])),
            (1, message1ID, SchemaV1MessageEnvelope(role: "assistant", content: [.init(kind: "text", text: "legacy-v1-reply")], toolCalls: [])),
        ]
        for (ordinal, msgID, envelope) in legacyEnvelopes {
            let msgBytes = try canonicalJSON(envelope)
            let msgDigest = v1RowDigest(
                prefix: "msg:\(storeID.uuidString):\(sessionA.uuidString):\(ordinal):\(msgID.uuidString):",
                payload: msgBytes
            )
            try withPrepared(
                db,
                "INSERT INTO session_messages (session_id, ordinal, message_id, message_json, digest) VALUES (?, ?, ?, ?, ?);"
            ) { stmt in
                bindText(stmt, 1, sessionA.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(bitPattern: ordinal))
                bindText(stmt, 3, msgID.uuidString)
                bindBlob(stmt, 4, msgBytes)
                bindText(stmt, 5, msgDigest)
            }
        }

        // Insert sessionB header (no pending mutation; its legacy mutation is already aborted).
        let headerB = JournalSessionHeader(
            revision: 1,
            created: true,
            lastRunID: legacyRunB,
            steeringIDs: [],
            historyHead: nil,
            messageCount: 0,
            pendingIdentity: nil
        )
        let headerBBytes = try canonicalJSON(headerB)
        let headerBDigest = v1RowDigest(
            prefix: "session:\(storeID.uuidString):\(sessionB.uuidString):1:",
            payload: headerBBytes
        )
        try withPrepared(
            db,
            "INSERT INTO sessions (session_id, revision, header_json, digest) VALUES (?, 1, ?, ?);"
        ) { stmt in
            bindText(stmt, 1, sessionB.uuidString)
            bindBlob(stmt, 2, headerBBytes)
            bindText(stmt, 3, headerBDigest)
        }

        // Insert both legacy mutations into the v1 mutations table.
        let opKeyA = "operation/\(Data("legacy-op-a".utf8).base64EncodedString())"
        let opKeyB = "operation/\(Data("legacy-op-b".utf8).base64EncodedString())"
        for (mutation, opKey) in [(storedMutationA, opKeyA), (storedMutationB, opKeyB)] {
            let mutBytes = try canonicalJSON(mutation)
            let mutDigest = v1RowDigest(
                prefix: "mutation:\(storeID.uuidString):\(mutation.intent.idempotencyKey):",
                payload: mutBytes
            )
            try withPrepared(
                db,
                """
                INSERT INTO mutations (
                    idempotency_key, session_id, run_id, call_id, sequence, state, operation_id, mutation_json, digest
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            ) { stmt in
                bindText(stmt, 1, mutation.intent.idempotencyKey)
                bindText(stmt, 2, mutation.sessionID.uuidString)
                bindText(stmt, 3, mutation.runID.uuidString)
                bindText(stmt, 4, mutation.intent.call.id.rawValue)
                sqlite3_bind_int64(stmt, 5, Int64(bitPattern: mutation.sequence))
                bindText(stmt, 6, mutation.state.rawValue)
                bindOptionalText(stmt, 7, opKey)
                bindBlob(stmt, 8, mutBytes)
                bindText(stmt, 9, mutDigest)
            }
        }

        try execSQL(db, "COMMIT;")

        return SchemaV1Fixture(
            storeID: storeID,
            operationDomain: domain,
            metaDigest: metaDigest,
            sessionA: sessionA,
            sessionB: sessionB,
            message0ID: message0ID,
            message1ID: message1ID,
            legacyHistory: legacyHistory,
            legacyRunA: legacyRunA,
            legacyCallA: legacyCallA,
            legacyKeyA: legacyKeyA,
            targetA: targetA,
            expectationA: expectationA,
            legacyRunB: legacyRunB,
            legacyCallB: legacyCallB,
            legacyKeyB: legacyKeyB,
            targetB: targetB,
            expectationB: expectationB,
            legacyConfirmationB: legacyConfirmationB
        )
    }

    @Test func preChangeSchemaV1StoreOpensAtVersion1WithoutMutatingMetaAndPreservesRetriedMutations() async throws {
        let directory = tempDir("v1-compat")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try Self.createSchemaV1Database(at: directory)

        #expect(try Self.readStoreMetaVersionAndDigest(at: directory) == (1, fixture.metaDigest))
        #expect(try !Self.tableExists("mutation_calls", at: directory))

        let journal = try AgentSQLiteJournal.open(at: directory)
        // Opening a pre-change v1 store keeps schema_version == 1, leaves store_meta untouched, and does no backfill.
        #expect(try Self.readStoreMetaVersionAndDigest(at: directory) == (1, fixture.metaDigest))
        #expect(try Self.tableExists("mutation_calls", at: directory))
        #expect(try Self.rowCount(table: "mutation_calls", at: directory) == 0)
        #expect(try Self.rowCount(table: "mutations", at: directory) == 2)

        let identity = try #require(await journal.storeIdentity())
        #expect(identity == JournalStoreIdentity(storeID: fixture.storeID, operationDomain: fixture.operationDomain))
        #expect(journal.supportsConfirmedNoEffect)
        #expect(journal.supportsRunRecords)
        #expect(journal.supportsPerCallFollowUps)
        #expect(journal.supportsAuthorizationAudit)
        #expect(journal.supportsAdmissionRejections)

        // Existing session checkpoint and messages remain readable with original message IDs.
        #expect(try await journal.latestCheckpoint(sessionID: fixture.sessionA)?.history == fixture.legacyHistory)
        let initialMessages = try await journal.readMessages(sessionID: fixture.sessionA, after: 0, limit: 10)
        #expect(initialMessages.map(\.id) == [fixture.message0ID, fixture.message1ID])
        #expect(initialMessages.map(\.message) == fixture.legacyHistory)

        // Existing pre-change mutations remain readable by (sessionID, runID, callID).
        let legacyStatusA = try #require(try await journal.mutationStatus(
            sessionID: fixture.sessionA,
            runID: fixture.legacyRunA,
            callID: fixture.legacyCallA
        ))
        #expect(legacyStatusA.state == .needsReconciliation)
        let legacyStatusB = try #require(try await journal.mutationStatus(
            sessionID: fixture.sessionB,
            runID: fixture.legacyRunB,
            callID: fixture.legacyCallB
        ))
        #expect(legacyStatusB.state == .aborted)
        #expect(legacyStatusB.abortConfirmation == fixture.legacyConfirmationB)

        // Abort the pending legacy mutation on sessionA (same invocation update -> still 0 rows in mutation_calls).
        let pendingA = try #require(try await journal.recoverPendingMutations(sessionID: fixture.sessionA).first)
        #expect(pendingA.runID == fixture.legacyRunA)
        #expect(pendingA.intent.call.id == fixture.legacyCallA)
        let confirmationA = try AgentNoEffectConfirmation(basis: "verified absent on target")
        try await journal.abortMutation(pendingA, confirmedNoEffect: confirmationA)
        #expect(try await journal.pendingMutations(sessionID: fixture.sessionA).isEmpty)
        #expect(try Self.rowCount(table: "mutation_calls", at: directory) == 0)

        let appendedHistory = fixture.legacyHistory + [
            .user([.text("post-open-prompt")]),
            .assistant(content: [.text("post-open-reply")], toolCalls: []),
        ]
        _ = try await journal.appendCheckpoint(
            [.checkpoint(history: appendedHistory, steeringIDs: [])],
            sessionID: fixture.sessionA,
            runID: UUID(),
            durability: .durable
        )

        // Retry legacyKeyA under a new invocation; legacyCallA is archived into mutation_calls.
        let newRunA = UUID()
        let newCallA = ToolCallID(rawValue: "retry-call-a")
        guard case .admitted = try await journal.admit(.init(
            sessionID: fixture.sessionA,
            runID: newRunA,
            callID: newCallA,
            name: "write",
            argumentsJSON: #"{"id":"a"}"#,
            resources: [.named(fixture.targetA)],
            idempotencyKey: fixture.legacyKeyA,
            receiptExpectation: fixture.expectationA
        )) else {
            Issue.record("expected fresh admission when retrying aborted legacy mutation A")
            try? await journal.close()
            return
        }
        #expect(try Self.rowCount(table: "mutation_calls", at: directory) == 1)

        let receiptA = ToolReceipt(operationID: fixture.legacyKeyA, status: .succeeded, confirmedTargets: [fixture.targetA], revision: "rev-a-2")
        let outputA = JSONValue.object(["item": .string("a")])
        let finalHistoryA = appendedHistory + [
            .assistant(content: [], toolCalls: [.init(id: newCallA, name: "write", argumentsJSON: #"{"id":"a"}"#, completeness: .complete)]),
            .tool(.init(callID: newCallA, content: [.text("done-a")], isError: false)),
        ]
        try await journal.commitMutation(
            sessionID: fixture.sessionA,
            runID: newRunA,
            callID: newCallA,
            receipt: receiptA,
            output: outputA,
            history: finalHistoryA,
            steeringIDs: []
        )
        #expect(try Self.rowCount(table: "mutation_calls", at: directory) == 1)

        // Retry legacyKeyB directly against the pre-existing already-aborted v1 mutation.
        let newRunB = UUID()
        let newCallB = ToolCallID(rawValue: "retry-call-b")
        guard case .admitted = try await journal.admit(.init(
            sessionID: fixture.sessionB,
            runID: newRunB,
            callID: newCallB,
            name: "write",
            argumentsJSON: #"{"id":"b"}"#,
            resources: [.named(fixture.targetB)],
            idempotencyKey: fixture.legacyKeyB,
            receiptExpectation: fixture.expectationB
        )) else {
            Issue.record("expected fresh admission when retrying pre-aborted legacy mutation B")
            try? await journal.close()
            return
        }
        #expect(try Self.rowCount(table: "mutation_calls", at: directory) == 2)

        let receiptB = ToolReceipt(operationID: fixture.legacyKeyB, status: .succeeded, confirmedTargets: [fixture.targetB], revision: "rev-b-2")
        let outputB = JSONValue.object(["item": .string("b")])
        let finalHistoryB: [ModelMessage] = [
            .user([.text("retry-b")]),
            .assistant(content: [], toolCalls: [.init(id: newCallB, name: "write", argumentsJSON: #"{"id":"b"}"#, completeness: .complete)]),
            .tool(.init(callID: newCallB, content: [.text("done-b")], isError: false)),
        ]
        try await journal.commitMutation(
            sessionID: fixture.sessionB,
            runID: newRunB,
            callID: newCallB,
            receipt: receiptB,
            output: outputB,
            history: finalHistoryB,
            steeringIDs: []
        )
        #expect(try Self.rowCount(table: "mutation_calls", at: directory) == 2)

        try await journal.close()
        #expect(try Self.readStoreMetaVersionAndDigest(at: directory).schemaVersion == 1)

        let reopened = try AgentSQLiteJournal.open(at: directory)
        #expect(try Self.readStoreMetaVersionAndDigest(at: directory).schemaVersion == 1)
        #expect(await reopened.storeIdentity() == identity)
        #expect(try await reopened.latestCheckpoint(sessionID: fixture.sessionA)?.history == finalHistoryA)
        let reopenedMessages = try await reopened.readMessages(sessionID: fixture.sessionA, after: 0, limit: 20)
        #expect(reopenedMessages.map(\.message) == finalHistoryA)
        #expect(Array(reopenedMessages.prefix(2).map(\.id)) == [fixture.message0ID, fixture.message1ID])

        // Both legacy and retried invocations survive close and reopen.
        let reopenedLegacyA = try #require(try await reopened.mutationStatus(
            sessionID: fixture.sessionA,
            runID: fixture.legacyRunA,
            callID: fixture.legacyCallA
        ))
        #expect(reopenedLegacyA.state == .aborted)
        #expect(reopenedLegacyA.abortConfirmation == confirmationA)

        let reopenedRetryA = try #require(try await reopened.mutationStatus(
            sessionID: fixture.sessionA,
            runID: newRunA,
            callID: newCallA
        ))
        #expect(reopenedRetryA.state == .settled)
        #expect(reopenedRetryA.receipt == receiptA)
        #expect(reopenedRetryA.replayOutput == outputA)
        #expect(try await reopened.mutationStatus(identity: fixture.legacyKeyA) == reopenedRetryA)

        let reopenedLegacyB = try #require(try await reopened.mutationStatus(
            sessionID: fixture.sessionB,
            runID: fixture.legacyRunB,
            callID: fixture.legacyCallB
        ))
        #expect(reopenedLegacyB.state == .aborted)
        #expect(reopenedLegacyB.abortConfirmation == fixture.legacyConfirmationB)

        let reopenedRetryB = try #require(try await reopened.mutationStatus(
            sessionID: fixture.sessionB,
            runID: newRunB,
            callID: newCallB
        ))
        #expect(reopenedRetryB.state == .settled)
        #expect(reopenedRetryB.receipt == receiptB)
        #expect(reopenedRetryB.replayOutput == outputB)
        #expect(try await reopened.mutationStatus(identity: fixture.legacyKeyB) == reopenedRetryB)

        try await reopened.close()
    }

    @Test func localizedCorruptedMutationDigestDoesNotBlockOpeningOrHealthySessionReads() async throws {
        let directory = tempDir("v1-corrupt-digest-localized")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try Self.createSchemaV1Database(at: directory)

        let dbURL = directory.appendingPathComponent("journal.sqlite3")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw AgentJournalError.persistenceUnavailable("unable to open v1 fixture for corruption")
        }
        try Self.withPrepared(
            db,
            "UPDATE mutations SET digest = ? WHERE idempotency_key = ?;"
        ) { stmt in
            Self.bindText(stmt, 1, String(repeating: "0", count: 64))
            Self.bindText(stmt, 2, fixture.legacyKeyB)
        }
        sqlite3_close_v2(db)

        // Opening succeeds without scanning mutations or modifying store_meta.
        let journal = try AgentSQLiteJournal.open(at: directory)
        #expect(try Self.readStoreMetaVersionAndDigest(at: directory) == (1, fixture.metaDigest))

        // Unrelated healthy session messages and mutation remain readable.
        #expect(try await journal.latestCheckpoint(sessionID: fixture.sessionA)?.history == fixture.legacyHistory)
        #expect(try await journal.readMessages(sessionID: fixture.sessionA, after: 0, limit: 10).map(\.id) == [fixture.message0ID, fixture.message1ID])
        #expect(try await journal.mutationStatus(identity: fixture.legacyKeyA)?.state == .needsReconciliation)

        // Reading the corrupted row fails with checksumMismatch.
        await #expect(throws: AgentJournalError.checksumMismatch) {
            _ = try await journal.mutationStatus(identity: fixture.legacyKeyB)
        }
        await #expect(throws: AgentJournalError.checksumMismatch) {
            _ = try await journal.mutationStatus(
                sessionID: fixture.sessionB,
                runID: fixture.legacyRunB,
                callID: fixture.legacyCallB
            )
        }
        await #expect(throws: AgentJournalError.checksumMismatch) {
            _ = try await journal.admit(.init(
                sessionID: fixture.sessionB,
                runID: UUID(),
                callID: .init(rawValue: "retry-corrupt-digest"),
                name: "write",
                argumentsJSON: #"{"id":"b"}"#,
                resources: [.named(fixture.targetB)],
                idempotencyKey: fixture.legacyKeyB,
                receiptExpectation: fixture.expectationB
            ))
        }

        try await journal.close()
    }

    @Test func localizedTamperedMutationPayloadDoesNotBlockOpeningOrHealthySessionReads() async throws {
        let directory = tempDir("v1-tampered-payload-localized")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try Self.createSchemaV1Database(at: directory)

        let dbURL = directory.appendingPathComponent("journal.sqlite3")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw AgentJournalError.persistenceUnavailable("unable to open v1 fixture for payload tamper")
        }
        // Replace mutation_json with syntactically valid JSON while leaving the original hex digest untouched.
        try Self.withPrepared(
            db,
            "UPDATE mutations SET mutation_json = ? WHERE idempotency_key = ?;"
        ) { stmt in
            Self.bindBlob(stmt, 1, Data(#"{"tampered":true}"#.utf8))
            Self.bindText(stmt, 2, fixture.legacyKeyB)
        }
        sqlite3_close_v2(db)

        // Opening succeeds without scanning mutations or modifying store_meta.
        let journal = try AgentSQLiteJournal.open(at: directory)
        #expect(try Self.readStoreMetaVersionAndDigest(at: directory) == (1, fixture.metaDigest))

        // Healthy session checkpoint, messages, and unrelated mutation remain readable.
        #expect(try await journal.latestCheckpoint(sessionID: fixture.sessionA)?.history == fixture.legacyHistory)
        #expect(try await journal.readMessages(sessionID: fixture.sessionA, after: 0, limit: 10).map(\.message) == fixture.legacyHistory)
        #expect(try await journal.mutationStatus(sessionID: fixture.sessionA, runID: fixture.legacyRunA, callID: fixture.legacyCallA)?.state == .needsReconciliation)

        // Reading the tampered mutation fails with checksumMismatch.
        await #expect(throws: AgentJournalError.checksumMismatch) {
            _ = try await journal.mutationStatus(identity: fixture.legacyKeyB)
        }
        await #expect(throws: AgentJournalError.checksumMismatch) {
            _ = try await journal.mutationStatus(
                sessionID: fixture.sessionB,
                runID: fixture.legacyRunB,
                callID: fixture.legacyCallB
            )
        }

        try await journal.close()
    }

    @Test func sameInvocationTransitionsStoreNoHistoryRowsAndRetriesArchiveOnlySupersededCalls() async throws {
        // Part 1: Ordinary single-attempt admit -> settle leaves mutation_calls empty.
        let singleDir = tempDir("single-attempt-no-history")
        defer { try? FileManager.default.removeItem(at: singleDir) }
        let singleJournal = try AgentSQLiteJournal.create(
            at: singleDir,
            operationDomain: "single-attempt-storage",
            supportsConfirmedNoEffect: true
        )
        let singleSession = UUID(), singleRun = UUID()
        let singleCall = ToolCallID(rawValue: "single-call")
        let singleTarget = EvidenceReference(namespace: "fixture", id: "single-item")
        let singleExpectation = try ToolReceiptExpectation(targets: [singleTarget], revision: .present)
        let singleKey = "single-attempt/write/{\"id\":\"single\"}"

        guard case .admitted = try await singleJournal.admit(.init(
            sessionID: singleSession,
            runID: singleRun,
            callID: singleCall,
            name: "write",
            argumentsJSON: #"{"id":"single"}"#,
            resources: [.named(singleTarget)],
            idempotencyKey: singleKey,
            receiptExpectation: singleExpectation
        )) else {
            Issue.record("expected single-attempt admission")
            try? await singleJournal.close()
            return
        }
        #expect(try Self.rowCount(table: "mutations", at: singleDir) == 1)
        #expect(try Self.rowCount(table: "mutation_calls", at: singleDir) == 0)

        let singleReceipt = ToolReceipt(operationID: singleKey, status: .succeeded, confirmedTargets: [singleTarget], revision: "rev-1")
        let singleHistory: [ModelMessage] = [
            .user([.text("single write")]),
            .assistant(content: [], toolCalls: [.init(id: singleCall, name: "write", argumentsJSON: #"{"id":"single"}"#, completeness: .complete)]),
            .tool(.init(callID: singleCall, content: [.text("ok")], isError: false)),
        ]
        try await singleJournal.commitMutation(
            sessionID: singleSession,
            runID: singleRun,
            callID: singleCall,
            receipt: singleReceipt,
            output: .string("single-ok"),
            history: singleHistory,
            steeringIDs: []
        )
        #expect(try Self.rowCount(table: "mutations", at: singleDir) == 1)
        #expect(try Self.rowCount(table: "mutation_calls", at: singleDir) == 0)
        try await singleJournal.close()

        // Part 2: Same-invocation intent -> needsReconciliation -> aborted produces 0 history rows;
        // retrying under a new invocation archives only the superseded call and settling adds no extra rows.
        let retryDir = tempDir("retry-archives-superseded")
        defer { try? FileManager.default.removeItem(at: retryDir) }
        let journal = try AgentSQLiteJournal.create(
            at: retryDir,
            operationDomain: "retry-storage",
            supportsConfirmedNoEffect: true
        )
        let session = UUID(), run1 = UUID(), run2 = UUID()
        let call1 = ToolCallID(rawValue: "call-1")
        let call2 = ToolCallID(rawValue: "call-2")
        let target = EvidenceReference(namespace: "fixture", id: "retry-item")
        let expectation = try ToolReceiptExpectation(targets: [target], revision: .present)
        let key = "retry-storage/write/{\"id\":\"item\"}"
        let confirmation = try AgentNoEffectConfirmation(basis: "verified absent before retry")

        guard case .admitted = try await journal.admit(.init(
            sessionID: session,
            runID: run1,
            callID: call1,
            name: "write",
            argumentsJSON: #"{"id":"item"}"#,
            resources: [.named(target)],
            idempotencyKey: key,
            receiptExpectation: expectation
        )) else {
            Issue.record("expected initial admission")
            try? await journal.close()
            return
        }
        #expect(try Self.rowCount(table: "mutations", at: retryDir) == 1)
        #expect(try Self.rowCount(table: "mutation_calls", at: retryDir) == 0)

        try await journal.markMutationNeedsReconciliation(sessionID: session, runID: run1, callID: call1)
        #expect(try Self.rowCount(table: "mutations", at: retryDir) == 1)
        #expect(try Self.rowCount(table: "mutation_calls", at: retryDir) == 0)

        let pending = try #require(try await journal.recoverPendingMutations(sessionID: session).first)
        try await journal.abortMutation(pending, confirmedNoEffect: confirmation)
        #expect(try Self.rowCount(table: "mutations", at: retryDir) == 1)
        #expect(try Self.rowCount(table: "mutation_calls", at: retryDir) == 0)

        // Retrying the same idempotencyKey with a new invocation archives (session, run1, call1) into mutation_calls.
        guard case .admitted = try await journal.admit(.init(
            sessionID: session,
            runID: run2,
            callID: call2,
            name: "write",
            argumentsJSON: #"{"id":"item"}"#,
            resources: [.named(target)],
            idempotencyKey: key,
            receiptExpectation: expectation
        )) else {
            Issue.record("expected retry admission")
            try? await journal.close()
            return
        }
        #expect(try Self.rowCount(table: "mutations", at: retryDir) == 1)
        #expect(try Self.rowCount(table: "mutation_calls", at: retryDir) == 1)
        #expect(try Self.storedCalls(table: "mutations", at: retryDir) == [
            StoredCallIdentity(sessionID: session.uuidString, runID: run2.uuidString, callID: call2.rawValue),
        ])
        #expect(try Self.storedCalls(table: "mutation_calls", at: retryDir) == [
            StoredCallIdentity(sessionID: session.uuidString, runID: run1.uuidString, callID: call1.rawValue),
        ])

        // Settling (session, run2, call2) updates mutations in place without adding another row to mutation_calls.
        let receipt = ToolReceipt(operationID: key, status: .succeeded, confirmedTargets: [target], revision: "rev-2")
        let settledOutput = JSONValue.object(["settled": .bool(true)])
        let history: [ModelMessage] = [
            .user([.text("retry write")]),
            .assistant(content: [], toolCalls: [.init(id: call2, name: "write", argumentsJSON: #"{"id":"item"}"#, completeness: .complete)]),
            .tool(.init(callID: call2, content: [.text("done")], isError: false)),
        ]
        try await journal.commitMutation(
            sessionID: session,
            runID: run2,
            callID: call2,
            receipt: receipt,
            output: settledOutput,
            history: history,
            steeringIDs: []
        )
        #expect(try Self.rowCount(table: "mutations", at: retryDir) == 1)
        #expect(try Self.rowCount(table: "mutation_calls", at: retryDir) == 1)
        #expect(try Self.storedCalls(table: "mutations", at: retryDir) == [
            StoredCallIdentity(sessionID: session.uuidString, runID: run2.uuidString, callID: call2.rawValue),
        ])
        #expect(try Self.storedCalls(table: "mutation_calls", at: retryDir) == [
            StoredCallIdentity(sessionID: session.uuidString, runID: run1.uuidString, callID: call1.rawValue),
        ])
        try await journal.close()

        let reopened = try AgentSQLiteJournal.open(at: retryDir)
        let firstStatus = try #require(try await reopened.mutationStatus(sessionID: session, runID: run1, callID: call1))
        #expect(firstStatus.state == .aborted)
        #expect(firstStatus.receipt == nil)
        #expect(firstStatus.replayOutput == nil)
        #expect(firstStatus.abortConfirmation == confirmation)

        let secondStatus = try #require(try await reopened.mutationStatus(sessionID: session, runID: run2, callID: call2))
        #expect(secondStatus.state == .settled)
        #expect(secondStatus.receipt == receipt)
        #expect(secondStatus.replayOutput == settledOutput)
        #expect(try await reopened.mutationStatus(identity: key) == secondStatus)
        #expect(try Self.rowCount(table: "mutations", at: retryDir) == 1)
        #expect(try Self.rowCount(table: "mutation_calls", at: retryDir) == 1)
        #expect(try Self.readStoreMetaVersionAndDigest(at: retryDir).schemaVersion == 1)
        try await reopened.close()
    }
}
