import AgentModels
import Foundation
import Testing
import XCTest
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
        try await firstRun.waitForDrain()

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
        try await continued.waitForDrain()
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
            try await run.waitForDrain()
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
        try await restoredRun.waitForDrain()
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
        try await run.waitForDrain()
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

    @Test func syntheticSummaryDoesNotCountAsARecentUserTurn() {
        let summary = AgentContextWindow.summaryMessage(.init(goal: "Earlier work"))
        let oldUser = ModelMessage.user([.text("real old turn")])
        let history: [ModelMessage] = [
            summary,
            oldUser,
            .assistant(content: [.text("old answer")], toolCalls: []),
            .user([.text("recent turn")]),
        ]

        let split = AgentContextWindow.split(history, retainingRecentTurns: 2)

        #expect(split.dropped == [summary])
        #expect(split.retained.first == oldUser)
    }

    @Test func lossyCompactorDoesNotCountASyntheticSummaryAsAUserTurn() async throws {
        let summary = AgentContextWindow.summaryMessage(.init(goal: "Earlier work"))
        let compacted = try await AgentRetainedTurnCompactor().summarize(droppedConversation: [
            summary,
            .user([.text("real turn")]),
            .assistant(content: [.text("answer")], toolCalls: []),
        ])

        #expect(compacted.openWork == ["1 earlier user turn(s) were compacted."])
    }

    @Test func midRunToolCheckpointFeedsCompactedHistoryIntoTheNextModelRequest() async throws {
        let spy = SpyCompactor()
        let policy = AgentContextPolicy(
            maxInputUTF8Bytes: 4_096,
            maxActiveHistoryUTF8Bytes: 900,
            retainedRecentTurnCount: 1,
            compactor: spy
        )
        let call = addition("compact-mid-run")
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1:
                return textResponse(request, String(repeating: "old-answer-", count: 18))
            case 2:
                return toolResponse(request, [call])
            default:
                #expect(request.messages.contains { AgentContextWindow.isSyntheticConversationSummary($0) })
                #expect(!request.messages.contains(.user([.text(String(repeating: "old-user-", count: 18))])))
                #expect(request.messages.contains(.assistant(content: [], toolCalls: [call])))
                #expect(request.messages.contains(.tool(.init(
                    callID: call.id,
                    content: [.json(.object(["sum": .number(5)]))],
                    isError: false
                ))))
                return textResponse(request, "done")
            }
        }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [AddTool(log: EffectLog())],
            configuration: AgentConfiguration(contextPolicy: policy)
        ).makeSession()

        _ = try await session.run(String(repeating: "old-user-", count: 18)).wait()
        let result = try await session.run(String(repeating: "new-user-", count: 18)).wait()

        #expect(result.outcome == AgentLoopOutcome.completed)
        #expect(await spy.count == 1)
        let sessionHistory = await session.history
        #expect(result.history == sessionHistory)
    }

    @Test func zeroRetainedTurnsDoesNotRecreateAToolTranscriptDroppedByCompaction() async throws {
        let spy = SpyCompactor()
        let policy = AgentContextPolicy(
            maxInputUTF8Bytes: 4_096,
            maxActiveHistoryUTF8Bytes: 900,
            retainedRecentTurnCount: 0,
            compactor: spy
        )
        let call = addition("compact-drop-tool")
        let provider = ScriptedProvider { request, turn in
            if turn == 1 { return toolResponse(request, [call]) }
            #expect(request.messages.contains { AgentContextWindow.isSyntheticConversationSummary($0) })
            #expect(!request.messages.contains { message in
                if case .assistant(_, let calls) = message { return calls.contains(call) }
                if case .tool(let result) = message { return result.callID == call.id }
                return false
            })
            return textResponse(request, "done")
        }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [AddTool(log: EffectLog())],
            configuration: .init(contextPolicy: policy)
        ).makeSession()

        let result = try await session.run(String(repeating: "large-user-", count: 80)).wait()

        #expect(result.outcome == .completed)
        #expect(await spy.count == 1)
        let canonical = await session.history
        #expect(result.history == canonical)
    }

    @Test func zeroRetainedTurnsPreservesCanonicalSummaryAcrossAMultiToolBatch() async throws {
        let spy = SpyCompactor()
        let policy = AgentContextPolicy(
            maxInputUTF8Bytes: 4_096,
            maxActiveHistoryUTF8Bytes: 900,
            retainedRecentTurnCount: 0,
            compactor: spy
        )
        let first = addition("compact-first")
        let second = ToolCall(
            id: .init(rawValue: "compact-second"),
            name: first.name,
            argumentsJSON: first.argumentsJSON,
            completeness: first.completeness
        )
        let provider = ScriptedProvider { request, turn in
            if turn == 1 { return toolResponse(request, [first, second]) }
            #expect(request.messages.first == .system("Keep the canonical summary."))
            #expect(request.messages.contains { AgentContextWindow.isSyntheticConversationSummary($0) })
            return textResponse(request, "done")
        }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [AddTool(log: EffectLog())],
            configuration: .init(
                instructions: "Keep the canonical summary.",
                contextPolicy: policy
            )
        ).makeSession()

        let result = try await session.run(String(repeating: "large-user-", count: 80)).wait()

        #expect(result.outcome == .completed)
        #expect(await spy.count >= 1)
        let canonical = await session.history
        #expect(result.history == canonical)
    }

    @Test func steeringAfterMidRunCompactionIsAppliedExactlyOnce() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Tool entered")
        let returned = XCTestExpectation(description: "Tool returned")
        let tool = try BlockingTool(gate: gate, entered: entered, returned: returned, timeout: .seconds(5))
        let spy = SpyCompactor()
        let policy = AgentContextPolicy(maxInputUTF8Bytes: 4_096, maxActiveHistoryUTF8Bytes: 900,
                                        retainedRecentTurnCount: 1, compactor: spy)
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1:
                return textResponse(request, String(repeating: "old-answer-", count: 18))
            case 2:
                return toolResponse(request, [blockingCall])
            default:
                #expect(request.messages.contains { AgentContextWindow.isSyntheticConversationSummary($0) })
                #expect(request.messages.filter { $0 == .user([.text("also do X")]) }.count == 1)
                #expect(request.messages.last == .user([.text("also do X")]))
                return textResponse(request, "done")
            }
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [tool],
                                configuration: .init(contextPolicy: policy)).makeSession()
        _ = try await session.run(String(repeating: "old-user-", count: 18)).wait()
        let run = try await session.run(String(repeating: "new-user-", count: 18))
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        _ = try await run.steer("also do X")
        await gate.open()

        let result = try await run.wait()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        #expect(result.history.filter { $0 == .user([.text("also do X")]) }.count == 1)
        #expect(await spy.count == 1)
        let canonical = await session.history
        #expect(result.history == canonical)
    }

    @Test func oversizedCompactorOutputFailsOnceAsHistoryTooLarge() async throws {
        let compactor = OversizedCompactor()
        let policy = AgentContextPolicy(
            maxInputUTF8Bytes: 4_096,
            maxActiveHistoryUTF8Bytes: 500,
            retainedRecentTurnCount: 1,
            compactor: compactor
        )
        let provider = ScriptedProvider { request, _ in
            textResponse(request, String(repeating: "answer-", count: 20))
        }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            configuration: AgentConfiguration(contextPolicy: policy)
        ).makeSession()
        _ = try await session.run(String(repeating: "first-", count: 20)).wait()

        await #expect(throws: AgentContextError.self) {
            _ = try await session.run(String(repeating: "second-", count: 20)).wait()
        }
        #expect(await compactor.count == 1)
        #expect(await session.activeRunID == nil)
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

    @Test func historyExactlyAtTheEncodedLimitIsAdmittedWithoutCompaction() async throws {
        let first = "threshold-hello"
        let reply = "threshold-ack"
        let aligned = AgentContextWindow.applyingCurrentInstructions(
            [.user([.text(first)]), .assistant(content: [.text(reply)], toolCalls: [])],
            instructions: ""
        )
        let bytes = try AgentContextWindow.encodedByteCount(aligned)
        let spy = SpyCompactor()
        let policy = AgentContextPolicy(
            maxInputUTF8Bytes: bytes + 64,
            maxActiveHistoryUTF8Bytes: bytes,
            retainedRecentTurnCount: 6,
            compactor: spy
        )
        let session = try Agent(
            model: fixtureModel,
            provider: ScriptedProvider { request, _ in textResponse(request, reply) },
            configuration: AgentConfiguration(contextPolicy: policy)
        ).makeSession()
        #expect(try await session.run(first).wait().outcome == .completed)
        #expect(await spy.count == 0)
        #expect(try AgentContextWindow.encodedByteCount(
            AgentContextWindow.applyingCurrentInstructions(await session.history, instructions: "")
        ) == bytes)
    }

    @Test func oneByteOverTheEncodedLimitFailsClosedWithoutACompactor() async throws {
        let first = "over-hello"
        let reply = "over-ack"
        let aligned = AgentContextWindow.applyingCurrentInstructions(
            [.user([.text(first)]), .assistant(content: [.text(reply)], toolCalls: [])],
            instructions: ""
        )
        let bytes = try AgentContextWindow.encodedByteCount(aligned)
        let policy = AgentContextPolicy(
            maxInputUTF8Bytes: bytes + 64,
            maxActiveHistoryUTF8Bytes: bytes - 1,
            retainedRecentTurnCount: 6
        )
        let session = try Agent(
            model: fixtureModel,
            provider: ScriptedProvider { request, _ in textResponse(request, reply) },
            configuration: AgentConfiguration(contextPolicy: policy)
        ).makeSession()
        await #expect(throws: AgentContextError.self) {
            _ = try await session.run(first).wait()
        }
        #expect(await session.activeRunID == nil)
    }

    @Test func throwingCompactorFailsTheRunWithoutHangingTheSession() async throws {
        let policy = AgentContextPolicy(
            maxInputUTF8Bytes: 2_048,
            maxActiveHistoryUTF8Bytes: 420,
            retainedRecentTurnCount: 1,
            compactor: ThrowingCompactor()
        )
        let session = try Agent(
            model: fixtureModel,
            provider: ScriptedProvider { request, turn in textResponse(request, "ack-\(turn)") },
            configuration: AgentConfiguration(contextPolicy: policy)
        ).makeSession()
        var sawCompactorError = false
        for index in 1...6 {
            do {
                let run = try await session.run(String(repeating: "payload-\(index)-", count: 6))
                _ = try await run.wait()
                try await run.waitForDrain()
            } catch is CompactorFixtureError {
                sawCompactorError = true
                break
            }
        }
        #expect(sawCompactorError)
        #expect(await session.activeRunID == nil)
        let started = ContinuousClock.now
        await #expect(throws: CompactorFixtureError.self) {
            _ = try await session.run("small").wait()
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(await session.activeRunID == nil)
    }

    @Test func timedOutCompactorCannotOverwriteANewerRunOrDurableCheckpoint() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-stale-compactor-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try AgentJournal(persistenceURL: url)
        let sessionID = UUID()
        let compactor = BlockingCompactor()
        let seedInput = "seed"
        let seedReply = "seed-reply"
        let timedOutInput = "run-a"
        let timedOutReply = String(repeating: "stale-a-", count: 80)
        let newerInput = "run-b"
        let newerReply = "fresh-b"
        let newerHistory: [ModelMessage] = [
            .user([.text(seedInput)]),
            .assistant(content: [.text(seedReply)], toolCalls: []),
            .user([.text(timedOutInput)]),
            .user([.text(newerInput)]),
            .assistant(content: [.text(newerReply)], toolCalls: []),
        ]
        let limit = try AgentContextWindow.encodedByteCount(newerHistory)
        let staleHistory = Array(newerHistory.prefix(3)) + [
            .assistant(content: [.text(timedOutReply)], toolCalls: []),
        ]
        #expect(try AgentContextWindow.encodedByteCount(staleHistory) > limit)
        let provider = ScriptedProvider { request, _ in
            switch request.messages.last {
            case .user([.text(seedInput)]): textResponse(request, seedReply)
            case .user([.text(timedOutInput)]): textResponse(request, timedOutReply)
            case .user([.text(newerInput)]): textResponse(request, newerReply)
            default: throw FixtureError.invalidOperation
            }
        }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            configuration: .init(contextPolicy: .init(
                maxInputUTF8Bytes: 4_096,
                maxActiveHistoryUTF8Bytes: limit,
                retainedRecentTurnCount: 0,
                compactor: compactor
            ))
        ).makeSession(id: sessionID, journal: journal)

        let seed = try await session.run(seedInput)
        _ = try await seed.wait()
        try await seed.waitForDrain()

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        let runA = try await session.run(
            timedOutInput,
            budget: AgentBudget(maxModelTurns: 2, maxToolCalls: 0, deadline: deadline)
        )
        await compactor.waitUntilBlocked()
        await #expect(throws: AgentLoopError.deadlineExceeded) { try await runA.wait() }

        let runB = try await session.run(newerInput)
        let resultB = try await runB.wait()
        try await runB.waitForDrain()
        #expect(resultB.history == newerHistory)
        #expect(await session.history == newerHistory)
        #expect(await journal.latestCheckpoint(sessionID: sessionID)?.history == newerHistory)

        await compactor.open()
        for _ in 0..<10_000 {
            if await journal.snapshot().contains(where: { record in
                record.runID == runA.id && record.sequence > 1 && {
                    if case .checkpoint = record.event { return true }
                    return false
                }()
            }) { break }
            await Task.yield()
        }
        for _ in 0..<10_000 {
            if await session.history != newerHistory { break }
            await Task.yield()
        }

        #expect(await session.history == newerHistory)
        let restored = try AgentJournal.load(from: url)
        #expect(await restored.latestCheckpoint(sessionID: sessionID)?.history == newerHistory)
    }
}

