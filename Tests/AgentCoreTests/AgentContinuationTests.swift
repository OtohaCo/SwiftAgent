import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

struct AgentContinuationTests {
    @Test func incompleteResponseDropsStateForDiscardedCallsBeforeTheNextRequest() async throws {
        let state = ModelProviderContinuation(model: fixtureModel, format: "fixture.v1", payload: Data([0, 255]))
        let probe = EffectLog()
        let provider = ScriptedProvider { request, turn in
            if turn == 1 { return continuationResponse(request, calls: [addition("one")], state: state, stop: .maxOutputTokens) }
            return textResponse(request, "Done")
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [AddTool(log: probe)]).makeSession()
        #expect(try await session.run("Compute").wait().outcome == .incomplete(.maxOutputTokens))
        _ = try await session.run("Continue").wait()
        #expect(await probe.names.isEmpty)
        let request = try #require(await provider.log.requests.last)
        #expect(!request.messages.contains { message in
            if case .assistant(let content, _) = message { return content.contains(.providerContinuation(state)) }
            return false
        })
    }

    @Test func completeTurnsKeepOpaqueStateInCanonicalHistoryAndNextRequest() async throws {
        let state = ModelProviderContinuation(model: fixtureModel, format: "fixture.v1", payload: Data([0, 255]))
        let provider = ScriptedProvider { request, turn in
            if turn == 1 { return continuationResponse(request, calls: [addition("one")], state: state) }
            return textResponse(request, "Done")
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [AddTool(log: EffectLog())]).makeSession()
        let result = try await session.run("Compute").wait()
        let expected = ModelMessage.assistant(content: [.text("Plan"), .providerContinuation(state)], toolCalls: [addition("one")])
        #expect(result.history.contains(expected))
        #expect(await provider.log.requests.last?.messages.contains(expected) == true)
    }

    @Test func partialBatchCheckpointDropsOpaqueStateBoundToTheUncommittedWholeResponse() async throws {
        let state = ModelProviderContinuation(model: fixtureModel, format: "fixture.v1", payload: Data([0, 255]))
        let failed = ToolCall(id: .init(rawValue: "overflow"), name: "add",
                              argumentsJSON: "{\"lhs\":\(Int.max),\"rhs\":1}", completeness: .complete)
        let provider = ScriptedProvider { request, _ in continuationResponse(request, calls: [addition("one"), failed], state: state) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [AddTool(log: EffectLog())]).makeSession()
        await #expect(throws: FixtureError.invalidOperation) { try await session.run("Compute").wait() }
        let history = await session.history
        #expect(history.contains(.assistant(content: [.text("Plan")], toolCalls: [addition("one")])))
        #expect(!history.contains { message in
            if case .assistant(let content, _) = message { return content.contains(.providerContinuation(state)) }
            return false
        })
        #expect(history.filter { $0.role == .tool }.count == 1)
    }
}

private func continuationResponse(_ request: ModelRequest, calls: [ToolCall], state: ModelProviderContinuation, stop: StopReason = .toolCalls) -> [ModelEvent] {
    var events = toolResponse(request, calls)
    events.insert(.textDelta("Plan"), at: 1)
    events.removeLast()
    events.append(.providerContinuation(state))
    events.append(.responseCompleted(.init(info: .init(id: "response", model: request.model),
                                            content: [.text("Plan"), .providerContinuation(state)],
                                            toolCalls: calls, stopReason: stop)))
    return events
}
