@testable import AgentCore
import AgentJournalFileStore
@testable import AgentJournalSQLiteStore
import AgentModels
import Foundation
import SQLite3

struct SQLiteBackendHarness: JournalBackendHarness {
    let name: String
    let durability: SQLiteJournalDurability

    init(name: String = "sqlite-wal", durability: SQLiteJournalDurability = .fullSync) {
        self.name = name
        self.durability = durability
    }

    func create(
        at directory: URL,
        operationDomain: String,
        smallMaintenanceSegments: Bool,
        capabilities: JournalContractCapabilities,
        fault: (@Sendable (JournalContractFaultStage) throws -> Void)?
    ) throws -> AgentJournal {
        if let fault {
            return try AgentSQLiteJournal.createForTesting(
                at: directory,
                operationDomain: operationDomain,
                durability: durability,
                supportsAdmissionRejections: capabilities.supportsAdmissionRejections,
                supportsAuthorizationAudit: capabilities.supportsAuthorizationAudit,
                supportsConfirmedNoEffect: capabilities.supportsConfirmedNoEffect,
                supportsPerCallFollowUps: capabilities.supportsPerCallFollowUps,
                supportsRunRecords: capabilities.supportsRunRecords,
                supportsImageContent: capabilities.supportsImageContent,
                supportsNativeContext: capabilities.supportsNativeContext,
                supportsContextHandoff: capabilities.supportsContextHandoff,
                supportsFileContent: capabilities.supportsFileContent,
                supportsIncompleteContextHandoff: capabilities.supportsIncompleteContextHandoff,
                fault: { stage in
                    switch stage {
                    case .beforeCommit:
                        try fault(.beforeCommit)
                    case .afterCommit:
                        try fault(.afterCommitBeforeAck)
                    case .duringMaintenanceSnapshot:
                        try fault(.duringMaintenanceSnapshot)
                    case .beforeSessionRead:
                        try fault(.beforeSessionRead)
                    }
                }
            )
        }
        return try AgentSQLiteJournal.create(
            at: directory,
            operationDomain: operationDomain,
            durability: durability,
            supportsAdmissionRejections: capabilities.supportsAdmissionRejections,
            supportsAuthorizationAudit: capabilities.supportsAuthorizationAudit,
            supportsConfirmedNoEffect: capabilities.supportsConfirmedNoEffect,
            supportsPerCallFollowUps: capabilities.supportsPerCallFollowUps,
            supportsRunRecords: capabilities.supportsRunRecords,
            supportsImageContent: capabilities.supportsImageContent,
            supportsNativeContext: capabilities.supportsNativeContext,
            supportsContextHandoff: capabilities.supportsContextHandoff,
            supportsFileContent: capabilities.supportsFileContent,
            supportsIncompleteContextHandoff: capabilities.supportsIncompleteContextHandoff
        )
    }

    func createAsync(
        at directory: URL,
        operationDomain: String,
        capabilities: JournalContractCapabilities,
        deadline: ContinuousClock.Instant?
    ) async throws -> AgentJournal {
        try await AgentSQLiteJournal.createAsync(
            at: directory,
            operationDomain: operationDomain,
            durability: durability,
            supportsAdmissionRejections: capabilities.supportsAdmissionRejections,
            supportsAuthorizationAudit: capabilities.supportsAuthorizationAudit,
            supportsConfirmedNoEffect: capabilities.supportsConfirmedNoEffect,
            supportsPerCallFollowUps: capabilities.supportsPerCallFollowUps,
            supportsRunRecords: capabilities.supportsRunRecords,
            supportsImageContent: capabilities.supportsImageContent,
            supportsNativeContext: capabilities.supportsNativeContext,
            supportsContextHandoff: capabilities.supportsContextHandoff,
            supportsFileContent: capabilities.supportsFileContent,
            supportsIncompleteContextHandoff: capabilities.supportsIncompleteContextHandoff,
            deadline: deadline
        )
    }

    func open(at directory: URL, smallMaintenanceSegments: Bool) throws -> AgentJournal {
        try AgentSQLiteJournal.open(at: directory, durability: durability)
    }

    func openAsync(
        at directory: URL,
        writerLockWait: JournalWriterLockWait,
        deadline: ContinuousClock.Instant?
    ) async throws -> AgentJournal {
        let mappedWait: SQLiteJournalLockWait
        switch writerLockWait {
        case .failFast:
            mappedWait = .failFast
        case .until(let end):
            mappedWait = .until(end)
        }
        return try await AgentSQLiteJournal.openAsync(
            at: directory,
            durability: durability,
            writerLockWait: mappedWait,
            deadline: deadline
        )
    }

    func corruptCommittedPayload(at directory: URL) throws {
        let dbURL = directory.appendingPathComponent("journal.sqlite3")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close_v2(db) }
            throw AgentJournalError.persistenceUnavailable("unable to open sqlite file for corruption test")
        }
        defer { sqlite3_close_v2(handle) }
        // Tamper with a stored message row without updating its row SHA-256 digest (simulating B-Tree page bitrot).
        guard sqlite3_exec(
            handle,
            "UPDATE session_messages SET digest = '0000000000000000000000000000000000000000000000000000000000000000';",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw AgentJournalError.persistenceUnavailable("failed to tamper session_messages row")
        }
    }

    func writeUnsupportedSchemaVersion(at directory: URL) throws {
        let dbURL = directory.appendingPathComponent("journal.sqlite3")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close_v2(db) }
            throw AgentJournalError.persistenceUnavailable("unable to open sqlite file for schema test")
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(
            handle,
            "UPDATE store_meta SET schema_version = 999 WHERE singleton = 1;",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw AgentJournalError.persistenceUnavailable("failed to tamper schema_version")
        }
    }

    func corruptStoredImagePayload(at directory: URL) throws {
        let dbURL = directory.appendingPathComponent("journal.sqlite3")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close_v2(db) }
            throw AgentJournalError.persistenceUnavailable("unable to open sqlite file for image corruption test")
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(
            handle,
            "UPDATE images SET data = zeroblob(byte_count);",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw AgentJournalError.persistenceUnavailable("failed to tamper image bytes")
        }
    }
}