actor SpyCompactor: AgentContextCompactor {
    private(set) var count = 0

    func summarize(droppedConversation: [ModelMessage]) async throws -> AgentCompactionSummary {
        count += 1
        return AgentCompactionSummary(goal: "Continue.", decisions: ["Keep recent turns"])
    }
}

private actor BlockingCompactor: AgentContextCompactor {
    private var continuation: CheckedContinuation<Void, Never>?
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func summarize(droppedConversation: [ModelMessage]) async throws -> AgentCompactionSummary {
        blocked = true
        let observers = blockedWaiters
        blockedWaiters.removeAll()
        for observer in observers { observer.resume() }
        await withCheckedContinuation { continuation = $0 }
        return AgentCompactionSummary(goal: "Run A stale summary")
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

struct CompactorFixtureError: Error {}

struct ThrowingCompactor: AgentContextCompactor {
    func summarize(droppedConversation: [ModelMessage]) async throws -> AgentCompactionSummary {
        throw CompactorFixtureError()
    }
}

actor OversizedCompactor: AgentContextCompactor {
    private(set) var count = 0

    func summarize(droppedConversation: [ModelMessage]) async throws -> AgentCompactionSummary {
        count += 1
        return AgentCompactionSummary(goal: String(repeating: "oversized", count: 200))
    }
}
