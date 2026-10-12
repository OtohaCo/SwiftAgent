@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentProviders
import AgentTools
import Foundation
import Testing

struct AnthropicReminderPublicationTests {
    @Test func pendingAddedDuringSummaryCannotPublishReminderException() async throws {
        let host = AnthropicHostCompactionTests()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-cas-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "host", supportsNativeContext: true)
        let probe = ProviderRequestProbe(), gate = HostSummaryGate()
        let adapter = try AnthropicProvider(apiKey: "fixture", thinking: .serviceDefault,
            nativeContext: .init(qualification: .init(endpoint: host.endpoint, resolvedModelNames: [host.model.name], modes: [.anthropicOnDemand]), runReminders: true),
            transport: HostSummaryTransport(probe: probe, bodies: [host.fixture(anthropicTextFixture), host.fixture(try host.summary()), host.fixture(try host.summary())], gate: gate))
        let session = try Agent(binding: host.binding(adapter)).makeSession(journal: journal)
        let run = try await session.run("user", contextControls: .init(reminder: "required reminder"))
        _ = try await run.wait(); try await run.waitForDrain()
        let first = try await session.compact(mode: .anthropicOnDemand)
        let checkpoint = try #require(try await first.wait().checkpoint); try await first.waitForDrain()
        let witness = try await journal.historyWitness(sessionID: session.id)
        let operation = try await session.compact(mode: .anthropicOnDemand)
        await gate.waitEntered()
        let call = ToolCall(id: .init(rawValue: "late-pending"), name: "mutate", argumentsJSON: "{}", completeness: .complete)
        // Package fault seam changes real File Journal metadata, not canonical history.
        let intent = try PendingMutationIntent(call: call, resources: [.global], idempotencyKey: "late-pending",
            receiptExpectation: .init(targets: [.init(namespace: "fixture", id: "late")]))
        try await journal.append(.pendingMutation(intent), sessionID: session.id, runID: run.id, durability: .durable)
        #expect(try await journal.historyWitness(sessionID: session.id) == witness)
        await gate.release()
        do { _ = try await operation.wait(); Issue.record("published after pending invalidated the exception") }
        catch let error as AgentJournalError { #expect(error == .concurrentWriter) }
        try await operation.waitForDrain()
        #expect(try await journal.nativeContextCheckpoint(sessionID: session.id) == checkpoint)
        #expect(try await journal.pendingMutations().count == 1)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.nativeContextCheckpoint(sessionID: session.id) == checkpoint)
        #expect(try await reopened.pendingMutations().count == 1)
        try await reopened.close()
    }
}
