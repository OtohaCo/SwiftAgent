import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest
@testable import AgentCore

struct AgentConversationContextTests {
    @Test func crossRunToolResultIsVisibleAndDrivesUseResource() async throws {
        let committed = CommittedTranscript()
        let used = EffectLog()
        let provider = ScriptedProvider { request, _ in
            try await catalogResponse(request, committed: committed)
        }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [SearchResourceTool(), UseResourceTool(log: used)],
            instructions: CatalogPrompt.instructions
        ).makeSession()

        let first = try await session.run(CatalogPrompt.find)
        let firstResult = try await first.wait()
        #expect(firstResult.outcome == .completed)
        ConversationTranscript.requireCanonicalSearchRound(firstResult.history, instructions: CatalogPrompt.instructions)
        await committed.store(firstResult.history)

        let second = try await session.run(CatalogPrompt.useFirst)
        let secondResult = try await second.wait()
        #expect(secondResult.outcome == .completed)
        #expect(await used.names == ["use_resource"])
        #expect(await used.contexts.first?.callID == CatalogIDs.use)

        let followUp = try #require(await provider.log.requests.first { $0.messages.last == .user([.text(CatalogPrompt.useFirst)]) })
        #expect(followUp.messages == firstResult.history + [.user([.text(CatalogPrompt.useFirst)])])
        try ConversationTranscript.requirePairedToolHistory(followUp.messages)
        ConversationTranscript.requireExactSearchThenUseOrder(secondResult.history, instructions: CatalogPrompt.instructions)
        #expect(followUp.messages.filter { $0 == .user([.text(CatalogPrompt.find)]) }.count == 1)
    }

    @Test func sameSessionEvidenceCanBeUsedAcrossRunsWhileTranscriptIsAlsoPresent() async throws {
        let committed = CommittedTranscript()
        let used = EffectLog()
        let provider = ScriptedProvider { request, _ in
            try await catalogResponse(request, committed: committed)
        }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [SearchResourceTool(publishEvidence: true), UseResourceTool(log: used, scope: .sameSession)],
            instructions: CatalogPrompt.instructions
        ).makeSession()
        let first = try await session.run(CatalogPrompt.find).wait()
        await committed.store(first.history)
        #expect(try await session.run(CatalogPrompt.useFirst).wait().outcome == .completed)
        #expect(await used.names == ["use_resource"])
        let followUp = try #require(await provider.log.requests.first { $0.messages.last == .user([.text(CatalogPrompt.useFirst)]) })
        #expect(ConversationTranscript.containsSearchHits(followUp.messages))
    }

    @Test func sameRunEvidenceCannotBeReusedEvenWhenTranscriptKeepsTheResource() async throws {
        let committed = CommittedTranscript()
        let used = EffectLog()
        let provider = ScriptedProvider { request, _ in
            try await catalogResponse(request, committed: committed)
        }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [SearchResourceTool(publishEvidence: true), UseResourceTool(log: used, scope: .sameRun)],
            instructions: CatalogPrompt.instructions
        ).makeSession()
        let first = try await session.run(CatalogPrompt.find).wait()
        await committed.store(first.history)
        await #expect(throws: EvidenceError.self) {
            try await session.run(CatalogPrompt.useFirst).wait()
        }
        #expect(await used.names.isEmpty)
        let followUp = try #require(await provider.log.requests.first { $0.messages.last == .user([.text(CatalogPrompt.useFirst)]) })
        #expect(ConversationTranscript.containsSearchHits(followUp.messages))
        #expect(followUp.messages == first.history + [.user([.text(CatalogPrompt.useFirst)])])
    }

    @Test func restartRestoresCommittedToolConversationWithoutRebuildingEvidence() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-conversation-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let sessionID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        let firstProvider = ScriptedProvider { request, _ in
            try await catalogResponse(request, committed: nil)
        }
        let original = try Agent(
            model: fixtureModel,
            provider: firstProvider,
            tools: [SearchResourceTool(publishEvidence: true), UseResourceTool(scope: .sameSession)],
            instructions: CatalogPrompt.instructions
        ).makeSession(id: sessionID, journal: journal)
        let firstRun = try await original.run(CatalogPrompt.find)
        let first = try await firstRun.wait()
        await firstRun.waitForDrain()
        ConversationTranscript.requireCanonicalSearchRound(first.history, instructions: CatalogPrompt.instructions)

        let restoredJournal = try AgentJournal.load(from: url)
        let committed = CommittedTranscript()
        await committed.store(
            AgentContextWindow.applyingCurrentInstructions(first.history, instructions: CatalogPrompt.instructions)
        )
        let restoredProvider = ScriptedProvider { request, _ in
            try await catalogResponse(request, committed: committed)
        }
        let restored = try Agent(
            model: fixtureModel,
            provider: restoredProvider,
            tools: [SearchResourceTool(publishEvidence: true), UseResourceTool(scope: .sameSession)],
            instructions: CatalogPrompt.instructions
        ).makeSession(id: sessionID, journal: restoredJournal)
        await #expect(throws: EvidenceError.self) {
            try await restored.run(CatalogPrompt.useFirst).wait()
        }
        let followUp = try #require(await restoredProvider.log.requests.first)
        let restoredPrefix = await committed.current()
        #expect(followUp.messages == restoredPrefix + [.user([.text(CatalogPrompt.useFirst)])])
        try ConversationTranscript.requirePairedToolHistory(followUp.messages)
        #expect(ConversationTranscript.containsSearchHits(followUp.messages))
    }

    @Test func restartUsesCurrentInstructionsAndKeepsToolHistory() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-instructions-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let sessionID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        let firstProvider = ScriptedProvider { request, _ in
            try await catalogResponse(request, committed: nil)
        }
        let original = try Agent(
            model: fixtureModel,
            provider: firstProvider,
            tools: [SearchResourceTool(), UseResourceTool()],
            configuration: AgentConfiguration(instructions: "Version one.")
        ).makeSession(id: sessionID, journal: journal)
        let firstRun = try await original.run(CatalogPrompt.find)
        let first = try await firstRun.wait()
        await firstRun.waitForDrain()

        let expected = AgentContextWindow.applyingCurrentInstructions(first.history, instructions: "Version two.")
        let committed = CommittedTranscript()
        await committed.store(expected)
        let restoredProvider = ScriptedProvider { request, _ in
            try await catalogResponse(request, committed: committed)
        }
        let restored = try Agent(
            model: fixtureModel,
            provider: restoredProvider,
            tools: [SearchResourceTool(), UseResourceTool()],
            configuration: AgentConfiguration(instructions: "Version two.")
        ).makeSession(id: sessionID, journal: try AgentJournal.load(from: url))
        _ = try await restored.run(CatalogPrompt.useFirst).wait()
        let request = try #require(await restoredProvider.log.requests.first)
        #expect(request.messages.first == .system("Version two."))
        #expect(request.messages.filter { $0.role == .system } == [.system("Version two.")])
        #expect(!request.messages.contains(.system("Version one.")))
        ConversationTranscript.requireCanonicalSearchRound(
            Array(request.messages.dropLast()),
            instructions: "Version two."
        )
        #expect(request.messages.last == .user([.text(CatalogPrompt.useFirst)]))
    }

    @Test func failedToolBatchLeavesOnlyCommittedPairsForTheNextRun() async throws {
        let good = addition("good")
        let bad = ToolCall(
            id: .init(rawValue: "overflow"),
            name: "add",
            argumentsJSON: "{\"lhs\":\(Int.max),\"rhs\":1}",
            completeness: .complete
        )
        let provider = ScriptedProvider { request, _ in
            try ConversationTranscript.requirePairedToolHistory(request.messages)
            if request.messages.last == .user([.text("continue")]) {
                #expect(!request.messages.contains { message in
                    if case .assistant(_, let calls) = message { return calls.contains(where: { $0.id == bad.id }) }
                    return false
                })
                #expect(!request.messages.contains { message in
                    if case .tool(let result) = message { return result.callID == bad.id }
                    return false
                })
                return textResponse(request, "Continuing")
            }
            return toolResponse(request, [good, bad])
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [AddTool(log: EffectLog())]).makeSession()
        let first = try await session.run("compute")
        await #expect(throws: FixtureError.self) { try await first.wait() }
        _ = try await session.run("continue").wait()
        let followUp = try #require(await provider.log.requests.first { $0.messages.last == .user([.text("continue")]) })
        try ConversationTranscript.requirePairedToolHistory(followUp.messages)
        #expect(followUp.messages == [
            .user([.text("compute")]),
            .assistant(content: [], toolCalls: [good]),
            .tool(.init(callID: good.id, content: [.json(.object(["sum": .number(5)]))], isError: false)),
            .user([.text("continue")]),
        ])
    }

    @Test func incompleteProposalIsNotPresentedAsExecutedOnTheNextRun() async throws {
        let proposal = addition("proposal")
        let provider = ScriptedProvider { request, _ in
            try ConversationTranscript.requirePairedToolHistory(request.messages)
            if request.messages.last == .user([.text("Continue")]) {
                #expect(!request.messages.contains { message in
                    if case .assistant(_, let calls) = message { return calls.contains(proposal) }
                    return false
                })
                #expect(!request.messages.contains { message in
                    if case .tool(let result) = message { return result.callID == proposal.id }
                    return false
                })
                return textResponse(request, "Next")
            }
            var events = toolResponse(request, [proposal], stop: .maxOutputTokens)
            events.insert(.textDelta("Partial answer"), at: 1)
            events[events.count - 1] = .responseCompleted(.init(
                info: .init(id: "response", model: request.model),
                content: [.text("Partial answer")],
                toolCalls: [proposal],
                stopReason: .maxOutputTokens
            ))
            return events
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [AddTool(log: EffectLog())]).makeSession()
        #expect(try await session.run("Compute").wait().outcome == .incomplete(.maxOutputTokens))
        _ = try await session.run("Continue").wait()
        let followUp = try #require(await provider.log.requests.last)
        try ConversationTranscript.requirePairedToolHistory(followUp.messages)
        #expect(followUp.messages == [
            .user([.text("Compute")]),
            .assistant(content: [.text("Partial answer")], toolCalls: []),
            .user([.text("Continue")]),
        ])
    }

    @Test func cancelledRunKeepsAcceptedInputOnceAndDropsUncommittedProposals() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Tool entered")
        let returned = XCTestExpectation(description: "Tool returned")
        let blocker = try BlockingTool(gate: gate, entered: entered, returned: returned, timeout: .seconds(5))
        let call = addition("done")
        let provider = ScriptedProvider { request, _ in
            try ConversationTranscript.requirePairedToolHistory(request.messages)
            if request.messages.last == .user([.text("continue")]) {
                return textResponse(request, "Next")
            }
            if request.messages.contains(where: { if case .tool = $0 { return true }; return false }) {
                return textResponse(request, "Unexpected")
            }
            return toolResponse(request, [call, blockingCall])
        }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [AddTool(log: EffectLog()), blocker]
        ).makeSession()
        let run = try await session.run("original")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        _ = try await run.steer("remember")
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        _ = try await session.run("continue").wait()
        let followUp = try #require(await provider.log.requests.first { $0.messages.last == .user([.text("continue")]) })
        try ConversationTranscript.requirePairedToolHistory(followUp.messages)
        #expect(followUp.messages.filter { $0 == .user([.text("remember")]) }.count == 1)
        #expect(followUp.messages.filter { $0 == .user([.text("continue")]) }.count == 1)
        #expect(!followUp.messages.contains { message in
            if case .assistant(_, let calls) = message { return calls.contains(where: { $0.id == blockingCall.id }) }
            return false
        })
        #expect(followUp.messages == [
            .user([.text("original")]),
            .assistant(content: [], toolCalls: [call]),
            .tool(.init(callID: call.id, content: [.json(.object(["sum": .number(5)]))], isError: false)),
            .user([.text("remember")]),
            .user([.text("continue")]),
        ])
    }

    @Test func refusalEntersCanonicalHistoryAndTheSessionCanContinue() async throws {
        let provider = ScriptedProvider { request, _ in
            try ConversationTranscript.requirePairedToolHistory(request.messages)
            if request.messages.last == .user([.text("follow up")]) {
                #expect(request.messages.contains(.assistant(content: [.text("Cannot help")], toolCalls: [])))
                return textResponse(request, "Ready")
            }
            return textResponse(request, "Cannot help", stop: .refusal)
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        #expect(try await session.run("risky").wait().outcome == .refused)
        #expect(try await session.run("follow up").wait().outcome == .completed)
        let followUp = try #require(await provider.log.requests.last)
        #expect(followUp.messages == [
            .user([.text("risky")]),
            .assistant(content: [.text("Cannot help")], toolCalls: []),
            .user([.text("follow up")]),
        ])
    }

    @Test func providerWithoutMultiTurnCannotSilentlyDropAssistantHistory() async throws {
        let provider = ScriptedProvider(descriptor: .init(id: "fixture", capabilities: [.streaming])) { request, _ in
            textResponse(request, "Hello")
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        #expect(try await session.run("hi").wait().outcome == .completed)
        await #expect(throws: AgentLoopError.unsupportedCapabilities(.multiTurn)) {
            try await session.run("again").wait()
        }
        #expect(await provider.log.requests.count == 1)
        let history = await session.history
        #expect(Array(history.prefix(2)) == [
            .user([.text("hi")]),
            .assistant(content: [.text("Hello")], toolCalls: []),
        ])
    }

    @Test func committedProviderContinuationSurvivesTheNextRunOnTheSameAssistant() async throws {
        let state = ModelProviderContinuation(model: fixtureModel, format: "fixture.v1", payload: Data([0, 255]))
        let expected = ModelMessage.assistant(content: [.text("Plan"), .providerContinuation(state)], toolCalls: [addition("one")])
        let provider = ScriptedProvider { request, _ in
            try ConversationTranscript.requirePairedToolHistory(request.messages)
            if request.messages.last == .user([.text("Continue")]) {
                #expect(request.messages.contains(expected))
                #expect(request.messages.contains(.tool(.init(
                    callID: addition("one").id,
                    content: [.json(.object(["sum": .number(5)]))],
                    isError: false
                ))))
                return textResponse(request, "Followed")
            }
            if request.messages.contains(where: { if case .tool = $0 { return true }; return false }) {
                return textResponse(request, "Done")
            }
            return continuationEvents(request, calls: [addition("one")], state: state)
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [AddTool(log: EffectLog())]).makeSession()
        #expect(try await session.run("Compute").wait().outcome == .completed)
        _ = try await session.run("Continue").wait()
        let followUp = try #require(await provider.log.requests.last)
        #expect(followUp.messages.contains(expected))
    }

    @Test func defaultPolicyFailsClosedInsteadOfInventingASemanticSummary() async throws {
        let policy = AgentContextPolicy(
            maxInputUTF8Bytes: 2_000,
            maxActiveHistoryUTF8Bytes: 900,
            retainedRecentTurnCount: 1
        )
        let provider = ScriptedProvider { request, _ in textResponse(request, "ack") }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            configuration: AgentConfiguration(instructions: "Stay in role.", contextPolicy: policy)
        ).makeSession()
        do {
            for index in 1...8 {
                _ = try await session.run(String(repeating: "turn-\(index)-payload-", count: 8)).wait()
            }
            Issue.record("Default policy must not silently compact away earlier turns")
        } catch let error as AgentContextError {
            guard case .historyTooLarge = error else {
                Issue.record("Expected historyTooLarge, got \(error)")
                return
            }
        }
        let requests = await provider.log.requests
        #expect(!requests.contains { request in
            request.messages.contains { message in
                if case .user(let content) = message, case .text(let text)? = content.first {
                    return text.hasPrefix("Conversation summary:")
                }
                return false
            }
        })
    }

    @Test func lossyCompactorDoesNotPreserveDroppedResourceReferences() async throws {
        let committed = CommittedTranscript()
        let used = EffectLog()
        let policy = AgentContextPolicy.lossyRetainedTurns(
            maxInputUTF8Bytes: 2_000,
            maxActiveHistoryUTF8Bytes: 900,
            retainedRecentTurnCount: 1
        )
        let provider = ScriptedProvider { request, _ in
            try await catalogOrFillerResponse(request, committed: committed)
        }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [SearchResourceTool(), UseResourceTool(log: used)],
            configuration: AgentConfiguration(instructions: CatalogPrompt.instructions, contextPolicy: policy)
        ).makeSession()
        let first = try await session.run(CatalogPrompt.find).wait()
        await committed.store(first.history)
        for index in 1...8 {
            _ = try await session.run(String(repeating: "padding-\(index)-", count: 8)).wait()
        }
        _ = try await session.run(CatalogPrompt.useFirst).wait()
        #expect(await used.names.isEmpty)
        let followUp = try #require(await provider.log.requests.first { $0.messages.last == .user([.text(CatalogPrompt.useFirst)]) })
        try ConversationTranscript.requirePairedToolHistory(followUp.messages)
        #expect(followUp.messages.first == .system(CatalogPrompt.instructions))
        #expect(followUp.messages.contains { message in
            if case .user(let content) = message, case .text(let text)? = content.first {
                return text.hasPrefix("Conversation summary:")
            }
            return false
        })
        #expect(!ConversationTranscript.containsSearchHits(followUp.messages))
        #expect(!followUp.messages.contains { message in
            if case .user(let content) = message, case .text(let text)? = content.first {
                return text.contains("resource-1") || text.contains("Alpha")
            }
            return false
        })
    }

    @Test func syntheticSummaryUsesUserRoleAndDoesNotMintEvidence() async throws {
        let spy = RecordingCompactor()
        let policy = AgentContextPolicy(
            maxInputUTF8Bytes: 2_000,
            maxActiveHistoryUTF8Bytes: 900,
            retainedRecentTurnCount: 1,
            compactor: spy
        )
        let provider = ScriptedProvider { request, _ in textResponse(request, "ack") }
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            configuration: AgentConfiguration(instructions: "Stay in role.", contextPolicy: policy)
        ).makeSession()
        for index in 1...8 {
            _ = try await session.run(String(repeating: "turn-\(index)-payload-", count: 8)).wait()
        }
        #expect(await spy.count >= 1)
        let last = try #require(await provider.log.requests.last)
        let summaries = last.messages.compactMap { message -> String? in
            guard case .user(let content) = message, case .text(let text)? = content.first,
                  text.hasPrefix("Conversation summary:") else { return nil }
            return text
        }
        #expect(!summaries.isEmpty)
        #expect(last.messages.filter { $0.role == .system } == [.system("Stay in role.")])
        #expect(!last.messages.contains { $0.role == .developer })
    }
}

