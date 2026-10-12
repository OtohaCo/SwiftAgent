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

    @Test func oversizedReplayTailCannotReplaceEffectiveState() async throws {
        let journal = AgentJournal(), session = UUID()
        let history: [ModelMessage] = [.user([.text("one")]), .assistant(content: [.text("answer")], toolCalls: [])]
        try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])], sessionID: session, durability: .memory)
        let good = candidate(sessionID: session, lastID: UUID())
        let bad = ModelNativeContextCheckpoint(id: good.id, generation: good.generation, continuation: good.continuation,
            transition: good.transition, rootConfigurationDigest: good.rootConfigurationDigest,
            toolBaseline: [], usage: good.usage, canonicalTailStart: Int.max)
        await #expect(throws: AgentJournalError.invalidRecord) {
            try await journal.appendCheckpoint([.nativeContextCheckpoint(bad)], sessionID: session, durability: .memory)
        }
        #expect(try await journal.nativeContextCheckpoint(sessionID: session) == nil)
    }

    @Test func optionalCompactCapabilityDoesNotChangeDefaultSchema3Generation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-disabled-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "disabled")
        let provider = CompactCapableLegacyFixture()
        let agent = try Agent(model: .init(provider: "legacy-fixture", name: "model"), provider: provider)
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("ordinary")
        #expect(try await run.wait().outcome == .completed); try await run.waitForDrain()
        #expect(await provider.requests.first?.nativeContextSource == nil)
        let binding = try AgentModelBinding(profileID: "compact", profileRevision: "1", model: .init(provider: "legacy-fixture", name: "model"),
            provider: provider, deployment: .init(serviceInstanceID: "fixture", endpointScope: "fixture", apiDialect: "fixture"),
            nativeContextPolicy: .init(compactBeforeGeneration: .openAIStandalone))
        await #expect(throws: AgentJournalError.unsupportedFormat) { try await session.compact(mode: .openAIStandalone, using: binding) }
        #expect(await provider.requests.count == 1)
        await #expect(throws: AgentJournalError.unsupportedFormat) { try await session.run("not admitted", using: binding) }
        #expect(await provider.requests.count == 1)
        #expect(try await journal.latestCheckpoint(sessionID: session.id)?.history.count == 2)
        try await journal.close()
    }

}

private actor CompactCapableLegacyFixture: ModelProviderCompaction {
    nonisolated let descriptor = ModelProviderDescriptor(id: "legacy-fixture", capabilities: [.streaming, .multiTurn])
    nonisolated let compactionModes: Set<ModelCompactionMode> = [.openAIStandalone]
    var requests: [ModelRequest] = []
    nonisolated func validateCompaction(request: ModelCompactionRequest) throws {}
    nonisolated func compact(request: ModelCompactionRequest) -> AsyncThrowingStream<ModelCompactionEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentJournalError.unsupportedFormat) }
    }
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { c in Task {
            await record(request)
            let info = ResponseInfo(id: "legacy", model: request.model)
            c.yield(.responseStarted(info)); c.yield(.textDelta("answer"))
            c.yield(.responseCompleted(.init(info: info, content: [.text("answer")], stopReason: .endTurn))); c.finish()
        } }
    }
    func record(_ request: ModelRequest) { requests.append(request) }
}
