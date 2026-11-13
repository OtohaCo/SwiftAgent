import AgentCore
import AgentModels
import AgentTools
import Foundation
import SQLite3

private struct SQLiteRunEnvelope: Codable {
    let storeID: UUID
    let sessionID: UUID
    let runID: UUID
    let formalMessageID: UUID
    let formalMessageOrdinal: UInt64
    let correlationKey: String?
    let correlationPayloadDigest: String?
    let payloadFingerprint: String
    let followUpInputID: String?

    init(
        storeID: UUID,
        sessionID: UUID,
        runID: UUID,
        formalMessageID: UUID,
        formalMessageOrdinal: UInt64,
        admission: JournalRunAdmission,
        followUpInputID: String?
    ) {
        self.storeID = storeID
        self.sessionID = sessionID
        self.runID = runID
        self.formalMessageID = formalMessageID
        self.formalMessageOrdinal = formalMessageOrdinal
        self.correlationKey = admission.correlation?.key
        self.correlationPayloadDigest = admission.correlation?.payloadDigest
        self.payloadFingerprint = admission.payloadFingerprint
        self.followUpInputID = followUpInputID
    }

    func toStoredRun() throws -> JournalStoredRun {
        let correlation: AgentRunCorrelation?
        if let key = correlationKey, let digest = correlationPayloadDigest {
            correlation = try AgentRunCorrelation(key: key, payloadDigest: digest)
        } else if correlationKey == nil && correlationPayloadDigest == nil {
            correlation = nil
        } else {
            throw AgentJournalError.invalidRecord
        }
        let record = AgentRunRecord(
            storeID: storeID,
            sessionID: sessionID,
            runID: runID,
            formalMessageID: formalMessageID,
            correlation: correlation,
            followUpInputID: followUpInputID
        )
        return JournalStoredRun(
            record: record,
            formalMessageOrdinal: formalMessageOrdinal,
            payloadFingerprint: payloadFingerprint
        )
    }
}

private struct SQLiteFollowUpEnvelope: Codable {
    let sessionID: UUID
    let ordinal: UInt64
    let inputID: String
    let text: String
    let operationID: String?
    let configurationRef: String
    let stateKind: String
    let admittedRunID: UUID?
    let admittedFormalMessageID: UUID?

    init(_ value: JournalStoredFollowUp) {
        sessionID = value.sessionID
        ordinal = value.ordinal
        inputID = value.input.inputID
        text = value.input.text
        operationID = value.input.operationID
        configurationRef = value.input.configurationRef
        switch value.state {
        case .queued:
            stateKind = "queued"; admittedRunID = nil; admittedFormalMessageID = nil
        case .withdrawn:
            stateKind = "withdrawn"; admittedRunID = nil; admittedFormalMessageID = nil
        case .admitted(let runID, let formalID):
            stateKind = "admitted"; admittedRunID = runID; admittedFormalMessageID = formalID
        }
    }

    func toStoredFollowUp(nextQueued: UInt64?) throws -> JournalStoredFollowUp {
        let identity: AgentOperationIdentity = operationID.map { .operation($0) } ?? .perCall
        let input = AgentFollowUpInput(
            inputID: inputID,
            text: text,
            identity: identity,
            configurationRef: configurationRef
        )
        let state: AgentFollowUpState
        switch stateKind {
        case "queued":
            state = .queued
        case "withdrawn":
            state = .withdrawn
        case "admitted":
            guard let admittedRunID, let admittedFormalMessageID else {
                throw AgentJournalError.invalidRecord
            }
            state = .admitted(runID: admittedRunID, formalMessageID: admittedFormalMessageID)
        default:
            throw AgentJournalError.invalidRecord
        }
        return JournalStoredFollowUp(
            sessionID: sessionID,
            ordinal: ordinal,
            input: input,
            state: state,
            nextQueued: nextQueued
        )
    }
}

extension AgentJournalSQLiteStore {
    static func pendingOperationKey(for intent: PendingMutationIntent, runID: UUID) -> String? {
        if intent.idempotencyKey == "\(runID.uuidString)/\(intent.call.id.rawValue)" {
            return nil
        }
        guard let arguments = try? JSONValue.decodeToolArguments(intent.call.argumentsJSON),
              let data = try? canonicalJSON(arguments) else {
            return "untyped"
        }
        let suffix = "/\(intent.call.name)/\(String(decoding: data, as: UTF8.self))"
        guard intent.idempotencyKey.hasSuffix(suffix) else { return "untyped" }
        let prefix = intent.idempotencyKey.dropLast(suffix.count)
        guard !prefix.isEmpty else { return "untyped" }
        return "operation/\(Data(String(prefix).utf8).base64EncodedString())"
    }

    static func operationLookupKey(_ operationID: String) -> String {
        "operation/\(Data(operationID.utf8).base64EncodedString())"
    }

    final class View: JournalStoreView {
        let store: AgentJournalSQLiteStore
        let db: OpaquePointer
        let writable: Bool
        var didPublish = false
        var writtenBytes: UInt64 = 0

        init(store: AgentJournalSQLiteStore, db: OpaquePointer, writable: Bool) {
            self.store = store
            self.db = db
            self.writable = writable
        }

        func nextRecordSequence() throws -> UInt64 {
            try store.loadMetaState(on: db).nextRecordSequence
        }

        func header(_ id: UUID) throws -> JournalSessionHeader? {
            try Self.loadHeader(sessionID: id, store: store, db: db)
        }

