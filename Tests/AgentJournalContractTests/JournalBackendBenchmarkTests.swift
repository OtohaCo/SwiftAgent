@testable import AgentCore
import AgentJournalFileStore
@testable import AgentJournalSQLiteStore
import AgentModels
import AgentTools
import Foundation
import Testing

@Suite struct JournalBackendBenchmarkTests {
    private static func directorySizeBytes(_ root: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += UInt64(size)
        }
        return total
    }

    /// Opt-in (`SWIFT_AGENT_JOURNAL_BENCHMARK=1`): its hundreds of full-sync commits saturate the disk for about a minute,
    /// which pushes timing-bound suites running beside it in a parallel `swift test` past their deadlines.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFT_AGENT_JOURNAL_BENCHMARK"] == "1"))
    func comparativeBenchmarkAcrossSegmentedFileAndSQLiteBackends() async throws {
        let backends: [any JournalBackendHarness] = [
            SegmentedFileBackendHarness(),
            SQLiteBackendHarness(name: "sqlite-wal-fullsync", durability: .fullSync),
            SQLiteBackendHarness(name: "sqlite-wal-apple-fullfsync", durability: .appleFullFsync),
        ]
        let recordCount = 200
        var rows: [[String: Any]] = []

        for backend in backends {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("journal-bench-\(backend.name)-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }

            let journal = try backend.create(
                at: directory,
                operationDomain: "benchmark",
                smallMaintenanceSegments: false,
                capabilities: .init(supportsPerCallFollowUps: true, supportsRunRecords: true)
            )
            let session = UUID()
            var history: [ModelMessage] = [.user([.text("benchmark seed input")])]
            var commitLatenciesMs: [Double] = []
            commitLatenciesMs.reserveCapacity(recordCount)

            let appendStart = DispatchTime.now().uptimeNanoseconds
            for index in 0..<recordCount {
                let runID = UUID()
                let callID = ToolCallID(rawValue: "call-\(index)")
                let target = EvidenceReference(namespace: "bench", id: "item-\(index)")
                let opKey = "bench-op-\(index)"

                let stepStart = DispatchTime.now().uptimeNanoseconds
                _ = try await journal.admit(.init(
                    sessionID: session,
                    runID: runID,
                    callID: callID,
                    name: "write",
                    argumentsJSON: "{\"index\":\(index)}",
                    resources: [.named(target)],
                    idempotencyKey: opKey,
                    receiptExpectation: try .init(targets: [target], revision: .present)
                ))
                let assistantTurn = ModelMessage.assistant(
                    content: [.text("turn-\(index)-" + String(repeating: "x", count: 160))],
                    toolCalls: [.init(id: callID, name: "write", argumentsJSON: "{\"index\":\(index)}", completeness: .complete)]
                )
                let toolResult = ModelMessage.tool(.init(callID: callID, content: [.text("done-\(index)")], isError: false))
                history.append(assistantTurn)
                history.append(toolResult)
                try await journal.commitMutation(
                    sessionID: session,
                    runID: runID,
                    callID: callID,
                    receipt: ToolReceipt(operationID: opKey, status: .succeeded, confirmedTargets: [target], revision: "r\(index)"),
                    output: .string("done-\(index)"),
                    history: history,
                    steeringIDs: []
                )
                commitLatenciesMs.append(Double(DispatchTime.now().uptimeNanoseconds - stepStart) / 1_000_000)
            }
            let appendTotalMs = Double(DispatchTime.now().uptimeNanoseconds - appendStart) / 1_000_000
            let bytesBeforeMaintenance = Self.directorySizeBytes(directory)
            let fileCountBeforeMaintenance = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?
                .compactMap { $0 as? URL }
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .count) ?? 0

            for _ in 0..<16 {
                if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
            }
            let bytesAfterMaintenance = Self.directorySizeBytes(directory)
            try await journal.close()

            let reopenStart = DispatchTime.now().uptimeNanoseconds
            let reopened = try backend.open(at: directory, smallMaintenanceSegments: false)
            let openMs = Double(DispatchTime.now().uptimeNanoseconds - reopenStart) / 1_000_000

            let recoverStart = DispatchTime.now().uptimeNanoseconds
            let restoredHistory = try #require(try await reopened.latestCheckpoint(sessionID: session)?.history)
            let recoveryMs = Double(DispatchTime.now().uptimeNanoseconds - recoverStart) / 1_000_000
            #expect(restoredHistory.count == 1 + recordCount * 2)
            #expect(try await reopened.pendingMutations(sessionID: session).isEmpty)
            try await reopened.close()

            commitLatenciesMs.sort()
            let opsPerSec = Double(recordCount) / (appendTotalMs / 1000.0)
            rows.append([
                "backend": backend.name,
                "records": recordCount,
                "messagesRecovered": restoredHistory.count,
                "appendTotalMs": round(appendTotalMs * 100) / 100,
                "opsPerSec": round(opsPerSec * 10) / 10,
                "p50TurnMs": round(commitLatenciesMs[recordCount / 2] * 1000) / 1000,
                "p95TurnMs": round(commitLatenciesMs[min(recordCount - 1, recordCount * 95 / 100)] * 1000) / 1000,
                "openMs": round(openMs * 1000) / 1000,
                "recoveryMs": round(recoveryMs * 1000) / 1000,
                "bytesBeforeMaintenance": bytesBeforeMaintenance,
                "bytesAfterMaintenance": bytesAfterMaintenance,
                "filesBeforeMaintenance": fileCountBeforeMaintenance,
            ])
        }

        let jsonData = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        print("JOURNAL_BACKEND_BENCHMARK=" + String(decoding: jsonData, as: UTF8.self))
        #expect(rows.count == 3)
    }
}
