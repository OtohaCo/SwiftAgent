@testable import AppleChatIntegration
import AgentCore
import AgentModels
import Foundation
import Testing

struct FixtureConversationTests {
    @Test func fixtureStreamsToolResultAndSecondTurnThroughPublicAPI() async throws {
        let controller = try makeFixtureConversationController(pacing: .immediate)
        var snapshots = controller.snapshots.makeAsyncIterator()
        _ = await snapshots.next()

        _ = try await controller.send("Look up account A-100 and summarize it")
        let finished = await terminalSnapshot(&snapshots)

        #expect(finished.terminal == .completed)
        #expect(finished.items.compactMap(\.tool).contains {
            $0.name == "lookup_account" && $0.state == .completed && !$0.isError
        })
        #expect(finished.items.compactMap(\.assistant).contains {
            $0.text.contains("A-100") && $0.text.contains("active")
        })
    }

    @Test func recoverableFixtureErrorIsVisibleAndRunStillCompletes() async throws {
        let controller = try makeFixtureConversationController(pacing: .immediate)
        var snapshots = controller.snapshots.makeAsyncIterator()
        _ = await snapshots.next()

        _ = try await controller.send("Look up account missing")
        let finished = await terminalSnapshot(&snapshots)

        #expect(finished.terminal == .completed)
        #expect(finished.items.compactMap(\.tool).contains { $0.isError })
        #expect(finished.items.compactMap(\.assistant).contains { $0.text.contains("could not find") })
    }

    @Test func fixtureKeepsRefusalIncompleteAndProtocolFailureDistinct() async throws {
        let cases: [(String, ConversationTerminal)] = [
            ("/refuse", .refused),
            ("/incomplete", .incomplete(.maxOutputTokens)),
            ("/fail", .failed(.provider(.init(kind: .invalidResponse, message: "Fixture protocol failure.")))),
        ]

        for (prompt, expected) in cases {
            let controller = try makeFixtureConversationController(pacing: .immediate)
            var snapshots = controller.snapshots.makeAsyncIterator()
            _ = await snapshots.next()
            _ = try await controller.send(prompt)
            #expect((await terminalSnapshot(&snapshots)).terminal == expected)
        }
    }

    @Test func validatedRouteIsHonestlyReportedAsBuffered() throws {
        let configuration = try makeFixtureConversationConfiguration(route: .validated, pacing: .immediate)
        #expect(!configuration.provider.descriptor.capabilities.contains(.streaming))
        #expect(configuration.mode == .validated)
    }

    @Test func separateConversationsKeepIndependentTranscripts() async throws {
        let accountController = try makeFixtureConversationController(pacing: .immediate)
        let missingController = try makeFixtureConversationController(pacing: .immediate)

        async let account = completedSnapshot(
            from: accountController,
            prompt: "Look up account A-100"
        )
        async let missing = completedSnapshot(
            from: missingController,
            prompt: "Look up account missing"
        )
        let (accountSnapshot, missingSnapshot) = await (try account, try missing)

        #expect(accountSnapshot.conversationID != missingSnapshot.conversationID)
        #expect(accountSnapshot.items.compactMap(\.tool).allSatisfy { !$0.isError })
        #expect(missingSnapshot.items.compactMap(\.tool).contains { $0.isError })
        #expect(accountSnapshot.items.compactMap(\.assistant).contains { $0.text.contains("A-100") })
        #expect(!missingSnapshot.items.compactMap(\.assistant).contains { $0.text.contains("A-100") })
    }
}

private func completedSnapshot(
    from controller: ConversationController,
    prompt: String
) async throws -> ConversationSnapshot {
    var snapshots = controller.snapshots.makeAsyncIterator()
    _ = await snapshots.next()
    _ = try await controller.send(prompt)
    return await terminalSnapshot(&snapshots)
}

private func terminalSnapshot(
    _ iterator: inout AsyncStream<ConversationSnapshot>.Iterator
) async -> ConversationSnapshot {
    while let snapshot = await iterator.next() {
        if snapshot.terminal != nil { return snapshot }
    }
    Issue.record("Snapshot stream ended before terminal outcome")
    return .init(conversationID: UUID())
}

private extension ConversationItem {
    var assistant: DisplayAssistantTurn? {
        guard case .assistant(let value) = self else { return nil }
        return value
    }

    var tool: DisplayToolCall? {
        guard case .tool(let value) = self else { return nil }
        return value
    }
}
