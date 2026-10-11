@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import Foundation
import Testing

struct StaleJournalBaselineTests {
    @Test(arguments: ["three", "two"], [false, true])
    func oldSessionRejectsSeriallyChangedHistory(nextInput: String, records: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "stale-baseline", supportsRunRecords: records)
        let provider = ScriptedProvider { request, turn in
            if turn == 2 { throw FixtureError.invalidOperation }
            return textResponse(request, "answer \(turn)")
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let id = UUID()
        let a = try agent.makeSession(id: id, journal: journal)
        let one = try await a.run("one")
        _ = try await one.wait()
        try await one.waitForDrain()
        let b = try agent.makeSession(id: id, journal: journal)
        let two = try await b.run("two")
        await #expect(throws: FixtureError.self) { try await two.wait() }
        try await two.waitForDrain()
        let before = try await journal.latestCheckpoint(sessionID: id)?.history
        let correlation = records ? try AgentRunCorrelation(key: "stale", payloadDigest: "input") : nil
        do {
            let stale = try await a.run(nextInput, correlation: correlation)
            _ = try await stale.wait()
            try await stale.waitForDrain()
            Issue.record("stale Run unexpectedly admitted; Provider messages: \(await provider.log.requests.last!.messages); Journal: \(try await journal.latestCheckpoint(sessionID: id)!.history)")
        } catch AgentJournalError.concurrentWriter {
            // Expected local rejection, before input admission and dispatch.
        }

        #expect(await provider.log.requests.count == 2)
        #expect(try await journal.latestCheckpoint(sessionID: id)?.history == before)
        if records { #expect(try await journal.runRecord(sessionID: id, correlationKey: "stale") == .notAdmitted) }
        let fresh = try agent.makeSession(id: id, journal: journal)
        let three = try await fresh.run(nextInput)
        let completed = try await three.wait()
        try await three.waitForDrain()
        #expect(completed.history == before! + [.user([.text(nextInput)]), .assistant(content: [.text("answer 3")], toolCalls: [])])
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: id)?.history == completed.history)
        try await reopened.close()
    }

    @Test func ownCheckpointsMetadataOtherSessionsAndMaintenanceKeepWitnessValid() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "stable-witness")
        let provider = ScriptedProvider { request, turn in textResponse(request, "answer \(turn)") }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let a = try agent.makeSession(journal: journal)
        let first = try await a.run("one")
        _ = try await first.wait()
        try await first.waitForDrain()
        _ = try await journal.append(.modelAttempt(turn: 9, model: fixtureModel), sessionID: a.id)
        let other = try agent.makeSession(journal: journal)
        let otherRun = try await other.run("unrelated")
        _ = try await otherRun.wait()
        try await otherRun.waitForDrain()
        _ = try await journal.requestMaintenance()
        let second = try await a.run("two")
        let result = try await second.wait()
        try await second.waitForDrain()
        #expect(result.history == [.user([.text("one")]), .assistant(content: [.text("answer 1")], toolCalls: []), .user([.text("two")]), .assistant(content: [.text("answer 3")], toolCalls: [])])
        try await journal.close()
    }

    @Test func startupPublicationRechecksWitnessAfterPreflight() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "publication-witness", supportsRunRecords: true)
        let id = UUID()
        let provider = ScriptedProvider { request, _ in textResponse(request, "unexpected") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(id: id, journal: journal,
            startupCommitWillBegin: { _ in
                do {
                    _ = try await journal.appendCheckpoint([.checkpoint(history: [.user([.text("external")])], steeringIDs: [])],
                        sessionID: id, runID: UUID(), durability: .durable)
                } catch { Issue.record("fixture publication failed: \(error)") }
            })
        let correlation = try AgentRunCorrelation(key: "blocked", payloadDigest: "input")
        await #expect(throws: AgentJournalError.concurrentWriter) { try await session.run("ours", correlation: correlation) }
        #expect(await provider.log.requests.isEmpty)
        #expect(try await journal.latestCheckpoint(sessionID: id)?.history == [.user([.text("external")])])
        #expect(try await journal.runRecord(sessionID: id, correlationKey: "blocked") == .notAdmitted)
        try await journal.close()
    }
}
