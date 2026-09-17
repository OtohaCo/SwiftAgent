import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentEventFailureTests {
    @Test func rejectedAuthorizationClosesToolBeforeRunFailure() async throws {
        let log = EffectLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe, timeout: .seconds(1))
        let tool = GuardedTool(log: log, policy: policy, output: 1)
        let call = ToolCall(id: .init(rawValue: "guard"), name: "guarded", argumentsJSON: "{}", completeness: .complete)
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(tool)]))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        let failure = AgentFailure.toolInvocation(.authorizationDenied)
        #expect(Array(events.suffix(3)) == [.toolStarted(call), .toolFailed(call.id, failure), .runFinished(.failed(failure))])
        #expect(await log.names.isEmpty)
        #expect(events.filter { if case .runFinished = $0 { true } else { false } }.count == 1)
    }

    @Test func unknownToolFailsWithoutPublishingToolStart() async throws {
        let call = ToolCall(id: .init(rawValue: "unknown"), name: "missing", argumentsJSON: "{}", completeness: .complete)
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        #expect(events.last == .runFinished(.failed(.toolRegistry(.unknownTool("missing")))))
        #expect(!events.contains { if case .toolStarted = $0 { true } else { false } })
    }

    @Test func timeoutClosesActiveToolOnceAndLateResultsCannotPublishSuccess() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Tool entered")
        let returned = XCTestExpectation(description: "Tool returned")
        let finished = XCTestExpectation(description: "Stream finished")
        let tool = try BlockingTool(gate: gate, entered: entered, returned: returned, timeout: .milliseconds(100))
        let provider = ScriptedProvider { request, _ in toolResponse(request, [blockingCall]) }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(tool)]))
        let stream = loop.events(messages: [], sessionID: UUID(), budget: try testBudget())
        let observer = Task {
            let events = await collectEvents(stream)
            finished.fulfill()
            return events
        }
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        #expect(await XCTWaiter.fulfillment(of: [finished], timeout: 1) == .completed)
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        let events = await observer.value
        let failure = AgentFailure.loop(.toolTimedOut(blockingCall.id))
        #expect(Array(events.suffix(3)) == [.toolStarted(blockingCall), .toolFailed(blockingCall.id, failure), .runFinished(.failed(failure))])
        #expect(!events.contains { if case .toolCompleted = $0 { true } else { false } })
        #expect(await provider.log.requests.count == 1)
    }

    @Test func invalidOutputNeverPublishesToolCompletion() async throws {
        let log = EffectLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let tool = GuardedTool(log: log, policy: policy, output: 1.5)
        let call = ToolCall(id: .init(rawValue: "guard"), name: "guarded", argumentsJSON: "{}", completeness: .complete)
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(tool)]))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        guard case .runFinished(.failed(.toolRegistry(.invalidOutput(let issue)))) = events.last else {
            Issue.record("Missing invalid-output terminal"); return
        }
        #expect(issue.keyword == "type")
        #expect(Array(events.suffix(2)) == [.toolFailed(call.id, .toolRegistry(.invalidOutput(issue))),
                                          .runFinished(.failed(.toolRegistry(.invalidOutput(issue))))])
        #expect(!events.contains { if case .toolCompleted = $0 { true } else { false } })
    }

    @Test func preflightAndProviderFailuresAreTypedAndTerminateOnce() async throws {
        let sessionID = UUID(), runID = UUID()
        let provider = ScriptedProvider { request, _ in textResponse(request, "Unexpected") }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let expired = try AgentBudget(maxModelTurns: 1, maxToolCalls: 0, deadline: .now.advanced(by: .seconds(-1)))
        let events = await collectEvents(loop.events(messages: [], sessionID: sessionID, runID: runID, budget: expired))
        #expect(events == [.runStarted(.init(sessionID: sessionID, runID: runID, model: fixtureModel)),
                           .runFinished(.failed(.loop(.deadlineExceeded)))])
        #expect(await provider.log.requests.isEmpty)
        let failure = ModelProviderError(kind: .rateLimited, message: "Retry later", retryAfter: .seconds(1))
        let limited = ScriptedProvider { _, _ in throw failure }
        let other = AgentLoop(model: fixtureModel, provider: limited, tools: try ToolRegistry(tools: []))
        let failed = await collectEvents(other.events(messages: [], sessionID: sessionID, runID: runID, budget: try testBudget()))
        #expect(failed == [.runStarted(.init(sessionID: sessionID, runID: runID, model: fixtureModel)), .turnStarted(1),
                           .runFinished(.failed(.provider(failure)))])
    }

    @Test func toolCancellationClosesItsAttemptBeforeRunCancellation() async throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let call = ToolCall(id: .init(rawValue: "cancel"), name: "self_cancel", argumentsJSON: "{}", completeness: .complete)
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let loop = AgentLoop(model: fixtureModel, provider: provider,
                             tools: try ToolRegistry(tools: [AnyAgentTool(SelfCancellingTool(policy: policy))]))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        #expect(Array(events.suffix(3)) == [.toolStarted(call), .toolFailed(call.id, .cancelled), .runFinished(.cancelled)])
    }

    @Test func executorErrorsCloseAttemptsWithoutLeakingRawErrorDescriptions() async throws {
        let call = ToolCall(id: .init(rawValue: "overflow"), name: "add",
                            argumentsJSON: "{\"lhs\":\(Int.max),\"rhs\":1}", completeness: .complete)
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let loop = AgentLoop(model: fixtureModel, provider: provider,
                             tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: EffectLog()))]))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        #expect(Array(events.suffix(3)) == [.toolStarted(call), .toolFailed(call.id, .unclassified), .runFinished(.failed(.unclassified))])
    }
}

struct SelfCancellingTool: AgentTool {
    typealias Input = BlockingTool.Input
    typealias Output = String
    static let name = "self_cancel"
    static let description = "Read a cancelled resource"
    static let inputSchema = BlockingTool.inputSchema
    static let outputSchema = ToolSchema.string
    let policy: ToolPolicy
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> { throw CancellationError() }
}