private enum CatalogPrompt {
    static let instructions = "Prefer exact resource identifiers from tool results."
    static let find = "Find resources for project A"
    static let useFirst = "Use the first one."
}

private enum CatalogIDs {
    static let search = ToolCallID(rawValue: "search-1")
    static let use = ToolCallID(rawValue: "use-1")
    static var searchCall: ToolCall {
        .init(id: search, name: SearchResourceTool.name, argumentsJSON: #"{"query":"project A"}"#, completeness: .complete)
    }
    static var useCall: ToolCall {
        .init(id: use, name: UseResourceTool.name, argumentsJSON: #"{"id":"resource-1"}"#, completeness: .complete)
    }
}

private actor CommittedTranscript {
    private var messages: [ModelMessage] = []
    func store(_ value: [ModelMessage]) { messages = value }
    func current() -> [ModelMessage] { messages }
}

private enum ConversationContextError: Error {
    case unexpectedRequest
    case missingPriorToolResult
}

private enum ConversationTranscript {
    static func requirePairedToolHistory(_ messages: [ModelMessage]) throws {
        var pending: [ToolCallID] = []
        var seen = Set<ToolCallID>()
        var conversationStarted = false
        for message in messages {
            switch message {
            case .system, .developer:
                guard !conversationStarted else { throw ConversationContextError.unexpectedRequest }
            case .user:
                conversationStarted = true
                guard pending.isEmpty else { throw ConversationContextError.unexpectedRequest }
            case .assistant(_, let calls):
                conversationStarted = true
                guard pending.isEmpty else { throw ConversationContextError.unexpectedRequest }
                for call in calls {
                    guard seen.insert(call.id).inserted else { throw ConversationContextError.unexpectedRequest }
                    pending.append(call.id)
                }
            case .tool(let result):
                conversationStarted = true
                guard pending.first == result.callID, seen.contains(result.callID) else {
                    throw ConversationContextError.unexpectedRequest
                }
                pending.removeFirst()
            }
        }
        guard pending.isEmpty else { throw ConversationContextError.unexpectedRequest }
    }

    static func requireCanonicalSearchRound(_ messages: [ModelMessage], instructions: String) {
        try! requirePairedToolHistory(messages)
        #expect(messages.first == .system(instructions))
        #expect(messages.contains(.user([.text(CatalogPrompt.find)])))
        #expect(messages.contains { message in
            if case .assistant(_, let calls) = message { return calls == [CatalogIDs.searchCall] }
            return false
        })
        #expect(containsSearchHits(messages))
        #expect(messages.contains(.assistant(content: [.text("I found Alpha and Beta.")], toolCalls: [])))
        let roles = messages.map(\.role)
        #expect(roles == [.system, .user, .assistant, .tool, .assistant])
    }

