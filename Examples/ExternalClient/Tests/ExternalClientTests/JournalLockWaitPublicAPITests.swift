import AgentCore
import AgentJournalFileStore
import Foundation
import Testing

struct JournalLockWaitPublicAPITests {
    @Test func hostSelectsFiniteWaitUsingOnlyPublicAPI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("public-lock-wait-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await AgentIncrementalJournal.createAsync(at: directory, operationDomain: "public-fixture")
        try await original.close()
        // The original function signature remains source compatible.
        let legacyOpen: (URL, JournalMaintenancePolicy, ContinuousClock.Instant?) async throws -> AgentJournal = AgentIncrementalJournal.openAsync
        let immediate = try await legacyOpen(directory, .default, nil)
        try await immediate.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let waited = try await AgentIncrementalJournal.openAsync(at: directory,
            writerLockWait: .until(deadline), deadline: deadline)
        #expect(waited.storage == .durable)
        try await waited.close()
    }
}
