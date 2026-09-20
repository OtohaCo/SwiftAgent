@testable import AppleChatIntegration
import AgentCore
import AgentModels
import AgentUsage
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
        #expect(finished.currentResponseUsage.inputTokens.reportedSubtotal == 10)
        #expect(finished.currentResponseUsage.outputTokens.reportedSubtotal == 4)
        #expect(finished.items.compactMap(\.assistant).last?.usageSummary.finalizedResponseCount == 1)
        #expect(finished.latestRunUsage.observedResponseCount == 2)
        #expect(finished.latestRunUsage.inputTokens.reportedSubtotal == 22)
        #expect(finished.latestRunUsage.outputTokens.reportedSubtotal == 9)
        #expect(finished.latestRunUsage.totalTokens == 31)
        #expect(finished.sessionUsage == finished.latestRunUsage)
        #expect(finished.usageDiagnosticCount == 0)
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
        #expect(accountSnapshot.sessionUsage.observedResponseCount == 2)
        #expect(missingSnapshot.sessionUsage.observedResponseCount == 2)
        #expect(accountSnapshot.sessionUsage.inputTokens.reportedSubtotal == 22)
        #expect(missingSnapshot.sessionUsage.inputTokens.reportedSubtotal == 22)
    }

    @Test func sessionUsageSurvivesDisplayHistoryTrimmingAndSnapshotReadsDoNotRecount() async throws {
        let controller = try makeFixtureConversationController(
            pacing: .immediate,
            maxDisplayItems: 2
        )
        var snapshots = controller.snapshots.makeAsyncIterator()
        _ = await snapshots.next()

        _ = try await controller.send("Hello")
        _ = await idleSnapshot(&snapshots)
        _ = try await controller.send("Again")
        let idle = await idleSnapshot(&snapshots)
        let firstRead = await controller.snapshot()
        let secondRead = await controller.snapshot()

        #expect(idle.items.count <= 2)
        #expect(idle.sessionUsage.observedResponseCount == 2)
        #expect(idle.sessionUsage.inputTokens.reportedSubtotal == 20)
        #expect(firstRead.sessionUsage == secondRead.sessionUsage)
        #expect(firstRead.sessionUsage == idle.sessionUsage)
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
    var observedTerminal = false
    while let snapshot = await iterator.next() {
        if snapshot.terminal != nil { observedTerminal = true }
        if observedTerminal, snapshot.phase == .idle { return snapshot }
    }
    Issue.record("Snapshot stream ended before terminal outcome drained")
    return .init(conversationID: UUID())
}

private func idleSnapshot(
    _ iterator: inout AsyncStream<ConversationSnapshot>.Iterator
) async -> ConversationSnapshot {
    while let snapshot = await iterator.next() {
        if snapshot.phase == .idle { return snapshot }
    }
    Issue.record("Snapshot stream ended before physical drain")
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
