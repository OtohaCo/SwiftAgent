import AgentCore
import AgentModels
import Foundation
import Testing

struct AgentMultiRunContextTests {
    @Test func laterRunSeesTheUserTurnFromThreeRunsEarlier() async throws {
        let provider = ScriptedProvider { request, _ in
            if request.messages.last == .user([.text("What was the first question?")]) {
                let users = request.messages.compactMap { message -> String? in
                    guard case .user(let content) = message, case .text(let text)? = content.first else { return nil }
                    return text
                }
                guard users.contains("alpha-question") else {
                    throw ConversationRecallError.missingEarlierTurn
                }
                return textResponse(request, "The first question was alpha-question")
            }
            return textResponse(request, "ack")
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        for text in ["alpha-question", "beta-question", "gamma-question"] {
            let run = try await session.run(text)
            #expect(try await run.wait().outcome == .completed)
            try await run.waitForDrain()
        }
        let follow = try await session.run("What was the first question?")
        let result = try await follow.wait()
        #expect(result.outcome == .completed)
        let recall = try #require(await provider.log.requests.last)
        #expect(recall.messages.contains(.user([.text("alpha-question")])))
        #expect(recall.messages.contains(.assistant(content: [.text("ack")], toolCalls: [])))
        #expect(recall.messages.contains(.user([.text("beta-question")])))
        #expect(recall.messages.contains(.user([.text("gamma-question")])))
        #expect(recall.messages.last == .user([.text("What was the first question?")]))
        try await follow.waitForDrain()
    }

    @Test func replacementProviderReceivesPortableTranscriptWithoutRequiringOpaqueContinuation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-handoff-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try makeTestJournal(at: url)
        let sessionID = UUID()
        let first = try Agent(
            model: ModelID(provider: "provider-a", name: "one"),
            provider: ScriptedProvider(
                descriptor: .init(id: "provider-a", capabilities: [.streaming, .multiTurn, .tools, .structuredOutput])
            ) { request, _ in textResponse(request, "saved") }
        )
        let original = try first.makeSession(id: sessionID, journal: journal)
        let run = try await original.run("remember portable state")
        _ = try await run.wait()
        try await run.waitForDrain()
        try await journal.close()

        let secondProvider = ScriptedProvider(
            descriptor: .init(id: "provider-b", capabilities: [.streaming, .multiTurn, .tools, .structuredOutput])
        ) { request, _ in
            let roles = request.messages.map(\.role)
            guard roles.contains(.user), roles.contains(.assistant) else {
                throw ConversationRecallError.missingEarlierTurn
            }
            #expect(!request.messages.contains { message in
                if case .assistant(let content, _) = message {
                    return content.contains { if case .providerContinuation = $0 { true } else { false } }
                }
                return false
            })
            return textResponse(request, "handoff-ack")
        }
        let restored = try Agent(
            model: ModelID(provider: "provider-b", name: "two"),
            provider: secondProvider
        ).makeSession(id: sessionID, journal: try openTestJournal(at: url))
        let follow = try await restored.run("continue elsewhere")
        #expect(try await follow.wait().outcome == .completed)
        let request = try #require(await secondProvider.log.requests.first)
        #expect(request.messages.contains(.user([.text("remember portable state")])))
        #expect(request.messages.contains(.assistant(content: [.text("saved")], toolCalls: [])))
        #expect(request.messages.contains(.user([.text("continue elsewhere")])))
        try await follow.waitForDrain()
    }
}

private enum ConversationRecallError: Error {
    case missingEarlierTurn
}