    static func requireExactSearchThenUseOrder(_ messages: [ModelMessage], instructions: String) {
        requireCanonicalSearchRound(Array(messages.prefix(5)), instructions: instructions)
        #expect(messages.dropFirst(5).map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(messages[5] == .user([.text(CatalogPrompt.useFirst)]))
        #expect(messages.contains { message in
            if case .assistant(_, let calls) = message { return calls == [CatalogIDs.useCall] }
            return false
        })
        #expect(messages.last == .assistant(content: [.text("Using Alpha.")], toolCalls: []))
    }

    static func containsSearchHits(_ messages: [ModelMessage]) -> Bool {
        messages.contains { message in
            guard case .tool(let result) = message, result.callID == CatalogIDs.search else { return false }
            return result.content.contains { part in
                guard case .json(let value) = part else { return false }
                return jsonContains(value, "resource-1") && jsonContains(value, "Alpha")
                    && jsonContains(value, "resource-2") && jsonContains(value, "Beta")
            }
        }
    }

    static func jsonContains(_ value: JSONValue, _ needle: String) -> Bool {
        switch value {
        case .string(let text): text == needle
        case .array(let items): items.contains { jsonContains($0, needle) }
        case .object(let object): object.values.contains { jsonContains($0, needle) }
        default: false
        }
    }
}

