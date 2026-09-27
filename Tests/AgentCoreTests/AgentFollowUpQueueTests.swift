@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import Foundation
import Testing

struct AgentFollowUpQueueTests {
    @Test func fullQueueStillAcceptsAnExistingIdentityAndNeverEvicts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-capacity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "capacity")
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: QueueFixtureProvider()).makeSession(journal: journal)
        for ordinal in 0..<128 {
            let value = AgentFollowUpInput(inputID: "id-\(ordinal)", text: "x",
                                           operationID: "op-\(ordinal)", configurationRef: "v1")
            #expect(try await session.enqueueFollowUp(value).ordinal == UInt64(ordinal))
        }
        let existing = AgentFollowUpInput(inputID: "id-0", text: "x",
                                          operationID: "op-0", configurationRef: "v1")
        #expect(try await session.enqueueFollowUp(existing).ordinal == 0)
        await #expect(throws: AgentFollowUpError.queueFull) {
            try await session.enqueueFollowUp(.init(inputID: "overflow", text: "x",
                operationID: "op-overflow", configurationRef: "v1"))
        }
        #expect(try await session.withdrawFollowUp(inputID: "id-0") == .withdrawn)
        #expect(try await session.enqueueFollowUp(.init(inputID: "next", text: "x",
            operationID: "op-next", configurationRef: "v1")).ordinal == 128)
        #expect(try await session.followUp(inputID: "id-0")?.state == .withdrawn)
        try await journal.close()
    }

    @Test func schemaOneStoreIsRejectedWithoutModificationOrReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-schema1-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = directory.appendingPathComponent("format.json")
        let original = Data("{\"magic\":\"SWIFTAGENT-SEGMENTED-JOURNAL\",\"schema\":1,\"storeID\":\"\(UUID())\",\"domain\":\"old\"}".utf8)
        try original.write(to: format)
        #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try AgentIncrementalJournal.open(at: directory)
        }
        #expect(throws: AgentJournalError.persistenceUnavailable("create requires a new directory")) {
            _ = try AgentIncrementalJournal.create(at: directory, operationDomain: "new")
        }
        #expect(try Data(contentsOf: format) == original)
    }

    @Test func atomicAdmissionPublishesQueueRunAndFormalMessageTogether() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-admit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "admission")
        let sessionID = UUID(), runID = UUID()
        let session = try Agent(model: .init(provider: "queue-fixture", name: "fixed"),
                                provider: QueueFixtureProvider()).makeSession(id: sessionID, journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "one", text: "formal input",
                                               operationID: "logical-one", configurationRef: "current"))
        _ = try await journal.appendStartupCheckpoint([
            .sessionCreated,
            .checkpoint(history: [.user([.text("formal input")])], steeringIDs: []),
            .userMessage("formal input")
        ], sessionID: sessionID, runID: runID, deadline: .now.advanced(by: .seconds(5)),
           durability: .durable, followUpInputID: "one")
        let record = try #require(try await session.followUp(inputID: "one"))
        guard case .admitted(let linkedRun, let formalID) = record.state else {
            Issue.record("missing queue admission"); return
        }
        #expect(linkedRun == runID)
        #expect(try await journal.readMessages(sessionID: sessionID).map(\.id) == [formalID])
        await #expect(throws: AgentJournalError.concurrentWriter) {
            try await journal.appendStartupCheckpoint([
                .checkpoint(history: [.user([.text("formal input")]), .user([.text("duplicated")])], steeringIDs: [])
            ], sessionID: sessionID, runID: UUID(), deadline: .now.advanced(by: .seconds(5)),
               durability: .durable, followUpInputID: "one")
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let persisted = try #require(try await reopened.readMessages(sessionID: sessionID).first)
        #expect(persisted.id == formalID)
        #expect(try await reopened.latestCheckpoint(sessionID: sessionID)?.history == [.user([.text("formal input")])])
        try await reopened.close()
    }

    @Test func durableAcceptDedupConflictWithdrawAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "queue-domain")
        let provider = QueueFixtureProvider()
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let id = UUID()
        let session = try agent.makeSession(id: id, journal: journal)
        let first = AgentFollowUpInput(inputID: "a", text: "first", operationID: "op-a", configurationRef: "v1")
        let second = AgentFollowUpInput(inputID: "b", text: "second", operationID: "op-b", configurationRef: "v1")
        let accepted = try await session.enqueueFollowUp(first)
        #expect(accepted.ordinal == 0)
        #expect(accepted.state == .queued)
        #expect(try await session.enqueueFollowUp(first) == accepted)
        #expect(try await session.enqueueFollowUp(second).ordinal == 1)
        await #expect(throws: AgentFollowUpError.inputConflict) {
            try await session.enqueueFollowUp(.init(inputID: "a", text: "changed", operationID: "op-a", configurationRef: "v1"))
        }
        #expect(await session.history == [])
        #expect(await provider.requests().isEmpty)
        #expect(try await session.withdrawFollowUp(inputID: "a") == .withdrawn)
        #expect(try await session.followUp(inputID: "a")?.state == .withdrawn)
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try agent.makeSession(id: id, journal: reopened)
        #expect(try await restored.followUp(inputID: "a")?.state == .withdrawn)
        #expect(try await restored.followUp(inputID: "b")?.state == .queued)
        #expect(try await restored.followUps(after: nil, limit: 10).map(\.inputID) == ["a", "b"])
        #expect(try await restored.enqueueFollowUp(first).ordinal == 0)
        try await reopened.close()
    }

    @Test func queueOnlyCommitDoesNotInvalidateActiveConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-concurrent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "queue-concurrent")
        let provider = QueueFixtureProvider()
        let agent = try Agent(model: .init(provider: "queue-fixture", name: "fixed"), provider: provider)
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("live")
        let before = try await session.conversationSnapshot()
        _ = try await session.enqueueFollowUp(.init(inputID: "next", text: "later",
            operationID: "logical-later", configurationRef: "current"))
        #expect(try await session.conversationSnapshot().revision == before.revision)
        #expect(try await run.wait().outcome == .completed)
        try await run.waitForDrain()
        #expect(await session.history.contains(.user([.text("live")])))
        #expect(!(await session.history).contains(.user([.text("later")])))
        #expect(try await session.followUp(inputID: "next")?.state == .queued)
        try await journal.close()
    }
}

private actor QueueFixtureRequests {
    var values: [ModelRequest] = []
    func append(_ value: ModelRequest) { values.append(value) }
}

private struct QueueFixtureProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "queue-fixture", capabilities: [.streaming, .multiTurn])
    private let log = QueueFixtureRequests()
    func requests() async -> [ModelRequest] { await log.values }
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await log.append(request)
            let info = ResponseInfo(id: "fixed", model: request.model)
            try emit(.responseStarted(info))
            try emit(.textDelta("done"))
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
        }
    }
}
