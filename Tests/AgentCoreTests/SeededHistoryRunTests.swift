@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import Foundation
import Testing

/// The first Run of a Session whose earlier conversation was seeded sends it, and the Run's input follows it.
@Suite struct SeededHistoryRunTests {
    @Test(arguments: [false, true]) func theFirstRunAfterASeedSendsTheEarlierConversation(durable: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seed-run-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = durable ? try AgentIncrementalJournal.create(at: directory, operationDomain: "seed-run", supportsRunRecords: true) : AgentJournal()
        let earlier: [ModelMessage] = [.user([.text("Plan a trip to Kyoto")]),
                                       .assistant(content: [.text("Three days in Kyoto.")], toolCalls: [])]
        let id = UUID()
        try await journal.seedHistory(earlier, sessionID: id)
        let provider = ScriptedProvider { request, _ in textResponse(request, "Four days, then.") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(id: id, journal: journal)
        let run = try await session.run("Make it four")
        _ = try await run.wait(); try await run.waitForDrain()
        let sent = try #require(await provider.log.requests.first).messages.filter { $0.role != .system && $0.role != .developer }
        #expect(Array(sent.prefix(2)) == earlier)
        #expect(sent.last == .user([.text("Make it four")]))
        #expect(try await journal.latestCheckpoint(sessionID: id)?.history.count == 4)
        if durable { try await journal.close() }
    }
}
