import Testing
import Foundation
import AgentJournalFileStore
import AgentModels
@testable import AgentCore

struct PaginationContractTests {
    @Test func messageAfterIsInclusiveAndQueueAfterIsExclusiveIncludingReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pagination-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "pagination")
        let provider = ScriptedProvider { request, _ in textResponse(request, "answer") }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let session = try agent.makeSession(journal: journal)
        for input in ["one", "two"] {
            let run = try await session.run(input)
            _ = try await run.wait(); try await run.waitForDrain()
        }
        for input in ["a", "b", "c"] {
            _ = try await session.enqueueFollowUp(.init(inputID: input, text: input, operationID: input, configurationRef: "1"))
        }
        try await check(journal: journal, session: session)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try agent.makeSession(id: session.id, journal: reopened)
        try await check(journal: reopened, session: restored)
        try await reopened.close()
    }
    private func check(journal: AgentJournal, session: AgentSession) async throws {
        let all = try await journal.readMessages(sessionID: session.id, after: 0, limit: 100)
        #expect(all.count == 4)
        #expect(try await journal.readMessages(sessionID: session.id, after: 0, limit: 1) == [all[0]])
        #expect(try await journal.readMessages(sessionID: session.id, after: 1, limit: 1) == [all[1]])
        #expect(try await journal.readMessages(sessionID: session.id, after: 3, limit: 2) == [all[3]])
        #expect(try await journal.readMessages(sessionID: session.id, after: 4, limit: 1).isEmpty)
        #expect(try await session.followUps(after: nil, limit: 1).map(\.ordinal) == [0])
        #expect(try await session.followUps(after: 0, limit: 1).map(\.ordinal) == [1])
        #expect(try await session.followUps(after: 1, limit: 2).map(\.ordinal) == [2])
        #expect(try await session.followUps(after: 2, limit: 1).isEmpty)
    }
}
