import AgentCore
import AgentJournalFileStore
import AgentModels
import Foundation
import Testing

struct LoadedHistoryContractTests {
    @Test func snapshotRestoresDurableHistoryAndUsesCurrentInstructions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "loaded-history")
        let provider = ScriptedProvider { request, _ in textResponse(request, "saved") }
        let first = try Agent(model: fixtureModel, provider: provider, instructions: "old instructions").makeSession(journal: journal)
        let run = try await first.run("remember this")
        _ = try await run.wait(); try await run.waitForDrain(); try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try Agent(model: fixtureModel, provider: provider, instructions: "current instructions")
            .makeSession(id: first.id, journal: reopened)
        // Nonempty before restore: this is current configuration, not a disk emptiness signal.
        #expect(await restored.history == [.system("current instructions")])
        let snapshot = try await restored.conversationSnapshot()
        #expect(snapshot.messages == [.system("current instructions"), .user([.text("remember this")]),
                                      .assistant(content: [.text("saved")], toolCalls: [])])
        #expect(await restored.history == snapshot.messages)
        try await reopened.close()
    }

    @Test func snapshotPropagatesRealStoreFailureInsteadOfAnEmptyConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "loaded-history")
        let provider = ScriptedProvider { request, _ in textResponse(request, "saved") }
        let first = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        let run = try await first.run("remember this")
        _ = try await run.wait(); try await run.waitForDrain(); try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try Agent(model: fixtureModel, provider: provider).makeSession(id: first.id, journal: reopened)
        try await reopened.close()
        await #expect(throws: AgentJournalError.storeClosed) { try await restored.conversationSnapshot() }
        #expect(await restored.history.isEmpty)
        #expect(await provider.log.requests.count == 1)
    }
}