private func catalogResponse(_ request: ModelRequest, committed: CommittedTranscript?) async throws -> [ModelEvent] {
    try ConversationTranscript.requirePairedToolHistory(request.messages)
    if request.messages.last == .user([.text(CatalogPrompt.useFirst)]) {
        guard let committed else { throw ConversationContextError.missingPriorToolResult }
        let expected = await committed.current() + [.user([.text(CatalogPrompt.useFirst)])]
        guard request.messages == expected, ConversationTranscript.containsSearchHits(request.messages) else {
            throw ConversationContextError.missingPriorToolResult
        }
        return toolResponse(request, [CatalogIDs.useCall])
    }
    if request.messages.last == .user([.text(CatalogPrompt.find)]) {
        return toolResponse(request, [CatalogIDs.searchCall])
    }
    if case .tool(let result) = request.messages.last {
        if result.callID == CatalogIDs.search {
            guard ConversationTranscript.containsSearchHits(request.messages) else {
                throw ConversationContextError.missingPriorToolResult
            }
            return textResponse(request, "I found Alpha and Beta.")
        }
        if result.callID == CatalogIDs.use {
            return textResponse(request, "Using Alpha.")
        }
    }
    throw ConversationContextError.unexpectedRequest
}

private func catalogOrFillerResponse(_ request: ModelRequest, committed: CommittedTranscript) async throws -> [ModelEvent] {
    try ConversationTranscript.requirePairedToolHistory(request.messages)
    if request.messages.last == .user([.text(CatalogPrompt.useFirst)]) {
        if ConversationTranscript.containsSearchHits(request.messages) {
            let expected = await committed.current() + [.user([.text(CatalogPrompt.useFirst)])]
            guard request.messages == expected else { throw ConversationContextError.missingPriorToolResult }
            return toolResponse(request, [CatalogIDs.useCall])
        }
        return textResponse(request, "I cannot resolve which resource was first.")
    }
    if request.messages.last == .user([.text(CatalogPrompt.find)]) {
        return toolResponse(request, [CatalogIDs.searchCall])
    }
    if case .tool(let result) = request.messages.last, result.callID == CatalogIDs.search {
        return textResponse(request, "I found Alpha and Beta.")
    }
    if case .user = request.messages.last {
        return textResponse(request, "ack")
    }
    throw ConversationContextError.unexpectedRequest
}

