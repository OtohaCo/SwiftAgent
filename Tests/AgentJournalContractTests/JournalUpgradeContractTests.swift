@testable import AgentCore
import AgentModels
import Foundation
import Testing

/// The offline upgrade a Host runs before retiring a turn that did not finish: the same rules on every backend.
@Suite struct JournalUpgradeContractTests {
    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("journal-contract-\(label)-\(UUID())")
    }

    @Test(arguments: JournalContractBackends.all)
    func upgradeToIncompleteContextHandoffKeepsIdentityAndHistory(_ backend: any JournalBackendHarness) async throws {
        let directory = tempDir("upgrade")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(
            at: directory, operationDomain: "upgrade-contract", capabilities: .init(supportsContextHandoff: true)
        )
        #expect(journal.supportsContextHandoff)
        #expect(!journal.supportsIncompleteContextHandoff)
        let identity = try #require(await journal.storeIdentity())
        let session = UUID()
        let history: [ModelMessage] = [.user([.text("before-upgrade-日本語")]), .assistant(content: [.text("reply")], toolCalls: [])]
        _ = try await journal.appendCheckpoint(
            [.checkpoint(history: history, steeringIDs: [])], sessionID: session, runID: UUID(), durability: .durable
        )
        try await journal.close()

        let upgraded = try backend.upgradeForIncompleteContextHandoff(at: directory)
        #expect(upgraded.supportsIncompleteContextHandoff)
        #expect(upgraded.supportsFileContent)
        #expect(upgraded.supportsContextHandoff)
        #expect(await upgraded.storeIdentity() == identity)
        #expect(try await upgraded.latestCheckpoint(sessionID: session)?.history == history)
        try await upgraded.close()

        let reopened = try backend.open(at: directory, smallMaintenanceSegments: false)
        #expect(reopened.supportsIncompleteContextHandoff)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == history)
        try await reopened.close()

        // Already upgraded: refused, and the store is unchanged.
        #expect(throws: AgentJournalError.unsupportedFormat) { _ = try backend.upgradeForIncompleteContextHandoff(at: directory) }
        let after = try backend.open(at: directory, smallMaintenanceSegments: false)
        #expect(after.supportsIncompleteContextHandoff)
        try await after.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func upgradeRefusesAStoreWithoutContextHandoffAndAnOpenOne(_ backend: any JournalBackendHarness) async throws {
        let plain = tempDir("upgrade-plain")
        let held = tempDir("upgrade-held")
        defer {
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: held)
        }
        let journal = try backend.create(at: plain, operationDomain: "upgrade-plain", capabilities: .init(supportsRunRecords: true))
        try await journal.close()
        #expect(throws: AgentJournalError.unsupportedFormat) { _ = try backend.upgradeForIncompleteContextHandoff(at: plain) }
        let reopened = try backend.open(at: plain, smallMaintenanceSegments: false)
        #expect(!reopened.supportsContextHandoff)
        try await reopened.close()

        let owner = try backend.create(at: held, operationDomain: "upgrade-held", capabilities: .init(supportsContextHandoff: true))
        #expect(throws: AgentJournalError.storeInUse) { _ = try backend.upgradeForIncompleteContextHandoff(at: held) }
        #expect(!owner.supportsIncompleteContextHandoff)
        try await owner.close()
    }
}
