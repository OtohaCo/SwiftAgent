import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

/// A read-only tool that declares its recoverable errors model-visible returned something its output
/// schema does not allow, or that cannot be carried as JSON. Nothing was changed, so the model is told
/// the tool's result could not be used and the Run goes on. Every other tool still fails closed.
struct AgentInvalidToolOutputTests {
    private func run(output: Double, recoverableErrors: ToolPolicy.RecoverableErrors) async throws
        -> (result: AgentLoopResult?, events: [AgentEvent], requests: [ModelRequest]) {
        let policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired,
                                    recoverableErrors: recoverableErrors)
        let call = ToolCall(id: .init(rawValue: "page"), name: "guarded", argumentsJSON: "{}", completeness: .complete)
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "I will look elsewhere.")
        }
        let tool = GuardedTool(log: EffectLog(), policy: policy, output: output)
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(tool)]))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        let result: AgentLoopResult?
        if case .runFinished(.result(let finished)) = events.last { result = finished } else { result = nil }
        return (result, events, await provider.log.requests)
    }

    @Test func anOutputOutsideItsSchemaGoesBackToTheModel() async throws {
        let (result, events, requests) = try await run(output: 1.5, recoverableErrors: .modelVisible)

        #expect(result?.outcome == .completed)
        #expect(requests.count == 2)
        let feedback = try #require(outputFeedback(requests.last?.messages.last))
        #expect(feedback.callID == ToolCallID(rawValue: "page") && feedback.isError)
        #expect(outputField(feedback, "code") == "invalid_output")
        let message = try #require(outputField(feedback, "message"))
        #expect(message.contains("guarded") && message.contains("output schema") && message.contains("\"type\""))
        // What the tool returned is not passed on: it is what could not be checked.
        #expect(!message.contains("1.5"))
        #expect(events.contains { if case .toolCompleted(let completed) = $0 { completed.isError } else { false } })
        #expect(!events.contains { if case .toolFailed = $0 { true } else { false } })
    }

    @Test func anOutputThatIsNotJSONGoesBackToTheModel() async throws {
        let (result, _, requests) = try await run(output: .nan, recoverableErrors: .modelVisible)

        #expect(result?.outcome == .completed)
        let feedback = try #require(outputFeedback(requests.last?.messages.last))
        #expect(feedback.isError && outputField(feedback, "code") == "invalid_output")
    }

    @Test(arguments: [1.5, Double.nan])
    func aToolThatFailsClosedStillEndsTheRun(_ output: Double) async throws {
        let (result, events, requests) = try await run(output: output, recoverableErrors: .failClosed)

        #expect(result == nil)
        #expect(requests.count == 1)
        guard case .runFinished(.failed(let failure)) = events.last else { Issue.record("The run did not fail"); return }
        switch failure {
        case .toolRegistry(.invalidOutput), .toolInvocation(.invalidOutput): break
        default: Issue.record("Unexpected failure \(failure)")
        }
    }
}

private func outputFeedback(_ message: ModelMessage?) -> ToolResultMessage? {
    if case .tool(let result) = message { return result }
    return nil
}

private func outputField(_ result: ToolResultMessage, _ key: String) -> String? {
    guard case .json(.object(let object)) = result.content.first, case .string(let value) = object[key] else { return nil }
    return value
}
