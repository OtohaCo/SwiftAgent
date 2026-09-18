import AgentModels
import Foundation
import Testing
@testable import AgentCore

struct AgentContextPolicyTests {
    @Test func restoredSessionUsesCurrentInstructionsAndKeepsConversation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-restore-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try AgentJournal(persistenceURL: url)
        let sessionID = UUID()
        let firstProvider = ScriptedProvider { request, _ in textResponse(request, "v1-ack") }
        let first = try Agent(
            model: fixtureModel,
            provider: firstProvider,
            configuration: AgentConfiguration(instructions: "Version one.")
        )
        let original = try first.makeSession(id: sessionID, journal: journal)
        let firstRun = try await original.run("remember this")
        _ = try await firstRun.wait()
        await firstRun.waitForDrain()

        let restartedJournal = try AgentJournal.load(from: url)
        let secondProvider = ScriptedProvider { request, _ in textResponse(request, "v2-ack") }
        let second = try Agent(
            model: fixtureModel,
            provider: secondProvider,
            configuration: AgentConfiguration(instructions: "Version two.")
        )
        let restored = try second.makeSession(id: sessionID, journal: restartedJournal)
        let continued = try await restored.run("continue")
        _ = try await continued.wait()
        await continued.waitForDrain()
        let request = try #require(await secondProvider.log.requests.first)
        #expect(request.messages.first == .system("Version two."))
        #expect(request.messages.filter { $0.role == .system } == [.system("Version two.")])
        #expect(request.messages.contains(.user([.text("remember this")])))
        #expect(request.messages.contains(.assistant(content: [.text("v1-ack")], toolCalls: [])))
        #expect(request.messages.contains(.user([.text("continue")])))
        #expect(!request.messages.contains(.system("Version one.")))
    }

    @Test func longSessionCompactsWithoutDroppingInstructionsOrRecentTurns() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-compact-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try AgentJournal(persistenceURL: url)
        let sessionID = UUID()
        let spy = SpyCompactor()
        let policy = AgentContextPolicy(
            maxInputUTF8Bytes: 1024,
            maxActiveHistoryUTF8Bytes: 900,
            retainedRecentTurnCount: 1,
            compactor: spy
        )
        let provider = ScriptedProvider { request, turn in textResponse(request, "ack-\(turn)") }
        let agent = try Agent(
            model: fixtureModel,
            provider: provider,
            configuration: AgentConfiguration(instructions: "Stay in role.", contextPolicy: policy)
        )
        let session = try agent.makeSession(id: sessionID, journal: journal)
        for index in 1...8 {
            let run = try await session.run(String(repeating: "turn-\(index)-payload-", count: 8))
            _ = try await run.wait()
            await run.waitForDrain()
        }
        #expect(await spy.count >= 1)
        let last = try #require(await provider.log.requests.last)
        #expect(last.messages.first == .system("Stay in role."))
        #expect(last.messages.contains { message in
            if case .user(let content) = message, case .text(let text)? = content.first {
                return text.contains("Conversation summary:")
            }
            return false
        })
        let checkpoint = await journal.latestCheckpoint(sessionID: sessionID)
        let encoded = try JSONEncoder().encode(checkpoint?.history ?? [])
        #expect(encoded.count <= 900)

        let restartedJournal = try AgentJournal.load(from: url)
        let restoredProvider = ScriptedProvider { request, _ in textResponse(request, "restored") }
        let restoredAgent = try Agent(
            model: fixtureModel,
            provider: restoredProvider,
            configuration: AgentConfiguration(instructions: "Stay in role.", contextPolicy: policy)
        )
        let restoredRun = try await restoredAgent.makeSession(id: sessionID, journal: restartedJournal).run("after compact")
        _ = try await restoredRun.wait()
        await restoredRun.waitForDrain()
        let restoredRequest = try #require(await restoredProvider.log.requests.first)
        #expect(restoredRequest.messages.first == .system("Stay in role."))
        #expect(restoredRequest.messages.contains(.user([.text("after compact")])))
    }

    @Test func oversizedSingleInputFailsFastAndLeavesTheSessionUsable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-input-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try AgentJournal(persistenceURL: url)
        let provider = ScriptedProvider { request, _ in textResponse(request, "ok") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        let oversized = String(repeating: "a", count: 17 * 1024 * 1024)
        do {
            _ = try await session.run(oversized)
            Issue.record("A 17 MiB input must fail before the Session is used")
        } catch let error as AgentContextError {
            guard case .inputTooLarge(let bytes, let limit) = error else {
                Issue.record("Expected inputTooLarge, got \(error)")
                return
            }
            #expect(bytes == 17 * 1024 * 1024)
            #expect(limit == 8 * 1024 * 1024)
        }
        #expect(await session.history == [])
        #expect(await journal.snapshot().isEmpty)
        let run = try await session.run("small")
        #expect(try await run.wait().outcome == .completed)
        await run.waitForDrain()
    }

    @Test func contextWindowKeepsUnresolvedToolPairs() {
        let call = ToolCall(id: .init(rawValue: "open"), name: "search", argumentsJSON: "{}", completeness: .complete)
        let history: [ModelMessage] = [
            .system("Now."),
            .user([.text("old")]),
            .assistant(content: [.text("done")], toolCalls: []),
            .user([.text("open work")]),
            .assistant(content: [], toolCalls: [call]),
        ]
        let split = AgentContextWindow.split(history, retainingRecentTurns: 1)
        #expect(!split.dropped.contains { message in
            if case .assistant(_, let calls) = message { return calls.contains(where: { $0.id == call.id }) }
            return false
        })
        #expect(split.retained.contains { message in
            if case .assistant(_, let calls) = message { return calls.contains(where: { $0.id == call.id }) }
            return false
        })
        #expect(split.retained.contains(.user([.text("open work")])))
    }

    @Test func uncompactableRetainedWindowFailsAsHistoryTooLarge() async throws {
        let policy = AgentContextPolicy(
            maxInputUTF8Bytes: 2_000,
            maxActiveHistoryUTF8Bytes: 180,
            retainedRecentTurnCount: 1
        )
        let session = try Agent(
            model: fixtureModel,
            provider: ScriptedProvider { request, _ in textResponse(request, "ack") },
            configuration: AgentConfiguration(contextPolicy: policy)
        ).makeSession()
        do {
            _ = try await session.run(String(repeating: "n", count: 400)).wait()
            Issue.record("A retained turn larger than the history limit must fail")
        } catch let error as AgentContextError {
            guard case .historyTooLarge = error else {
                Issue.record("Expected historyTooLarge, got \(error)")
                return
            }
        }
    }
}

actor SpyCompactor: AgentContextCompactor {
    private(set) var count = 0

    func summarize(droppedConversation: [ModelMessage]) async throws -> AgentCompactionSummary {
        count += 1
        return AgentCompactionSummary(goal: "Continue.", decisions: ["Keep recent turns"])
    }
}
