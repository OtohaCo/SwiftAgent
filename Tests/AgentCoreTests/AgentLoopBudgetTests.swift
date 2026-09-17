import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

struct AgentLoopBudgetTests {
    @Test func invalidLimitsAreRejectedAtConstruction() {
        for (turns, calls) in [(0, 1), (-1, 1), (1, -1)] {
            #expect(throws: AgentLoopError.invalidBudget) { try testBudget(turns: turns, calls: calls) }
        }
    }

    @Test func toolBudgetRejectsWholeBatchRatherThanExecutingAPrefix() async throws {
        let log = EffectLog()
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [addition("1"), addition("2")]) : textResponse(request, "Unexpected")
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log))]))
        await #expect(throws: AgentLoopError.toolCallLimitReached) { try await loop.run(messages: [], sessionID: UUID(), budget: testBudget(calls: 1)) }
        #expect(await log.names.isEmpty)
        #expect(await provider.log.requests.count == 1)
    }

    @Test func limitsApplyAcrossTurnsAndReserveAFinalModelTurn() async throws {
        for (turns, calls) in [(2, 8), (4, 1)] {
            let log = EffectLog()
            let provider = ScriptedProvider { request, turn in
                turn < 3 ? toolResponse(request, [addition("\(turn)")]) : textResponse(request, "Unexpected")
            }
            let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log))]))
            let expected: AgentLoopError = turns == 2 ? .modelTurnLimitReached : .toolCallLimitReached
            await #expect(throws: expected) { try await loop.run(messages: [], sessionID: UUID(), budget: testBudget(turns: turns, calls: calls)) }
            #expect(await log.names == ["add"])
            #expect(await provider.log.requests.count == 2)
        }
    }

    @Test func expiredBudgetDoesNotContactProvider() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "Unexpected") }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let expired = try AgentBudget(maxModelTurns: 1, maxToolCalls: 0, deadline: .now.advanced(by: .seconds(-1)))
        await #expect(throws: AgentLoopError.deadlineExceeded) { try await loop.run(messages: [], sessionID: UUID(), budget: expired) }
        #expect(await provider.log.requests.isEmpty)
    }

    @Test func reusedCallIDsFromEarlierTurnsOrHistoryCannotReplayTools() async throws {
        let call = addition("same")
        for history: [ModelMessage] in [[], [.assistant(content: [], toolCalls: [call])]] {
            let log = EffectLog()
            let provider = ScriptedProvider { request, turn in
                turn < 3 ? toolResponse(request, [call]) : textResponse(request, "Unexpected")
            }
            let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log))]))
            await #expect(throws: AgentLoopError.reusedToolCallID(call.id)) { try await loop.run(messages: history, sessionID: UUID(), budget: testBudget()) }
            #expect(await log.names.count == (history.isEmpty ? 1 : 0))
        }
    }
}

func addition(_ id: String) -> ToolCall {
    .init(id: .init(rawValue: id), name: "add", argumentsJSON: #"{"lhs":2,"rhs":3}"#, completeness: .complete)
}