        static func loadHeader(
            sessionID: UUID,
            store: AgentJournalSQLiteStore,
            db: OpaquePointer
        ) throws -> JournalSessionHeader? {
            let row: (Int64, Data, String)? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: "SELECT revision, header_json, digest FROM sessions WHERE session_id = ?;"
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, sessionID.uuidString)
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                return (
                    sqlite3_column_int64(stmt, 0),
                    AgentJournalSQLiteStore.columnBlob(stmt, 1),
                    AgentJournalSQLiteStore.columnText(stmt, 2)
                )
            }
            guard let (revInt, bytes, storedDigest) = row else { return nil }
            store.noteReadBytes(bytes.count)
            let revision = UInt64(bitPattern: revInt)
            let expectedDigest = AgentJournalSQLiteStore.rowDigest(
                prefix: "session:\(store.storeID.uuidString):\(sessionID.uuidString):\(revision):",
                payload: bytes
            )
            guard storedDigest == expectedDigest else {
                throw AgentJournalError.checksumMismatch
            }
            let decoded = try AgentJournalSQLiteStore.decodeJSON(JournalSessionHeader.self, from: bytes)
            guard decoded.revision == revision else { throw AgentJournalError.invalidRecord }
            if let proof = decoded.contextHandoff?.closedTurnProof {
                guard store.supportsIncompleteContextHandoff,
                      proof.storeID == store.storeID,
                      proof.sessionID == sessionID else {
                    throw AgentJournalError.invalidRecord
                }
            }
            return decoded
        }

        func session(_ id: UUID) throws -> JournalStoredSession? {
            guard let sessionHeader = try header(id) else { return nil }
            var history: [ModelMessage] = []
            var ordinal: UInt64 = 0
            while ordinal < sessionHeader.messageCount {
                let page = try messages(sessionID: id, after: ordinal, limit: 512)
                guard !page.isEmpty else { throw AgentJournalError.invalidRecord }
                history.append(contentsOf: page.map(\.value))
                ordinal += UInt64(page.count)
            }
            return JournalStoredSession(header: sessionHeader, history: history)
        }

        func messages(sessionID: UUID, after ordinal: UInt64, limit: Int) throws -> [JournalMessage] {
            try store.fault?(.beforeSessionRead)
            guard (1...1000).contains(limit) else { throw AgentJournalError.invalidRecord }
            guard let sessionHeader = try header(sessionID), ordinal < sessionHeader.messageCount else {
                return []
            }
            let rows: [(UInt64, String, Data, String)] = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: """
                SELECT ordinal, message_id, message_json, digest
                FROM session_messages
                WHERE session_id = ? AND ordinal >= ? AND ordinal < ?
                ORDER BY ordinal ASC LIMIT ?;
                """
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, sessionID.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(bitPattern: ordinal))
                sqlite3_bind_int64(stmt, 3, Int64(bitPattern: sessionHeader.messageCount))
                sqlite3_bind_int64(stmt, 4, Int64(limit))
                var collected: [(UInt64, String, Data, String)] = []
                while try AgentJournalSQLiteStore.stepRow(stmt, on: db) {
                    collected.append((
                        UInt64(bitPattern: sqlite3_column_int64(stmt, 0)),
                        AgentJournalSQLiteStore.columnText(stmt, 1),
                        AgentJournalSQLiteStore.columnBlob(stmt, 2),
                        AgentJournalSQLiteStore.columnText(stmt, 3)
                    ))
                }
                return collected
            }
            var result: [JournalMessage] = []
            result.reserveCapacity(rows.count)
            for (offset, row) in rows.enumerated() {
                let (rowOrdinal, idString, payload, storedDigest) = row
                store.noteReadBytes(payload.count)
                guard rowOrdinal == ordinal + UInt64(offset),
                      let msgID = UUID(uuidString: idString) else {
                    throw AgentJournalError.invalidRecord
                }
                let expected = AgentJournalSQLiteStore.rowDigest(
                    prefix: "msg:\(store.storeID.uuidString):\(sessionID.uuidString):\(rowOrdinal):\(idString):",
                    payload: payload
                )
                guard storedDigest == expected else {
                    throw AgentJournalError.checksumMismatch
                }
                let envelope = try AgentJournalSQLiteStore.decodeJSON(SQLiteMessageEnvelope.self, from: payload)
                let decodedMessage = try envelope.decode { ref in
                    try self.store.loadImage(ref, on: self.db)
                }
                result.append(JournalMessage(id: msgID, value: decodedMessage))
            }
            return result
        }

        func identity(_ key: String) throws -> JournalStoredMutation? {
            let row: (Data, String)? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: "SELECT mutation_json, digest FROM mutations WHERE idempotency_key = ?;"
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, key)
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                return (
                    AgentJournalSQLiteStore.columnBlob(stmt, 0),
                    AgentJournalSQLiteStore.columnText(stmt, 1)
                )
            }
            guard let (bytes, storedDigest) = row else { return nil }
            store.noteReadBytes(bytes.count)
            let expected = AgentJournalSQLiteStore.rowDigest(
                prefix: "mutation:\(store.storeID.uuidString):\(key):",
                payload: bytes
            )
            guard storedDigest == expected else { throw AgentJournalError.checksumMismatch }
            let mutation = try AgentJournalSQLiteStore.decodeJSON(JournalStoredMutation.self, from: bytes)
            guard mutation.intent.idempotencyKey == key else { throw AgentJournalError.invalidRecord }
            return mutation
        }

        func mutation(sessionID: UUID, runID: UUID, callID: ToolCallID) throws -> JournalStoredMutation? {
            let row: (String, Data, String)? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: """
                SELECT idempotency_key, mutation_json, digest
                FROM mutations WHERE session_id = ? AND run_id = ? AND call_id = ?;
                """
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, sessionID.uuidString)
                AgentJournalSQLiteStore.bindText(stmt, 2, runID.uuidString)
                AgentJournalSQLiteStore.bindText(stmt, 3, callID.rawValue)
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                return (
                    AgentJournalSQLiteStore.columnText(stmt, 0),
                    AgentJournalSQLiteStore.columnBlob(stmt, 1),
                    AgentJournalSQLiteStore.columnText(stmt, 2)
                )
            }
            guard let (key, bytes, storedDigest) = row else { return nil }
            store.noteReadBytes(bytes.count)
            let expected = AgentJournalSQLiteStore.rowDigest(
                prefix: "mutation:\(store.storeID.uuidString):\(key):",
                payload: bytes
            )
            guard storedDigest == expected else { throw AgentJournalError.checksumMismatch }
            let mutation = try AgentJournalSQLiteStore.decodeJSON(JournalStoredMutation.self, from: bytes)
            guard mutation.sessionID == sessionID,
                  mutation.runID == runID,
                  mutation.intent.call.id == callID else {
                throw AgentJournalError.invalidRecord
            }
            return mutation
        }

        func pending(sessionID: UUID?) throws -> [JournalStoredMutation] {
            let sessionIDs: [UUID]
            if let sessionID {
                sessionIDs = [sessionID]
            } else {
                sessionIDs = try AgentJournalSQLiteStore.withPrepared(
                    on: db,
                    sql: "SELECT session_id FROM sessions;"
                ) { stmt in
                    var ids: [UUID] = []
                    while try AgentJournalSQLiteStore.stepRow(stmt, on: db) {
                        guard let parsed = UUID(uuidString: AgentJournalSQLiteStore.columnText(stmt, 0)) else {
                            throw AgentJournalError.invalidRecord
                        }
                        ids.append(parsed)
                    }
                    return ids
                }
            }
            var items: [JournalStoredMutation] = []
            for id in sessionIDs {
                if let pendingKey = try header(id)?.pendingIdentity,
                   let found = try identity(pendingKey),
                   found.sessionID == id,
                   found.state == .intent || found.state == .needsReconciliation {
                    items.append(found)
                }
            }
            return items.sorted { $0.sequence < $1.sequence }
        }

        func hasPending(operationID: String) throws -> Bool {
            guard store.supportsAdmissionRejections else { throw AgentJournalError.unsupportedFormat }
            let lookupKey = AgentJournalSQLiteStore.operationLookupKey(operationID)
            let rows: [(String, String)] = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: """
                SELECT session_id, idempotency_key FROM mutations
                WHERE (state = 'intent' OR state = 'needsReconciliation')
                  AND (operation_id = ? OR operation_id = 'untyped');
                """
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, lookupKey)
                var list: [(String, String)] = []
                while try AgentJournalSQLiteStore.stepRow(stmt, on: db) {
                    list.append((
                        AgentJournalSQLiteStore.columnText(stmt, 0),
                        AgentJournalSQLiteStore.columnText(stmt, 1)
                    ))
                }
                return list
            }
            for (sessionText, key) in rows {
                guard let sessionID = UUID(uuidString: sessionText) else { throw AgentJournalError.invalidRecord }
                if try header(sessionID)?.pendingIdentity == key {
                    return true
                }
            }
            return false
        }

        func admissionRejection(
            sessionID: UUID,
            runID: UUID,
            callID: ToolCallID
        ) throws -> JournalAdmissionRejection? {
            guard store.supportsAdmissionRejections else { return nil }
            let row: (String, String)? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: """
                SELECT tool_name, digest FROM admission_rejections
                WHERE session_id = ? AND run_id = ? AND call_id = ?;
                """
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, sessionID.uuidString)
                AgentJournalSQLiteStore.bindText(stmt, 2, runID.uuidString)
                AgentJournalSQLiteStore.bindText(stmt, 3, callID.rawValue)
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                return (
                    AgentJournalSQLiteStore.columnText(stmt, 0),
                    AgentJournalSQLiteStore.columnText(stmt, 1)
                )
            }
            guard let (toolName, storedDigest) = row else { return nil }
            let expected = AgentJournalSQLiteStore.rowDigest(
                prefix: "reject:\(store.storeID.uuidString):\(sessionID.uuidString):\(runID.uuidString):\(callID.rawValue):",
                payload: Data(toolName.utf8)
            )
            guard storedDigest == expected else { throw AgentJournalError.checksumMismatch }
            return JournalAdmissionRejection(sessionID: sessionID, runID: runID, callID: callID, toolName: toolName)
        }

        func runRecord(sessionID: UUID, runID: UUID) throws -> JournalStoredRun? {
            guard store.supportsRunRecords else { throw AgentJournalError.unsupportedFormat }
            let row: (Data, Data?, String)? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: "SELECT run_json, terminal_json, digest FROM run_records WHERE session_id = ? AND run_id = ?;"
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, sessionID.uuidString)
                AgentJournalSQLiteStore.bindText(stmt, 2, runID.uuidString)
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                return (
                    AgentJournalSQLiteStore.columnBlob(stmt, 0),
                    AgentJournalSQLiteStore.columnOptionalBlob(stmt, 1),
                    AgentJournalSQLiteStore.columnText(stmt, 2)
                )
            }
            guard let (runBytes, terminalBytes, storedDigest) = row else { return nil }
            store.noteReadBytes(runBytes.count + (terminalBytes?.count ?? 0))
            var combined = runBytes
            if let terminalBytes { combined.append(terminalBytes) }
            let expected = AgentJournalSQLiteStore.rowDigest(
                prefix: "run:\(store.storeID.uuidString):\(sessionID.uuidString):\(runID.uuidString):",
                payload: combined
            )
            guard storedDigest == expected else { throw AgentJournalError.checksumMismatch }
            let envelope = try AgentJournalSQLiteStore.decodeJSON(SQLiteRunEnvelope.self, from: runBytes)
            guard envelope.storeID == store.storeID,
                  envelope.sessionID == sessionID,
                  envelope.runID == runID else {
                throw AgentJournalError.invalidRecord
            }
            let stored = try envelope.toStoredRun()
            guard let formal = try messages(sessionID: sessionID, after: stored.formalMessageOrdinal, limit: 1).first,
                  formal.id == stored.record.formalMessageID,
                  case .user = formal.value else {
                throw AgentJournalError.invalidRecord
            }
            return stored
        }

        func runRecord(sessionID: UUID, correlationKey: String) throws -> JournalStoredRun? {
            guard store.supportsRunRecords else { throw AgentJournalError.unsupportedFormat }
            let runIDText: String? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: "SELECT run_id FROM run_records WHERE session_id = ? AND correlation_key = ?;"
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, sessionID.uuidString)
                AgentJournalSQLiteStore.bindText(stmt, 2, correlationKey)
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                return AgentJournalSQLiteStore.columnText(stmt, 0)
            }
            guard let runIDText else { return nil }
            guard let parsed = UUID(uuidString: runIDText),
                  let stored = try runRecord(sessionID: sessionID, runID: parsed),
                  stored.record.correlation?.key == correlationKey else {
                throw AgentJournalError.invalidRecord
            }
            return stored
        }

        func runTerminal(sessionID: UUID, runID: UUID) throws -> AgentRunTerminal? {
            guard store.supportsRunRecords else { throw AgentJournalError.unsupportedFormat }
            let row: (Data, Data?, String)? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: "SELECT run_json, terminal_json, digest FROM run_records WHERE session_id = ? AND run_id = ?;"
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, sessionID.uuidString)
                AgentJournalSQLiteStore.bindText(stmt, 2, runID.uuidString)
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                return (
                    AgentJournalSQLiteStore.columnBlob(stmt, 0),
                    AgentJournalSQLiteStore.columnOptionalBlob(stmt, 1),
                    AgentJournalSQLiteStore.columnText(stmt, 2)
                )
            }
            guard let (runBytes, terminalBytes, storedDigest) = row, let terminalBytes else { return nil }
            var combined = runBytes
            combined.append(terminalBytes)
            let expected = AgentJournalSQLiteStore.rowDigest(
                prefix: "run:\(store.storeID.uuidString):\(sessionID.uuidString):\(runID.uuidString):",
                payload: combined
            )
            guard storedDigest == expected else { throw AgentJournalError.checksumMismatch }
            guard try runRecord(sessionID: sessionID, runID: runID) != nil else {
                throw AgentJournalError.invalidRecord
            }
            return try AgentJournalSQLiteStore.decodeJSON(AgentRunTerminal.self, from: terminalBytes)
        }

        func followUpHead(sessionID: UUID) throws -> JournalFollowUpHead {
            let row: (Int64, Data, String)? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: "SELECT revision, head_json, digest FROM followup_heads WHERE session_id = ?;"
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, sessionID.uuidString)
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                return (
                    sqlite3_column_int64(stmt, 0),
                    AgentJournalSQLiteStore.columnBlob(stmt, 1),
                    AgentJournalSQLiteStore.columnText(stmt, 2)
                )
            }
            guard let (revInt, bytes, storedDigest) = row else { return .init() }
            store.noteReadBytes(bytes.count)
            let revision = UInt64(bitPattern: revInt)
            let expected = AgentJournalSQLiteStore.rowDigest(
                prefix: "qhead:\(store.storeID.uuidString):\(sessionID.uuidString):\(revision):",
                payload: bytes
            )
            guard storedDigest == expected else { throw AgentJournalError.checksumMismatch }
            let head = try AgentJournalSQLiteStore.decodeJSON(JournalFollowUpHead.self, from: bytes)
            guard head.revision == revision else { throw AgentJournalError.invalidRecord }
            return head
        }

        func followUp(sessionID: UUID, inputID: String) throws -> JournalStoredFollowUp? {
            let row: (UInt64, UInt64?, Data, String)? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: """
                SELECT ordinal, next_queued, followup_json, digest
                FROM followups WHERE session_id = ? AND input_id = ?;
                """
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, sessionID.uuidString)
                AgentJournalSQLiteStore.bindText(stmt, 2, inputID)
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                let ord = UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
                let next: UInt64? = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                    ? nil
                    : UInt64(bitPattern: sqlite3_column_int64(stmt, 1))
                return (
                    ord,
                    next,
                    AgentJournalSQLiteStore.columnBlob(stmt, 2),
                    AgentJournalSQLiteStore.columnText(stmt, 3)
                )
            }
            guard let (ord, nextQueued, bytes, storedDigest) = row else { return nil }
            store.noteReadBytes(bytes.count)
            let expected = AgentJournalSQLiteStore.rowDigest(
                prefix: "qitem:\(store.storeID.uuidString):\(sessionID.uuidString):\(ord):\(nextQueued.map(String.init) ?? "nil"):",
                payload: bytes
            )
            guard storedDigest == expected else { throw AgentJournalError.checksumMismatch }
            let decoded = try AgentJournalSQLiteStore.decodeJSON(SQLiteFollowUpEnvelope.self, from: bytes)
                .toStoredFollowUp(nextQueued: nextQueued)
            guard decoded.sessionID == sessionID, decoded.ordinal == ord,
                  decoded.input.inputID.utf8.elementsEqual(inputID.utf8) else {
                throw AgentJournalError.invalidRecord
            }
            return decoded
        }

        func followUps(sessionID: UUID, after ordinal: UInt64, limit: Int) throws -> [JournalStoredFollowUp] {
            guard (1...1000).contains(limit) else { throw AgentJournalError.invalidRecord }
            let head = try followUpHead(sessionID: sessionID)
            guard ordinal < head.nextOrdinal else { return [] }
            let (candidate, overflow) = ordinal.addingReportingOverflow(UInt64(limit))
            let end = min(head.nextOrdinal, overflow ? UInt64.max : candidate)
            let rows: [(UInt64, UInt64?, Data, String)] = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: """
                SELECT ordinal, next_queued, followup_json, digest
                FROM followups
                WHERE session_id = ? AND ordinal >= ? AND ordinal < ?
                ORDER BY ordinal ASC;
                """
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, sessionID.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(bitPattern: ordinal))
                sqlite3_bind_int64(stmt, 3, Int64(bitPattern: end))
                var list: [(UInt64, UInt64?, Data, String)] = []
                while try AgentJournalSQLiteStore.stepRow(stmt, on: db) {
                    let ord = UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
                    let next: UInt64? = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                        ? nil
                        : UInt64(bitPattern: sqlite3_column_int64(stmt, 1))
                    list.append((
                        ord,
                        next,
                        AgentJournalSQLiteStore.columnBlob(stmt, 2),
                        AgentJournalSQLiteStore.columnText(stmt, 3)
                    ))
                }
                return list
            }
            guard UInt64(rows.count) == (end - ordinal) else { throw AgentJournalError.invalidRecord }
            return try rows.enumerated().map { offset, row in
                let (ord, nextQueued, bytes, storedDigest) = row
                store.noteReadBytes(bytes.count)
                guard ord == ordinal + UInt64(offset) else { throw AgentJournalError.invalidRecord }
                let expected = AgentJournalSQLiteStore.rowDigest(
                    prefix: "qitem:\(store.storeID.uuidString):\(sessionID.uuidString):\(ord):\(nextQueued.map(String.init) ?? "nil"):",
                    payload: bytes
                )
                guard storedDigest == expected else { throw AgentJournalError.checksumMismatch }
                return try AgentJournalSQLiteStore.decodeJSON(SQLiteFollowUpEnvelope.self, from: bytes)
                    .toStoredFollowUp(nextQueued: nextQueued)
            }
        }

        func auditHighWater() throws -> UInt64 {
            guard store.supportsAuthorizationAudit else {
                throw AgentAuthorizationError.auditStoreRequired
            }
            let meta = try store.loadMetaState(on: db)
            if meta.auditHighWater > 0 {
                let allSummary: (UInt64, UInt64)? = try AgentJournalSQLiteStore.withPrepared(
                    on: db,
                    sql: "SELECT member_count, last_sequence FROM audit_groups WHERE group_key = 'all';"
                ) { stmt in
                    guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                    return (
                        UInt64(bitPattern: sqlite3_column_int64(stmt, 0)),
                        UInt64(bitPattern: sqlite3_column_int64(stmt, 1))
                    )
                }
                guard let allSummary, allSummary.0 == meta.auditHighWater, allSummary.1 == meta.auditHighWater else {
                    throw AgentJournalError.invalidRecord
                }
            }
            return meta.auditHighWater
        }

        func auditRecord(sequence: UInt64) throws -> AuditRecord {
            let highWater = try auditHighWater()
            guard sequence > 0, sequence <= highWater else { throw AgentJournalError.invalidRecord }
            let row: (Data, String)? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: "SELECT record_json, digest FROM audit_records WHERE sequence = ?;"
            ) { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(bitPattern: sequence))
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                return (
                    AgentJournalSQLiteStore.columnBlob(stmt, 0),
                    AgentJournalSQLiteStore.columnText(stmt, 1)
                )
            }
            guard let (bytes, storedDigest) = row else { throw AgentJournalError.invalidRecord }
            store.noteReadBytes(bytes.count)
            let expected = AgentJournalSQLiteStore.rowDigest(
                prefix: "audit:\(store.storeID.uuidString):\(sequence):",
                payload: bytes
            )
            guard storedDigest == expected else { throw AgentJournalError.checksumMismatch }
            let record = try AgentJournalSQLiteStore.decodeJSON(AuditRecord.self, from: bytes)
            guard record.sequence == sequence,
                  record.links.storeID == store.storeID,
                  record.links.operationDomain == store.operationDomain,
                  record.digest == store.auditDigest(try record.unsignedBytes()) else {
                throw AgentJournalError.invalidRecord
            }
            return record
        }

        func auditGroupCount(_ key: String) throws -> UInt64 {
            let highWater = try auditHighWater()
            let row: (UInt64, UInt64)? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: "SELECT member_count, last_sequence FROM audit_groups WHERE group_key = ?;"
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, key)
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                return (
                    UInt64(bitPattern: sqlite3_column_int64(stmt, 0)),
                    UInt64(bitPattern: sqlite3_column_int64(stmt, 1))
                )
            }
            guard let (count, lastSeq) = row else { return 0 }
            guard count > 0, count <= highWater, lastSeq <= highWater,
                  try auditGroupMember(key, ordinal: count) == lastSeq else {
                throw AgentJournalError.invalidRecord
            }
            return count
        }

        func auditGroupMember(_ key: String, ordinal: UInt64) throws -> UInt64 {
            let highWater = try auditHighWater()
            guard ordinal > 0 else { throw AgentJournalError.invalidRecord }
            let seq: UInt64? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: "SELECT audit_sequence FROM audit_members WHERE group_key = ? AND ordinal = ?;"
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, key)
                sqlite3_bind_int64(stmt, 2, Int64(bitPattern: ordinal))
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                return UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
            }
            guard let seq, seq > 0, seq <= highWater else {
                throw AgentJournalError.invalidRecord
            }
            return seq
        }

        func auditExportCheckpoint(_ configurationID: String) throws -> JournalAuditExportCheckpoint? {
            let highWater = try auditHighWater()
            let row: (Data, String)? = try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: "SELECT checkpoint_json, digest FROM audit_exports WHERE configuration_id = ?;"
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, configurationID)
                guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                return (
                    AgentJournalSQLiteStore.columnBlob(stmt, 0),
                    AgentJournalSQLiteStore.columnText(stmt, 1)
                )
            }
            guard let (bytes, storedDigest) = row else { return nil }
            store.noteReadBytes(bytes.count)
            let expected = AgentJournalSQLiteStore.rowDigest(
                prefix: "auditexp:\(store.storeID.uuidString):\(configurationID):",
                payload: bytes
            )
            guard storedDigest == expected else { throw AgentJournalError.checksumMismatch }
            let checkpoint = try AgentJournalSQLiteStore.decodeJSON(JournalAuditExportCheckpoint.self, from: bytes)
            guard checkpoint.configurationID == configurationID,
                  checkpoint.throughSequence <= highWater else {
                throw AgentJournalError.invalidRecord
            }
            return checkpoint
        }

        // MARK: Mutations / Publishing

        func publish(_ change: JournalStoreChange) throws {
            guard store.supportsFileContent || change.messages.allSatisfy({ $0.value.files.isEmpty }) else {
                throw AgentJournalError.unsupportedFormat
            }
            guard writable, !didPublish else { throw AgentJournalError.invalidRecord }

            var meta = try store.loadMetaState(on: db)
            let priorHeader = try header(change.sessionID)
            let expectedRev = priorHeader?.revision ?? 0
            let priorCount = priorHeader?.messageCount ?? 0

            guard expectedRev == change.expectedRevision,
                  change.header.revision == expectedRev + 1,
                  !change.records.isEmpty,
                  change.records.first?.sequence == meta.nextRecordSequence,
                  change.records.last?.sequence == meta.nextRecordSequence + UInt64(change.records.count) - 1,
                  change.messageStart <= priorCount,
                  change.header.messageCount == change.messageStart + UInt64(change.messages.count),
                  change.header.messageCount >= priorCount else {
                throw AgentJournalError.concurrentWriter
            }
            guard store.supportsContextHandoff || change.header.contextHandoff == nil else {
                throw AgentJournalError.unsupportedFormat
            }
            guard store.supportsIncompleteContextHandoff || change.header.contextHandoff?.closedTurnProof == nil else {
                throw AgentJournalError.unsupportedFormat
            }
            guard store.supportsNativeContext || (
                change.header.nativeContext == nil
                && change.header.conversationControls == nil
                && !change.messages.contains { message in
                    guard case .assistant(let parts, _) = message.value else { return false }
                    return parts.contains {
                        if case .providerContinuation(let cont) = $0 { return cont.contextTransition != nil }
                        return false
                    }
                }
            ) else {
                throw AgentJournalError.unsupportedFormat
            }

            let hasCheckpoint = change.records.contains {
                if case .checkpoint = $0.event { return true }
                return false
            }
            guard hasCheckpoint || change.messages.isEmpty else {
                throw AgentJournalError.invalidRecord
            }

            let rejections = change.records.compactMap { record -> JournalAdmissionRejection? in
                guard case .toolAdmissionRejected(let callID, let name) = record.event,
                      let runID = record.runID else { return nil }
                return .init(sessionID: record.sessionID, runID: runID, callID: callID, toolName: name)
            }
            guard rejections.count <= 1,
                  rejections.isEmpty || store.supportsAdmissionRejections else {
                throw AgentJournalError.unsupportedFormat
            }
            if let rejection = rejections.first {
                guard !rejection.callID.rawValue.isEmpty,
                      !rejection.toolName.isEmpty,
                      hasCheckpoint,
                      change.messages.contains(where: { msg in
                          if case .assistant(_, let calls) = msg.value {
                              return calls.contains { $0.id == rejection.callID && $0.name == rejection.toolName }
                          }
                          return false
                      }),
                      change.messages.contains(where: { msg in
                          if case .tool(let res) = msg.value {
                              return res.callID == rejection.callID && res.isError
                          }
                          return false
                      }) else {
                    throw AgentJournalError.invalidRecord
                }
            }
            guard change.mutation?.abortConfirmation?.executorProof.map({
                (1...2).contains($0.version) && $0.version <= store.noEffectProofVersion
            }) ?? true else {
                throw AgentJournalError.unsupportedFormat
            }
            guard change.auditRecords.count <= 64,
                  change.auditRecords.isEmpty || store.supportsAuthorizationAudit else {
                throw AgentJournalError.invalidRecord
            }

            let nextSeq = meta.logicalSequence + 1
            var finalHeader = change.header
            finalHeader.historyHead = hasCheckpoint ? nextSeq : priorHeader?.historyHead

            var queueUpdate: (head: JournalFollowUpHead, item: JournalStoredFollowUp)?
            if let admission = change.followUpAdmission {
                let currentHead = try followUpHead(sessionID: change.sessionID)
                let priorItem = try followUp(sessionID: change.sessionID, inputID: admission.inputID)
                if let priorItem, priorItem.state == .withdrawn {
                    throw JournalFollowUpAdmissionError.withdrawn(
                        storeID: store.storeID,
                        sessionID: change.sessionID,
                        inputID: admission.inputID,
                        ordinal: priorItem.ordinal
                    )
                }
                guard currentHead.revision == admission.expectedQueueRevision,
                      currentHead.queuedCount > 0,
                      currentHead.firstQueued != nil,
                      let priorItem,
                      priorItem.state == .queued,
                      currentHead.firstQueued == priorItem.ordinal,
                      let runID = change.records.first?.runID,
                      change.records.allSatisfy({ $0.runID == runID }),
                      let lastMsg = change.messages.last,
                      case .user(let parts) = lastMsg.value,
                      parts.count == 1,
                      case .text(let text) = parts[0],
                      text.utf8.elementsEqual(priorItem.input.text.utf8),
                      currentHead.queuedBytes >= text.utf8.count else {
                    throw AgentJournalError.concurrentWriter
                }
                var updatedHead = currentHead
                updatedHead.revision += 1
                updatedHead.queuedCount -= 1
                updatedHead.queuedBytes -= text.utf8.count
                updatedHead.firstQueued = priorItem.nextQueued
                updatedHead.lastAdmitted = priorItem.ordinal
                if updatedHead.queuedCount == 0 { updatedHead.lastQueued = nil }
                var admittedItem = priorItem
                admittedItem.state = .admitted(runID: runID, formalMessageID: lastMsg.id)
                admittedItem.nextQueued = nil
                queueUpdate = (updatedHead, admittedItem)
            }

            guard !store.supportsRunRecords || !change.admitsNewWork || change.runAdmission != nil else {
                throw AgentJournalError.invalidRecord
            }
            var runEnvelopeToInsert: SQLiteRunEnvelope?
            if let admission = change.runAdmission {
                guard store.supportsRunRecords,
                      change.admitsNewWork,
                      let runID = change.records.first?.runID,
                      change.records.allSatisfy({ $0.runID == runID }),
                      finalHeader.lastRunID == runID,
                      let userMsg = change.messages.last,
                      case .user = userMsg.value,
                      try runRecord(sessionID: change.sessionID, runID: runID) == nil else {
                    throw AgentJournalError.invalidRecord
                }
                if let correlation = admission.correlation,
                   let existing = try runRecord(sessionID: change.sessionID, correlationKey: correlation.key) {
                    if existing.payloadFingerprint == admission.payloadFingerprint {
                        throw AgentRunAdmissionError.alreadyAdmitted(existing.record)
                    }
                    throw AgentRunAdmissionError.conflict(existing.record)
                }
                runEnvelopeToInsert = SQLiteRunEnvelope(
                    storeID: store.storeID,
                    sessionID: change.sessionID,
                    runID: runID,
                    formalMessageID: userMsg.id,
                    formalMessageOrdinal: change.messageStart + UInt64(change.messages.count) - 1,
                    admission: admission,
                    followUpInputID: change.followUpAdmission?.inputID
                )
            }

            var terminalToUpdate: (runID: UUID, terminal: AgentRunTerminal)?
            if let terminal = change.runTerminal {
                guard store.supportsRunRecords,
                      !change.admitsNewWork,
                      let runID = change.records.first?.runID,
                      change.records.allSatisfy({ $0.runID == runID }),
                      change.records.contains(where: {
                          if case .runTerminated(let value) = $0.event { return value == terminal }
                          return false
                      }),
                      try runRecord(sessionID: change.sessionID, runID: runID) != nil,
                      try runTerminal(sessionID: change.sessionID, runID: runID) == nil else {
                    throw AgentJournalError.invalidRecord
                }
                terminalToUpdate = (runID, terminal)
            }

            // Store deduplicated images first.
            var seenDigests: Set<String> = []
            for image in change.messages.flatMap(\.value.images) where seenDigests.insert(image.digest).inserted {
                writtenBytes += UInt64(try store.storeImage(image, on: db))
            }

            // Upsert messages from messageStart.
            for (offset, msg) in change.messages.enumerated() {
                let ord = change.messageStart + UInt64(offset)
                let msgBytes = try AgentJournalSQLiteStore.canonicalJSON(SQLiteMessageEnvelope(msg.value))
                let digest = AgentJournalSQLiteStore.rowDigest(
                    prefix: "msg:\(store.storeID.uuidString):\(change.sessionID.uuidString):\(ord):\(msg.id.uuidString):",
                    payload: msgBytes
                )
                try AgentJournalSQLiteStore.withPrepared(
                    on: db,
                    sql: """
                    INSERT INTO session_messages (session_id, ordinal, message_id, message_json, digest)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(session_id, ordinal) DO UPDATE SET
                        message_id = excluded.message_id,
                        message_json = excluded.message_json,
                        digest = excluded.digest;
                    """
                ) { stmt in
                    AgentJournalSQLiteStore.bindText(stmt, 1, change.sessionID.uuidString)
                    sqlite3_bind_int64(stmt, 2, Int64(bitPattern: ord))
                    AgentJournalSQLiteStore.bindText(stmt, 3, msg.id.uuidString)
                    AgentJournalSQLiteStore.bindBlob(stmt, 4, msgBytes)
                    AgentJournalSQLiteStore.bindText(stmt, 5, digest)
                    try AgentJournalSQLiteStore.stepDone(stmt, on: db)
                }
                writtenBytes += UInt64(msgBytes.count)
            }

            // Upsert session header.
            let headerBytes = try AgentJournalSQLiteStore.canonicalJSON(finalHeader)
            let headerDigest = AgentJournalSQLiteStore.rowDigest(
                prefix: "session:\(store.storeID.uuidString):\(change.sessionID.uuidString):\(finalHeader.revision):",
                payload: headerBytes
            )
            try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: """
                INSERT INTO sessions (session_id, revision, header_json, digest)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    revision = excluded.revision,
                    header_json = excluded.header_json,
                    digest = excluded.digest;
                """
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, change.sessionID.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(bitPattern: finalHeader.revision))
                AgentJournalSQLiteStore.bindBlob(stmt, 3, headerBytes)
                AgentJournalSQLiteStore.bindText(stmt, 4, headerDigest)
                try AgentJournalSQLiteStore.stepDone(stmt, on: db)
            }
            writtenBytes += UInt64(headerBytes.count)

            // Upsert mutation if present.
            if let mutation = change.mutation {
                let mutBytes = try AgentJournalSQLiteStore.canonicalJSON(mutation)
                let key = mutation.intent.idempotencyKey
                let mutDigest = AgentJournalSQLiteStore.rowDigest(
                    prefix: "mutation:\(store.storeID.uuidString):\(key):",
                    payload: mutBytes
                )
                let opKey = AgentJournalSQLiteStore.pendingOperationKey(for: mutation.intent, runID: mutation.runID)
                try AgentJournalSQLiteStore.withPrepared(
                    on: db,
                    sql: """
                    INSERT INTO mutations (
                        idempotency_key, session_id, run_id, call_id, sequence, state, operation_id, mutation_json, digest
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(idempotency_key) DO UPDATE SET
                        session_id = excluded.session_id,
                        run_id = excluded.run_id,
                        call_id = excluded.call_id,
                        sequence = excluded.sequence,
                        state = excluded.state,
                        operation_id = excluded.operation_id,
                        mutation_json = excluded.mutation_json,
                        digest = excluded.digest;
                    """
                ) { stmt in
                    AgentJournalSQLiteStore.bindText(stmt, 1, key)
                    AgentJournalSQLiteStore.bindText(stmt, 2, mutation.sessionID.uuidString)
                    AgentJournalSQLiteStore.bindText(stmt, 3, mutation.runID.uuidString)
                    AgentJournalSQLiteStore.bindText(stmt, 4, mutation.intent.call.id.rawValue)
                    sqlite3_bind_int64(stmt, 5, Int64(bitPattern: mutation.sequence))
                    AgentJournalSQLiteStore.bindText(stmt, 6, mutation.state.rawValue)
                    AgentJournalSQLiteStore.bindOptionalText(stmt, 7, opKey)
                    AgentJournalSQLiteStore.bindBlob(stmt, 8, mutBytes)
                    AgentJournalSQLiteStore.bindText(stmt, 9, mutDigest)
                    try AgentJournalSQLiteStore.stepDone(stmt, on: db)
                }
                writtenBytes += UInt64(mutBytes.count)
            }

            // Upsert admission rejection if present.
            if let rejection = rejections.first {
                let digest = AgentJournalSQLiteStore.rowDigest(
                    prefix: "reject:\(store.storeID.uuidString):\(rejection.sessionID.uuidString):\(rejection.runID.uuidString):\(rejection.callID.rawValue):",
                    payload: Data(rejection.toolName.utf8)
                )
                try AgentJournalSQLiteStore.withPrepared(
                    on: db,
                    sql: """
                    INSERT INTO admission_rejections (session_id, run_id, call_id, tool_name, digest)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(session_id, run_id, call_id) DO UPDATE SET
                        tool_name = excluded.tool_name,
                        digest = excluded.digest;
                    """
                ) { stmt in
                    AgentJournalSQLiteStore.bindText(stmt, 1, rejection.sessionID.uuidString)
                    AgentJournalSQLiteStore.bindText(stmt, 2, rejection.runID.uuidString)
                    AgentJournalSQLiteStore.bindText(stmt, 3, rejection.callID.rawValue)
                    AgentJournalSQLiteStore.bindText(stmt, 4, rejection.toolName)
                    AgentJournalSQLiteStore.bindText(stmt, 5, digest)
                    try AgentJournalSQLiteStore.stepDone(stmt, on: db)
                }
            }

            // Apply follow-up admission if present.
            if let queueUpdate {
                try writeFollowUpHead(queueUpdate.head, sessionID: change.sessionID)
                try writeFollowUpItem(queueUpdate.item)
            }

            // Insert run admission or update run terminal.
            if let runEnv = runEnvelopeToInsert {
                let runBytes = try AgentJournalSQLiteStore.canonicalJSON(runEnv)
                let digest = AgentJournalSQLiteStore.rowDigest(
                    prefix: "run:\(store.storeID.uuidString):\(runEnv.sessionID.uuidString):\(runEnv.runID.uuidString):",
                    payload: runBytes
                )
                try AgentJournalSQLiteStore.withPrepared(
                    on: db,
                    sql: """
                    INSERT INTO run_records (
                        session_id, run_id, correlation_key, formal_ordinal, payload_fingerprint, run_json, terminal_json, digest
                    ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?);
                    """
                ) { stmt in
                    AgentJournalSQLiteStore.bindText(stmt, 1, runEnv.sessionID.uuidString)
                    AgentJournalSQLiteStore.bindText(stmt, 2, runEnv.runID.uuidString)
                    AgentJournalSQLiteStore.bindOptionalText(stmt, 3, runEnv.correlationKey)
                    sqlite3_bind_int64(stmt, 4, Int64(bitPattern: runEnv.formalMessageOrdinal))
                    AgentJournalSQLiteStore.bindText(stmt, 5, runEnv.payloadFingerprint)
                    AgentJournalSQLiteStore.bindBlob(stmt, 6, runBytes)
                    AgentJournalSQLiteStore.bindText(stmt, 7, digest)
                    try AgentJournalSQLiteStore.stepDone(stmt, on: db)
                }
                writtenBytes += UInt64(runBytes.count)
            }

            if let term = terminalToUpdate {
                let existingRunBytes: Data = try AgentJournalSQLiteStore.withPrepared(
                    on: db,
                    sql: "SELECT run_json FROM run_records WHERE session_id = ? AND run_id = ?;"
                ) { stmt in
                    AgentJournalSQLiteStore.bindText(stmt, 1, change.sessionID.uuidString)
                    AgentJournalSQLiteStore.bindText(stmt, 2, term.runID.uuidString)
                    guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else {
                        throw AgentJournalError.invalidRecord
                    }
                    return AgentJournalSQLiteStore.columnBlob(stmt, 0)
                }
                let termBytes = try AgentJournalSQLiteStore.canonicalJSON(term.terminal)
                var combined = existingRunBytes
                combined.append(termBytes)
                let digest = AgentJournalSQLiteStore.rowDigest(
                    prefix: "run:\(store.storeID.uuidString):\(change.sessionID.uuidString):\(term.runID.uuidString):",
                    payload: combined
                )
                try AgentJournalSQLiteStore.withPrepared(
                    on: db,
                    sql: "UPDATE run_records SET terminal_json = ?, digest = ? WHERE session_id = ? AND run_id = ?;"
                ) { stmt in
                    AgentJournalSQLiteStore.bindBlob(stmt, 1, termBytes)
                    AgentJournalSQLiteStore.bindText(stmt, 2, digest)
                    AgentJournalSQLiteStore.bindText(stmt, 3, change.sessionID.uuidString)
                    AgentJournalSQLiteStore.bindText(stmt, 4, term.runID.uuidString)
                    try AgentJournalSQLiteStore.stepDone(stmt, on: db)
                }
                writtenBytes += UInt64(termBytes.count)
            }

            // Append audit records if present.
            if !change.auditRecords.isEmpty {
                try appendAuditRecords(
                    change.auditRecords,
                    expectedFirstAudit: meta.auditHighWater + 1,
                    expectedFirstJournal: meta.nextRecordSequence + UInt64(change.records.count)
                )
                meta.auditHighWater += UInt64(change.auditRecords.count)
            }

            meta.logicalSequence = nextSeq
            meta.nextRecordSequence += UInt64(change.records.count + change.auditRecords.count)
            try store.saveMetaState(meta, on: db)
            didPublish = true
        }

        func publishFollowUp(_ change: JournalFollowUpChange) throws {
            guard store.supportsPerCallFollowUps || change.records.allSatisfy({ $0.input.identity != .perCall }) else {
                throw AgentJournalError.unsupportedFormat
            }
            guard writable, !didPublish, (0...2).contains(change.records.count), change.links.count <= 2 else {
                throw AgentJournalError.invalidRecord
            }
            let current = try followUpHead(sessionID: change.sessionID)
            guard current.revision == change.expectedRevision,
                  change.head.revision == current.revision + 1,
                  change.records.allSatisfy({ $0.sessionID == change.sessionID && $0.ordinal < change.head.nextOrdinal }),
                  Set(change.records.map(\.ordinal)).count == change.records.count,
                  Set(change.links.map(\.ordinal)).count == change.links.count,
                  change.links.allSatisfy({ link in
                      link.ordinal < change.head.nextOrdinal
                          && (link.next.map { $0 > link.ordinal && $0 < change.head.nextOrdinal } ?? true)
                  }) else {
                throw AgentJournalError.concurrentWriter
            }

            var meta = try store.loadMetaState(on: db)
            try writeFollowUpHead(change.head, sessionID: change.sessionID)

            let linkMap = Dictionary(uniqueKeysWithValues: change.links.map { ($0.ordinal, $0.next) })
            let updatedOrdinals = Set(change.records.map(\.ordinal))

            for var record in change.records {
                if let explicitNext = linkMap[record.ordinal] {
                    record.nextQueued = explicitNext
                }
                try writeFollowUpItem(record)
            }

            for link in change.links where !updatedOrdinals.contains(link.ordinal) {
                let existingRow: (Data, UInt64?, String)? = try AgentJournalSQLiteStore.withPrepared(
                    on: db,
                    sql: "SELECT followup_json, next_queued, digest FROM followups WHERE session_id = ? AND ordinal = ?;"
                ) { stmt in
                    AgentJournalSQLiteStore.bindText(stmt, 1, change.sessionID.uuidString)
                    sqlite3_bind_int64(stmt, 2, Int64(bitPattern: link.ordinal))
                    guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return nil }
                    let oldNext: UInt64? = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                        ? nil
                        : UInt64(bitPattern: sqlite3_column_int64(stmt, 1))
                    return (
                        AgentJournalSQLiteStore.columnBlob(stmt, 0),
                        oldNext,
                        AgentJournalSQLiteStore.columnText(stmt, 2)
                    )
                }
                guard let (bytes, oldNext, oldDigest) = existingRow else {
                    throw AgentJournalError.invalidRecord
                }
                let expectedOld = AgentJournalSQLiteStore.rowDigest(
                    prefix: "qitem:\(store.storeID.uuidString):\(change.sessionID.uuidString):\(link.ordinal):\(oldNext.map(String.init) ?? "nil"):",
                    payload: bytes
                )
                guard oldDigest == expectedOld else { throw AgentJournalError.checksumMismatch }
                let newDigest = AgentJournalSQLiteStore.rowDigest(
                    prefix: "qitem:\(store.storeID.uuidString):\(change.sessionID.uuidString):\(link.ordinal):\(link.next.map(String.init) ?? "nil"):",
                    payload: bytes
                )
                try AgentJournalSQLiteStore.withPrepared(
                    on: db,
                    sql: "UPDATE followups SET next_queued = ?, digest = ? WHERE session_id = ? AND ordinal = ?;"
                ) { stmt in
                    if let next = link.next {
                        sqlite3_bind_int64(stmt, 1, Int64(bitPattern: next))
                    } else {
                        sqlite3_bind_null(stmt, 1)
                    }
                    AgentJournalSQLiteStore.bindText(stmt, 2, newDigest)
                    AgentJournalSQLiteStore.bindText(stmt, 3, change.sessionID.uuidString)
                    sqlite3_bind_int64(stmt, 4, Int64(bitPattern: link.ordinal))
                    try AgentJournalSQLiteStore.stepDone(stmt, on: db)
                }
            }

            meta.logicalSequence += 1
            try store.saveMetaState(meta, on: db)
            didPublish = true
        }

        func publishAudit(_ change: JournalAuditChange) throws {
            guard writable, !didPublish, store.supportsAuthorizationAudit,
                  !change.records.isEmpty, change.records.count <= 64 else {
                throw AgentJournalError.invalidRecord
            }
            var meta = try store.loadMetaState(on: db)
            try appendAuditRecords(
                change.records,
                expectedFirstAudit: meta.auditHighWater + 1,
                expectedFirstJournal: meta.nextRecordSequence
            )
            meta.logicalSequence += 1
            meta.nextRecordSequence += UInt64(change.records.count)
            meta.auditHighWater += UInt64(change.records.count)
            try store.saveMetaState(meta, on: db)
            didPublish = true
        }

        func publishAuditExport(_ change: JournalAuditExportChange) throws {
            let previous = try auditExportCheckpoint(change.checkpoint.configurationID)
            let highWater = try auditHighWater()
            guard writable, !didPublish, store.supportsAuthorizationAudit,
                  (previous?.throughSequence ?? 0) == change.expectedThroughSequence,
                  change.checkpoint.throughSequence > change.expectedThroughSequence,
                  change.checkpoint.throughSequence <= highWater,
                  previous.map({ $0.configurationDigest == change.checkpoint.configurationDigest }) ?? true else {
                throw AgentAuthorizationError.invalidAcknowledgement
            }
            var meta = try store.loadMetaState(on: db)
            let bytes = try AgentJournalSQLiteStore.canonicalJSON(change.checkpoint)
            let digest = AgentJournalSQLiteStore.rowDigest(
                prefix: "auditexp:\(store.storeID.uuidString):\(change.checkpoint.configurationID):",
                payload: bytes
            )
            try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: """
                INSERT INTO audit_exports (configuration_id, through_sequence, checkpoint_json, digest)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(configuration_id) DO UPDATE SET
                    through_sequence = excluded.through_sequence,
                    checkpoint_json = excluded.checkpoint_json,
                    digest = excluded.digest;
                """
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, change.checkpoint.configurationID)
                sqlite3_bind_int64(stmt, 2, Int64(bitPattern: change.checkpoint.throughSequence))
                AgentJournalSQLiteStore.bindBlob(stmt, 3, bytes)
                AgentJournalSQLiteStore.bindText(stmt, 4, digest)
                try AgentJournalSQLiteStore.stepDone(stmt, on: db)
            }
            writtenBytes += UInt64(bytes.count)
            meta.logicalSequence += 1
            try store.saveMetaState(meta, on: db)
            didPublish = true
        }

        private func writeFollowUpHead(_ head: JournalFollowUpHead, sessionID: UUID) throws {
            let bytes = try AgentJournalSQLiteStore.canonicalJSON(head)
            let digest = AgentJournalSQLiteStore.rowDigest(
                prefix: "qhead:\(store.storeID.uuidString):\(sessionID.uuidString):\(head.revision):",
                payload: bytes
            )
            try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: """
                INSERT INTO followup_heads (session_id, revision, head_json, digest)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    revision = excluded.revision,
                    head_json = excluded.head_json,
                    digest = excluded.digest;
                """
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, sessionID.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(bitPattern: head.revision))
                AgentJournalSQLiteStore.bindBlob(stmt, 3, bytes)
                AgentJournalSQLiteStore.bindText(stmt, 4, digest)
                try AgentJournalSQLiteStore.stepDone(stmt, on: db)
            }
            writtenBytes += UInt64(bytes.count)
        }

        private func writeFollowUpItem(_ item: JournalStoredFollowUp) throws {
            let bytes = try AgentJournalSQLiteStore.canonicalJSON(SQLiteFollowUpEnvelope(item))
            let digest = AgentJournalSQLiteStore.rowDigest(
                prefix: "qitem:\(store.storeID.uuidString):\(item.sessionID.uuidString):\(item.ordinal):\(item.nextQueued.map(String.init) ?? "nil"):",
                payload: bytes
            )
            try AgentJournalSQLiteStore.withPrepared(
                on: db,
                sql: """
                INSERT INTO followups (session_id, ordinal, input_id, next_queued, followup_json, digest)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id, ordinal) DO UPDATE SET
                    input_id = excluded.input_id,
                    next_queued = excluded.next_queued,
                    followup_json = excluded.followup_json,
                    digest = excluded.digest;
                """
            ) { stmt in
                AgentJournalSQLiteStore.bindText(stmt, 1, item.sessionID.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(bitPattern: item.ordinal))
                AgentJournalSQLiteStore.bindText(stmt, 3, item.input.inputID)
                if let next = item.nextQueued {
                    sqlite3_bind_int64(stmt, 4, Int64(bitPattern: next))
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                AgentJournalSQLiteStore.bindBlob(stmt, 5, bytes)
                AgentJournalSQLiteStore.bindText(stmt, 6, digest)
                try AgentJournalSQLiteStore.stepDone(stmt, on: db)
            }
            writtenBytes += UInt64(bytes.count)
        }

        private func appendAuditRecords(
            _ records: [AuditRecord],
            expectedFirstAudit: UInt64,
            expectedFirstJournal: UInt64
        ) throws {
            for (offset, record) in records.enumerated() {
                let expectedSeq = expectedFirstAudit + UInt64(offset)
                let expectedJournalSeq = expectedFirstJournal + UInt64(offset)
                guard record.sequence == expectedSeq,
                      record.journalRecordSequence == expectedJournalSeq,
                      record.links.storeID == store.storeID,
                      record.links.operationDomain == store.operationDomain,
                      record.digest == store.auditDigest(try record.unsignedBytes()) else {
                    throw AgentJournalError.invalidRecord
                }
                let bytes = try AgentJournalSQLiteStore.canonicalJSON(record)
                let digest = AgentJournalSQLiteStore.rowDigest(
                    prefix: "audit:\(store.storeID.uuidString):\(record.sequence):",
                    payload: bytes
                )
                try AgentJournalSQLiteStore.withPrepared(
                    on: db,
                    sql: "INSERT INTO audit_records (sequence, record_json, digest) VALUES (?, ?, ?);"
                ) { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(bitPattern: record.sequence))
                    AgentJournalSQLiteStore.bindBlob(stmt, 2, bytes)
                    AgentJournalSQLiteStore.bindText(stmt, 3, digest)
                    try AgentJournalSQLiteStore.stepDone(stmt, on: db)
                }
                writtenBytes += UInt64(bytes.count)

                let groups = ["all"] + record.links.indexKeys
                for groupKey in groups {
                    let currentCount: UInt64 = try AgentJournalSQLiteStore.withPrepared(
                        on: db,
                        sql: "SELECT member_count FROM audit_groups WHERE group_key = ?;"
                    ) { stmt in
                        AgentJournalSQLiteStore.bindText(stmt, 1, groupKey)
                        guard try AgentJournalSQLiteStore.stepRow(stmt, on: db) else { return 0 }
                        return UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
                    }
                    let nextOrdinal = currentCount + 1
                    try AgentJournalSQLiteStore.withPrepared(
                        on: db,
                        sql: """
                        INSERT INTO audit_groups (group_key, member_count, last_sequence)
                        VALUES (?, ?, ?)
                        ON CONFLICT(group_key) DO UPDATE SET
                            member_count = excluded.member_count,
                            last_sequence = excluded.last_sequence;
                        """
                    ) { stmt in
                        AgentJournalSQLiteStore.bindText(stmt, 1, groupKey)
                        sqlite3_bind_int64(stmt, 2, Int64(bitPattern: nextOrdinal))
                        sqlite3_bind_int64(stmt, 3, Int64(bitPattern: record.sequence))
                        try AgentJournalSQLiteStore.stepDone(stmt, on: db)
                    }
                    try AgentJournalSQLiteStore.withPrepared(
                        on: db,
                        sql: "INSERT INTO audit_members (group_key, ordinal, audit_sequence) VALUES (?, ?, ?);"
                    ) { stmt in
                        AgentJournalSQLiteStore.bindText(stmt, 1, groupKey)
                        sqlite3_bind_int64(stmt, 2, Int64(bitPattern: nextOrdinal))
                        sqlite3_bind_int64(stmt, 3, Int64(bitPattern: record.sequence))
                        try AgentJournalSQLiteStore.stepDone(stmt, on: db)
                    }
                }
            }
        }
    }
}
