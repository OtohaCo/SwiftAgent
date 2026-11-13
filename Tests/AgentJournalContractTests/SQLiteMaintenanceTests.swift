@testable import AgentCore
@testable import AgentJournalSQLiteStore
import AgentModels
import Foundation
import Testing
#if canImport(SQLite3)
import SQLite3
#else
import CAgentSQLite
#endif

/// Background maintenance must stop once it has nothing left to relieve; otherwise every open journal spins a core.
@Suite struct SQLiteMaintenanceTests {
    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("journal-sqlite-maintenance-\(label)-\(UUID())")
    }

    private func walBytes(_ directory: URL) -> UInt64 {
        let path = directory.appendingPathComponent("journal.sqlite3").path + "-wal"
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
    }

    private func sqliteStore(_ journal: AgentJournal) async throws -> AgentJournalSQLiteStore {
        try #require(await journal.store as? AgentJournalSQLiteStore)
    }

    /// Waits (bounded) until no `maintain()` run starts for `quietPeriod`; returns the run count at that point.
    private func waitUntilQuiet(
        _ store: AgentJournalSQLiteStore,
        quietPeriod: Duration = .milliseconds(300),
        timeout: Duration = .seconds(10)
    ) async throws -> UInt64? {
        let deadline = ContinuousClock.now + timeout
        var last = store.maintenanceRuns()
        var quietSince = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            let current = store.maintenanceRuns()
            if current != last {
                last = current
                quietSince = ContinuousClock.now
            } else if ContinuousClock.now - quietSince >= quietPeriod {
                return current
            }
        }
        return nil
    }

    @Test func maintenanceGoesQuietAfterSmallWrites() async throws {
        let directory = tempDir("small")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentSQLiteJournal.create(at: directory, operationDomain: "maintenance-quiet")
        let store = try await sqliteStore(journal)
        let session = UUID()
        var history: [ModelMessage] = []
        for index in 0..<5 {
            history.append(.user([.text("message-\(index)")]))
            _ = try await journal.appendCheckpoint(
                [.checkpoint(history: history, steeringIDs: [])],
                sessionID: session,
                runID: UUID(),
                durability: .durable
            )
        }

        let before = store.maintenanceRuns()
        try await Task.sleep(for: .milliseconds(1_500))
        let during = store.maintenanceRuns() - before
        #expect(during <= 3, "maintenance ran \(during) times in 1.5 s without new writes")
        let settled = try await waitUntilQuiet(store, timeout: .seconds(2))
        #expect(settled != nil, "maintenance never went idle")
        try await journal.close()
    }

    @Test func largeWriteBurstIsCheckpointedThenMaintenanceStops() async throws {
        let directory = tempDir("burst")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentSQLiteJournal.create(at: directory, operationDomain: "maintenance-burst")
        let store = try await sqliteStore(journal)
        let threshold = AgentJournalSQLiteStore.walMaintenanceThresholdBytes
        let session = UUID()
        // Random text so neither compression nor deduplication keeps the WAL small.
        func chunk() -> String {
            Data((0..<(192 * 1024)).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        }
        var history: [ModelMessage] = []
        var peakWal: UInt64 = 0
        var index = 0
        while peakWal <= threshold, index < 200 {
            history.append(.user([.text("burst-\(index)-" + chunk())]))
            _ = try await journal.appendCheckpoint(
                [.checkpoint(history: history, steeringIDs: [])],
                sessionID: session,
                runID: UUID(),
                durability: .durable
            )
            peakWal = max(peakWal, walBytes(directory))
            index += 1
        }
        #expect(peakWal > threshold, "the burst should have grown the WAL past the maintenance threshold")

        let settled = try #require(try await waitUntilQuiet(store), "maintenance never went idle after the burst")
        #expect(settled >= 1, "a WAL above the threshold must trigger maintenance")
        #expect(walBytes(directory) < threshold, "maintenance should shrink the WAL, left \(walBytes(directory)) bytes")
        let status = try #require(try await journal.storeStatus())
        #expect(status.sealedSegments == 0)

        try await Task.sleep(for: .milliseconds(1_000))
        #expect(store.maintenanceRuns() - settled <= 1, "maintenance restarted itself after the WAL was checkpointed")

        #expect(try await journal.latestCheckpoint(sessionID: session)?.history == history)
        try await journal.close()
    }

    @Test func readerHoldingTheWALDoesNotMakeMaintenanceSpin() async throws {
        let directory = tempDir("reader")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentSQLiteJournal.create(at: directory, operationDomain: "maintenance-reader")
        let store = try await sqliteStore(journal)
        let threshold = AgentJournalSQLiteStore.walMaintenanceThresholdBytes
        let session = UUID()
        _ = try await journal.appendCheckpoint(
            [.checkpoint(history: [.user([.text("seed")])], steeringIDs: [])],
            sessionID: session,
            runID: UUID(),
            durability: .durable
        )

        // An outside reader keeps an open snapshot, so no checkpoint can reset or truncate the WAL.
        var reader: OpaquePointer?
        let dbPath = directory.appendingPathComponent("journal.sqlite3").path
        #expect(sqlite3_open_v2(dbPath, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(reader) }
        #expect(sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM store_meta;", nil, nil, nil) == SQLITE_OK)

        var history: [ModelMessage] = [.user([.text("seed")])]
        var index = 0
        while walBytes(directory) <= threshold + threshold / 2, index < 200 {
            history.append(.user([.text("held-\(index)-" + Data((0..<(192 * 1024)).map { _ in
                UInt8.random(in: 0...255)
            }).base64EncodedString())]))
            _ = try await journal.appendCheckpoint(
                [.checkpoint(history: history, steeringIDs: [])],
                sessionID: session,
                runID: UUID(),
                durability: .durable
            )
            index += 1
        }
        #expect(walBytes(directory) > threshold)

        let settled = try #require(try await waitUntilQuiet(store), "maintenance spun while a reader held the WAL")
        #expect(walBytes(directory) > threshold, "the held reader should have kept the WAL from shrinking")
        try await Task.sleep(for: .milliseconds(1_000))
        #expect(store.maintenanceRuns() - settled <= 1, "maintenance restarted itself while the reader held the WAL")

        sqlite3_exec(reader, "COMMIT;", nil, nil, nil)
        _ = try await journal.requestMaintenance()
        #expect(walBytes(directory) < threshold, "once the reader is gone maintenance should shrink the WAL")
        #expect(try await journal.latestCheckpoint(sessionID: session)?.history == history)
        try await journal.close()
    }
}
