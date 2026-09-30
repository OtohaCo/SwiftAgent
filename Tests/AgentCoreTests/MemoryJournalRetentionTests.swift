import AgentCore
import AgentModels
import Foundation
import Testing

struct MemoryJournalRetentionTests {
    @Test(arguments: [1_000, 2_000, 4_000]) func onlyLatestFullHistoryIsRetained(_ count: Int) async throws {
        let journal = AgentJournal(), sessionID = UUID()
        var history: [ModelMessage] = []
        for index in 0..<count {
            history.append(.user([.text("m\(index)")]))
            _ = try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])],
                sessionID: sessionID, runID: UUID(), durability: .memory)
        }
        let checkpoint = try #require(try await journal.latestCheckpoint(sessionID: sessionID))
        #expect(checkpoint.history == history)
        let retained = await journal.memoryRetentionStatistics()
        #expect(retained.checkpointArrays == 1)
        #expect(retained.messageSlots == count)
        #expect(retained.sessionStates == 1)
        #expect(retained.runIdentities == count)
    }

    @Test func sessionsSequencesSteeringAndRunIdentityRemainIndependent() async throws {
        let journal = AgentJournal(), a = UUID(), b = UUID(), first = UUID(), second = UUID(), steering = UUID()
        let start = try await journal.appendCheckpoint([.sessionCreated, .checkpoint(history: [.user([.text("a")])], steeringIDs: [steering])], sessionID: a, runID: first)
        #expect(start.map(\.sequence) == [1, 2])
        _ = try await journal.append(.sessionCreated, sessionID: b, runID: second)
        let changed = try await journal.appendCheckpointForCurrentRun([.checkpoint(history: [.user([.text("a")]), .assistant(content: [.text("answer")], toolCalls: [])], steeringIDs: [steering])], sessionID: a, runID: first)
        #expect(changed.map(\.sequence) == [4])
        #expect(try await journal.hasSessionCreated(a))
        #expect(try await journal.hasSessionCreated(b))
        #expect(try await journal.hasRun(first, sessionID: a))
        #expect(!(try await journal.hasRun(first, sessionID: b)))
        _ = try await journal.append(.runCompleted(.completed), sessionID: a, runID: second)
        await #expect(throws: CancellationError.self) {
            _ = try await journal.appendCheckpointForCurrentRun([.checkpoint(history: [], steeringIDs: [])], sessionID: a, runID: first)
        }
        #expect(try await journal.hasRun(first, sessionID: a))
        #expect(try await journal.latestCheckpoint(sessionID: a)?.steeringIDs == [steering])
        #expect(try await journal.latestCheckpoint(sessionID: a)?.history.count == 2)
        #expect(try await journal.latestCheckpoint(sessionID: b) == nil)
        let restored = try Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in textResponse(request, "ok") }).makeSession(id: a, journal: journal)
        #expect(try await restored.conversationSnapshot().messages.count == 2)
    }

    @Test func realSessionsKeepTheirEntireConversationAcrossRunsAndRestore() async throws {
        let journal = AgentJournal()
        let agent = try Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in textResponse(request, "ack") })
        let first = try agent.makeSession(journal: journal), other = try agent.makeSession(journal: journal)
        for index in 0..<30 {
            for session in [first, other] {
                let run = try await session.run("turn-\(index)")
                _ = try await run.wait(); try await run.waitForDrain()
            }
        }
        let restored = try agent.makeSession(id: first.id, journal: journal)
        let snapshot = try await restored.conversationSnapshot()
        #expect(snapshot.messages.count == 60)
        #expect(snapshot.messages.first == .user([.text("turn-0")]))
        #expect(snapshot.messages.last == .assistant(content: [.text("ack")], toolCalls: []))
        let retained = await journal.memoryRetentionStatistics()
        #expect(retained.checkpointArrays == 2)
        #expect(retained.messageSlots == 120)
    }
}
