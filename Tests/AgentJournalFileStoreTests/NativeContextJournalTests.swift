import Foundation
import Testing
import AgentModels
@testable import AgentCore
@testable import AgentJournalFileStore

@Suite struct NativeContextJournalTests {
    private func candidate(sessionID: UUID, lastID: UUID) -> ModelNativeContextCheckpoint {
        let source = ModelNativeContextSource(sessionID: sessionID, canonicalMessageCount: 2, lastMessageID: lastID,
            canonicalDigest: "source-digest", requestDigest: "actual-request-digest", projectionID: "identity", projectionVersion: "1", previousCheckpointID: nil)
        let transition = ModelNativeContextTransition(mode: .openAIStandalone, source: source, replayPosition: 0,
            invocationID: UUID(), responseID: "compact-response")
        let state = ModelProviderContinuation(model: .init(provider: "openai", name: "fixture"), format: "openai.compact.v1",
            payload: Data(#"{"output":[{"type":"compaction","encrypted_content":"opaque"}]}"#.utf8), contextTransition: transition)
        return .init(id: UUID(), generation: 1, continuation: state, transition: transition, rootConfigurationDigest: "root", toolBaseline: [], usage: .init(inputTokens: 10, outputTokens: 1))
    }
    @Test func nativeStateSurvivesOrdinaryAppendMaintenanceAndReopenWithoutDeletingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID(), run = UUID()
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "native", supportsNativeContext: true)
        #expect(journal.supportsNativeContext)
        let original: [ModelMessage] = [.user([.text("constraint")]), .assistant(content: [.text("answer")], toolCalls: [])]
        try await journal.appendCheckpoint([.sessionCreated, .checkpoint(history: original, steeringIDs: [])], sessionID: session, runID: run, durability: .durable)
        let anchor = try #require(try await journal.readMessages(sessionID: session, after: 1, limit: 1).first)
        let checkpoint = candidate(sessionID: session, lastID: anchor.id)
        let witness = try await journal.historyWitness(sessionID: session)
        try await journal.publishNativeContext(checkpoint, history: original, sessionID: session, runID: nil, expectedHistory: witness)
        let continued = original + [.user([.text("next")])]
        try await journal.appendCheckpoint([.checkpoint(history: continued, steeringIDs: [])], sessionID: session, runID: UUID(), durability: .durable)
        #expect(try await journal.nativeContextCheckpoint(sessionID: session) == checkpoint)
        #expect(try await journal.readMessages(sessionID: session, after: 1, limit: 1).first?.id == anchor.id)
        _ = try await journal.requestMaintenance()
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.nativeContextCheckpoint(sessionID: session) == checkpoint)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == continued)
        try await reopened.close()
    }
    @Test func publicationChecksWitnessAndDefaultOldFormatRejects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-old-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try AgentIncrementalJournal.create(at: directory, operationDomain: "native")
        #expect(!old.supportsNativeContext)
        let session = UUID(); let history: [ModelMessage] = [.user([.text("one")]), .assistant(content: [.text("answer")], toolCalls: [])]
        try await old.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])], sessionID: session, durability: .durable)
        let checkpoint = candidate(sessionID: session, lastID: UUID())
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            try await old.publishNativeContext(checkpoint, history: history, sessionID: session, runID: nil, expectedHistory: old.historyWitness(sessionID: session))
        }
        try await old.close()
        let nativeDirectory = directory.appendingPathComponent("native")
        let native = try AgentIncrementalJournal.create(at: nativeDirectory, operationDomain: "native", supportsNativeContext: true)
        try await native.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])], sessionID: session, durability: .durable)
        let witness = try await native.historyWitness(sessionID: session)
        try await native.appendCheckpoint([.checkpoint(history: history + [.user([.text("new")])], steeringIDs: [])], sessionID: session, durability: .durable)
        await #expect(throws: AgentJournalError.concurrentWriter) {
            try await native.publishNativeContext(checkpoint, history: history, sessionID: session, runID: nil, expectedHistory: witness)
        }
        #expect(try await native.nativeContextCheckpoint(sessionID: session) == nil)
        try await native.close()
    }
    @Test func memoryRejectsForeignAndDuplicateNativeTransitionsAtomically() async throws {
        let journal = AgentJournal()
        let session = UUID()
        let history: [ModelMessage] = [.user([.text("one")]), .assistant(content: [.text("answer")], toolCalls: [])]
        try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])], sessionID: session, durability: .memory)
        let foreign = candidate(sessionID: UUID(), lastID: UUID())
        await #expect(throws: AgentJournalError.invalidRecord) {
            try await journal.appendCheckpoint([.checkpoint(history: history + [.user([.text("must not commit")])], steeringIDs: []), .nativeContextCheckpoint(foreign)], sessionID: session, durability: .memory)
        }
        #expect(try await journal.latestCheckpoint(sessionID: session)?.history == history)
        #expect(try await journal.nativeContextCheckpoint(sessionID: session) == nil)
        let valid = candidate(sessionID: session, lastID: UUID())
        await #expect(throws: AgentJournalError.invalidRecord) {
            try await journal.appendCheckpoint([.nativeContextCheckpoint(valid), .nativeContextCheckpoint(valid)], sessionID: session, durability: .memory)
        }
        #expect(try await journal.nativeContextCheckpoint(sessionID: session) == nil)
        try await journal.appendCheckpoint([.nativeContextCheckpoint(valid)], sessionID: session, durability: .memory)
        await #expect(throws: AgentJournalError.invalidRecord) {
            try await journal.appendCheckpoint([.nativeContextCheckpoint(valid)], sessionID: session, durability: .memory)
        }
        #expect(try await journal.nativeContextCheckpoint(sessionID: session) == valid)
    }

}
