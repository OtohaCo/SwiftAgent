import AgentCore
import AgentModels
import Foundation
import Testing

struct AgentJournalUnicodeTests {
    @Test func durableCheckpointRoundTripsChineseJapaneseAndEmoji() async throws {
        let text = "查找资源。検索する。🎯"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-unicode-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = AgentJournal()
        let sessionID = UUID()
        _ = try await journal.appendCheckpoint(
            [
                .userMessage(text),
                .checkpoint(
                    history: [
                        .user([.text(text)]),
                        .assistant(content: [.text("已记录。記録しました。")], toolCalls: []),
                    ],
                    steeringIDs: []
                ),
            ],
            sessionID: sessionID,
            runID: UUID()
        )
        try await journal.persist(to: url)
        let restored = try AgentJournal.load(from: url)
        let checkpoint = try #require(await restored.latestCheckpoint(sessionID: sessionID))
        #expect(checkpoint.history == [
            .user([.text(text)]),
            .assistant(content: [.text("已记录。記録しました。")], toolCalls: []),
        ])
        #expect(checkpoint.history.contains { message in
            guard case .user(let content) = message, case .text(let value)? = content.first else { return false }
            return value.utf8.elementsEqual(text.utf8)
        })
    }
}
