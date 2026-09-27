import AgentModels
import Foundation
import Testing
@testable import AgentCore

struct AgentContextPolicyTests {
    @Test func restoredSessionUsesCurrentInstructionsAndKeepsFormalConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("context-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try makeTestJournal(at: directory)
        let sessionID = UUID()
        let first = try Agent(model: fixtureModel,
                              provider: ScriptedProvider { request, _ in textResponse(request, "first") },
                              configuration: .init(instructions: "Version one."))
        let run = try await first.makeSession(id: sessionID, journal: journal).run("remember")
        _ = try await run.wait()
        try await run.waitForDrain()
        try await journal.close()

        let restored = try openTestJournal(at: directory)
        let provider = ScriptedProvider { request, _ in textResponse(request, "second") }
        let next = try Agent(model: fixtureModel, provider: provider,
                             configuration: .init(instructions: "Version two."))
        let continued = try await next.makeSession(id: sessionID, journal: restored).run("continue")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        let request = try #require(await provider.log.requests.first)
        #expect(request.messages.first == .system("Version two."))
        #expect(request.messages.contains(.user([.text("remember")])))
        #expect(request.messages.contains(.assistant(content: [.text("first")], toolCalls: [])))
        #expect(!request.messages.contains(.system("Version one.")))
        #expect(try await restored.readMessages(sessionID: sessionID, limit: 100).count == 4)
        try await restored.close()
    }

    @Test func oversizedInputLeavesTheSessionUsableAndStorageEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oversized-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try makeTestJournal(at: directory)
        let sessionID = UUID()
        let provider = ScriptedProvider { request, _ in textResponse(request, "ok") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(id: sessionID, journal: journal)
        await #expect(throws: AgentContextError.self) {
            _ = try await session.run(String(repeating: "a", count: 17 * 1024 * 1024))
        }
        #expect(try await journal.readMessages(sessionID: sessionID).isEmpty)
        let run = try await session.run("small")
        #expect(try await run.wait().outcome == .completed)
        try await run.waitForDrain()
        try await journal.close()
    }

    @Test func limitDoesNotSilentlySummarizeOrEraseConversation() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "reply") }
        let policy = AgentContextPolicy(maxInputUTF8Bytes: 1024, maxModelContextUTF8Bytes: 350)
        let session = try Agent(model: fixtureModel, provider: provider,
                                configuration: .init(contextPolicy: policy)).makeSession()
        let first = try await session.run("first")
        _ = try? await first.wait()
        try await first.waitForDrain()
        let before = await session.history
        await #expect(throws: AgentContextError.self) {
            _ = try await session.run(String(repeating: "next", count: 100))
        }
        #expect(await session.history == before)
        #expect(!(await session.history).contains { message in
            if case .user(let content) = message, case .text(let text)? = content.first {
                return text.hasPrefix("Conversation summary:")
            }
            return false
        })
    }

    @Test func requestProjectionCanBoundModelInputWhileFormalHistoryKeepsEveryTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("context-projection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try makeTestJournal(at: directory)
        let sessionID = UUID()
        let provider = ScriptedProvider { request, _ in textResponse(request, "ack") }
        let agent = try Agent(model: fixtureModel, provider: provider,
                              configuration: .init(contextPolicy: .init(
                                maxInputUTF8Bytes: 1024, maxModelContextUTF8Bytes: 500)))
        let binding = try AgentModelBinding(profileID: "projection", profileRevision: "1",
                                             model: fixtureModel, provider: provider,
                                             deployment: .init(serviceInstanceID: "fixture",
                                                               endpointScope: "https://fixture.invalid/v1",
                                                               apiDialect: "fixture"),
                                             projector: LastUserProjection())
        let session = try agent.makeSession(id: sessionID, journal: journal)
        for index in 0..<6 {
            let run = try await session.run("turn \(index) " + String(repeating: "x", count: 180), using: binding)
            _ = try await run.wait()
            try await run.waitForDrain()
        }
        let request = try #require(await provider.log.requests.last)
        #expect(request.messages.count == 1)
        #expect(try await journal.readMessages(sessionID: sessionID, limit: 100).count == 12)
        try await journal.close()
        let reopened = try openTestJournal(at: directory)
        #expect(try await reopened.readMessages(sessionID: sessionID, limit: 100).count == 12)
        try await reopened.close()
    }
}

private struct LastUserProjection: AgentContextProjector {
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        let user = input.canonicalMessages.last { $0.role == .user }
        return .init(messages: user.map { [$0] } ?? [], plan: .init(
            projectionID: "latest-user", version: "1",
            sourceRevision: input.conversationRevision,
            sourceDigest: try AgentContextProjectionSource.digest(messages: input.canonicalMessages),
            contextEpoch: input.contextEpoch, lossy: true, reason: "fixture request view"
        ))
    }
}
