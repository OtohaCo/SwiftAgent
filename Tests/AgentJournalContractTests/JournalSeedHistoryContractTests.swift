@testable import AgentCore
import AgentModels
import Foundation
import Testing

/// A Host that moved a conversation to a new store gives the Session its earlier conversation once, before its first Run.
@Suite struct JournalSeedHistoryContractTests {
    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("journal-contract-\(label)-\(UUID())")
    }

    private let earlier: [ModelMessage] = [
        .user([.text("Plan a trip to Kyoto")]),
        .assistant(content: [.text("Three days: temples, Arashiyama, Nishiki market.")], toolCalls: []),
        .user([.text("Make it four")]),
        .assistant(content: [.text("Add Nara as a day trip.")], toolCalls: []),
    ]

    @Test(arguments: JournalContractBackends.all)
    func anEmptySessionTakesItsEarlierConversationOnceAndKeepsIt(_ backend: any JournalBackendHarness) async throws {
        let directory = tempDir("seed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(at: directory, operationDomain: "seed", capabilities: .init(supportsRunRecords: true))
        let session = UUID()
        try await journal.seedHistory(earlier, sessionID: session)
        #expect(try await journal.latestCheckpoint(sessionID: session)?.history == earlier)
        #expect(try await journal.readMessages(sessionID: session).map(\.message) == earlier)
        // Once: a second seed, or one over a session with history, is refused and changes nothing.
        await #expect(throws: AgentJournalError.concurrentWriter) { try await journal.seedHistory(earlier, sessionID: session) }
        try await journal.close()
        let reopened = try backend.open(at: directory, smallMaintenanceSegments: false)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == earlier)
        try await reopened.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func onlyPlainUserAndAssistantTextIsTaken(_ backend: any JournalBackendHarness) async throws {
        let directory = tempDir("seed-shape")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(at: directory, operationDomain: "seed-shape")
        let call = ToolCall(id: .init(rawValue: "c1"), name: "read", argumentsJSON: "{}", completeness: .complete)
        for refused: [ModelMessage] in [
            [],
            [.assistant(content: [.text("starts with the answer")], toolCalls: [])],
            [.user([.text("read it")]), .assistant(content: [], toolCalls: [call])],
            [.user([.text("x")]), .tool(.init(callID: call.id, content: [.text("result")], isError: false))],
            [.system("you are"), .user([.text("x")])],
        ] {
            await #expect(throws: AgentJournalError.invalidRecord) { try await journal.seedHistory(refused, sessionID: UUID()) }
        }
        let session = UUID()
        try await journal.seedHistory(Array(earlier.prefix(1)), sessionID: session)
        #expect(try await journal.latestCheckpoint(sessionID: session)?.history.count == 1)
        try await journal.close()
    }
}