private func continuationEvents(
    _ request: ModelRequest,
    calls: [ToolCall],
    state: ModelProviderContinuation
) -> [ModelEvent] {
    var events = toolResponse(request, calls)
    events.insert(.textDelta("Plan"), at: 1)
    events.removeLast()
    events.append(.providerContinuation(state))
    events.append(.responseCompleted(.init(
        info: .init(id: "response", model: request.model),
        content: [.text("Plan"), .providerContinuation(state)],
        toolCalls: calls,
        stopReason: .toolCalls
    )))
    return events
}

private struct SearchResourceTool: AgentTool {
    struct Input: Codable, Sendable { let query: String }
    struct Hit: Codable, Sendable { let id: String; let name: String }
    struct Output: Codable, Sendable { let resources: [Hit] }

    static let name = "search_resource"
    static let description = "Find resources by query"
    static let inputSchema = ToolSchema.object(properties: ["query": .string], required: ["query"])
    static let outputSchema = ToolSchema.object(
        properties: [
            "resources": .array(items: .object(
                properties: ["id": .string, "name": .string],
                required: ["id", "name"]
            )),
        ],
        required: ["resources"]
    )
    let publishEvidence: Bool
    let policy: ToolPolicy

    init(publishEvidence: Bool = false) throws {
        self.publishEvidence = publishEvidence
        policy = try ToolPolicy(
            effect: .readOnly,
            execution: .parallel,
            idempotency: .safe,
            timeout: .seconds(2),
            authorization: .notRequired
        )
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let hits = [Hit(id: "resource-1", name: "Alpha"), Hit(id: "resource-2", name: "Beta")]
        let evidence: [Evidence] = publishEvidence
            ? hits.map { Evidence(namespace: "resource", id: $0.id, issuedAt: Date()) }
            : []
        return ToolResult(output: Output(resources: hits), evidence: evidence)
    }
}

private struct UseResourceTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    typealias Output = String

    static let name = "use_resource"
    static let description = "Use a previously listed resource"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.string
    let log: EffectLog?
    let scope: EvidenceScope?
    let policy: ToolPolicy

    init(log: EffectLog? = nil, scope: EvidenceScope? = nil) throws {
        self.log = log
        self.scope = scope
        policy = try ToolPolicy(
            effect: .readOnly,
            execution: .sequential,
            idempotency: .safe,
            timeout: .seconds(2),
            authorization: .notRequired,
            evidence: scope == nil ? .none : .required
        )
    }

    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        guard let scope else { return [] }
        return [.init(reference: .init(namespace: "resource", id: input.id), scope: scope)]
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        if let log { await log.record(Self.name, context) }
        return ToolResult(output: "used \(input.id)")
    }
}

private actor RecordingCompactor: AgentContextCompactor {
    private(set) var count = 0

    func summarize(droppedConversation: [ModelMessage]) async throws -> AgentCompactionSummary {
        count += 1
        return AgentCompactionSummary(goal: "Continue.", decisions: ["Keep recent turns"])
    }
}
