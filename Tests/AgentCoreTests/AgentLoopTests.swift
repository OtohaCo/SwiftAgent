import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

struct AgentLoopTests {
    @Test func textOnlyAnswerUsesExactlyOneProviderTurn() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "Hello") }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let messages: [ModelMessage] = [.system("Be concise."), .user([.text("Hello")])]
        let result = try await loop.run(messages: messages, sessionID: UUID(), budget: testBudget())
        #expect(result.outcome == .completed)
        #expect(result.response.content == [.text("Hello")])
        #expect(result.history == messages + [.assistant(content: [.text("Hello")], toolCalls: [])])
        #expect(await provider.log.requests.count == 1)
    }

    @Test func twoToolsFeedOrderedTypedResultsBackIntoTheNextTurn() async throws {
        let calls = [
            ToolCall(id: .init(rawValue: "add-1"), name: "add", argumentsJSON: #"{"lhs":2,"rhs":3}"#, completeness: .complete),
            ToolCall(id: .init(rawValue: "search-1"), name: "search", argumentsJSON: #"{"query":"building"}"#, completeness: .complete),
        ]
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, calls) : textResponse(request, "Found building; total 5")
        }
        let log = EffectLog()
        let registry = try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log)), AnyAgentTool(LookupTool(log: log))])
        let sessionID = UUID(), runID = UUID()
        let user: ModelMessage = .user([.text("Search and add")])
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: registry)
        let result = try await loop.run(messages: [user], sessionID: sessionID, runID: runID, budget: testBudget())
        let requests = await provider.log.requests
        try #require(requests.count == 2)
        #expect(requests[0].tools.map(\.name) == ["add", "search"])
        #expect(requests[1].messages == [user, .assistant(content: [], toolCalls: calls),
            .tool(.init(callID: calls[0].id, content: [.json(.object(["sum": .number(5)]))], isError: false)),
            .tool(.init(callID: calls[1].id, content: [.json(.object(["references": .array([.string("building")])]))], isError: false)),
        ])
        #expect(result.history == requests[1].messages + [.assistant(content: [.text("Found building; total 5")], toolCalls: [])])
        #expect(result.modelTurns == 2)
        #expect(result.toolCalls == 2)
        #expect(await Set(log.names) == Set(["add", "search"]))
        #expect(await log.names.count == 2)
        #expect(await log.contexts.allSatisfy { $0.sessionID == sessionID && $0.runID == runID })
    }
}
