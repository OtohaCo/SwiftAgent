import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

struct AgentEventTests {
    @Test func textResponseHasGoldenEventOrderAndRunIdentity() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "Hello") }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let sessionID = UUID(), runID = UUID()
        let messages: [ModelMessage] = [.user([.text("Hi")])]
        var events: [AgentEvent] = []
        for await event in loop.events(messages: messages, sessionID: sessionID, runID: runID, budget: try testBudget()) {
            events.append(event)
        }
        guard case .runFinished(.result(let result)) = events.last else { Issue.record("Missing result"); return }
        let info = ResponseInfo(id: "response", model: fixtureModel)
        #expect(events == [
            .runStarted(.init(sessionID: sessionID, runID: runID, model: fixtureModel)),
            .turnStarted(1), .model(.responseStarted(info)), .model(.textDelta("Hello")),
            .model(.responseCompleted(result.response)), .runFinished(.result(result)),
        ])
        #expect(result.outcome == .completed)
        #expect(result.history == messages + [.assistant(content: [.text("Hello")], toolCalls: [])])
        #expect(await provider.log.requests.count == 1)
    }

    @Test func twoToolRoundHasGoldenLifecycleOrderAndValidatedResults() async throws {
        let calls = [addition("a"), ToolCall(id: .init(rawValue: "s"), name: "search",
            argumentsJSON: #"{"query":"resource"}"#, completeness: .complete)]
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, calls) : textResponse(request, "Done")
        }
        let log = EffectLog()
        let registry = try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log)), AnyAgentTool(LookupTool(log: log))])
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: registry)
        let sessionID = UUID(), runID = UUID()
        let events = await collectEvents(loop.events(messages: [], sessionID: sessionID, runID: runID, budget: try testBudget()))
        guard case .runFinished(.result(let result)) = events.last else { Issue.record("Missing result"); return }
        let info = ResponseInfo(id: "response", model: fixtureModel)
        let sum = ToolResultMessage(callID: calls[0].id, content: [.json(.object(["sum": .number(5)]))], isError: false)
        let search = ToolResultMessage(callID: calls[1].id, content: [.json(.object(["references": .array([.string("resource")])]))], isError: false)
        let completions = events.compactMap { if case .toolCompleted(let result) = $0 { result } else { nil } }
        #expect(Set(completions) == Set([sum, search]))
        #expect(completions.count == 2)
        let nextTurn = try #require(events.firstIndex(of: .turnStarted(2)))
        for call in calls {
            let started = try #require(events.firstIndex(of: .toolStarted(call)))
            let completed = try #require(events.firstIndex { if case .toolCompleted(let result) = $0 { result.callID == call.id } else { false } })
            #expect(started < completed && completed < nextTurn)
        }
        #expect(events.filter { if case .toolCompleted = $0 { false } else { true } } == [
            .runStarted(.init(sessionID: sessionID, runID: runID, model: fixtureModel)), .turnStarted(1),
            .model(.responseStarted(info)),
            .model(.toolCallStarted(calls[0].id, name: "add")), .model(.toolCallArgumentsDelta(calls[0].id, calls[0].argumentsJSON)),
            .model(.toolCallCompleted(calls[0])),
            .model(.toolCallStarted(calls[1].id, name: "search")), .model(.toolCallArgumentsDelta(calls[1].id, calls[1].argumentsJSON)),
            .model(.toolCallCompleted(calls[1])),
            .model(.responseCompleted(.init(info: info, toolCalls: calls, stopReason: .toolCalls))),
            .toolStarted(calls[0]), .toolStarted(calls[1]),
            .turnStarted(2), .model(.responseStarted(info)), .model(.textDelta("Done")),
            .model(.responseCompleted(.init(info: info, content: [.text("Done")], stopReason: .endTurn))),
            .runFinished(.result(result)),
        ])
        #expect(result.toolCalls == 2)
        #expect(result.history == [.assistant(content: [], toolCalls: calls), .tool(sum), .tool(search),
                                  .assistant(content: [.text("Done")], toolCalls: [])])
    }
}
