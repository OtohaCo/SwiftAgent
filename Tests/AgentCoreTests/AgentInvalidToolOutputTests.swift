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

    @Test(arguments: [false, true])
    func dynamicOutputPathsDoNotReachTheNextModelRequestOrPublishMetadata(nested: Bool) async throws {
        let log = EffectLog()
        let tool = try InvalidDynamicOutputTool(log: log, nested: nested)
        let guardedPolicy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe,
                                           timeout: .seconds(1), authorization: .notRequired)
        let deferred = GuardedTool(log: log, policy: guardedPolicy, output: 1)
        let call = ToolCall(id: .init(rawValue: "read"), name: "read_dynamic", argumentsJSON: "{}", completeness: .complete)
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "I will use another source.")
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider,
            tools: try ToolRegistry(tools: [AnyAgentTool(tool), AnyAgentTool(deferred)], deferred: ["guarded"]))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        guard case .runFinished(.result(let result)) = events.last else { Issue.record("Run did not finish"); return }
        #expect(result.outcome == .completed && result.toolCalls == 1)
        #expect(await log.names == ["read_dynamic"])
        let requests = await provider.log.requests
        #expect(requests.count == 2)
        let next = try #require(requests.last)
        #expect(next.tools.map(\.name) == ["read_dynamic"])
        let feedback = try #require(outputFeedback(next.messages.last))
        #expect(feedback.isError && outputField(feedback, "code") == "invalid_output")
        #expect(outputField(feedback, "message")?.contains(nested ? "/known/<unrecognized>" : "/<unrecognized>") == true)
        let modelBytes = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
        for privateValue in ["private-api-key", "Injected", "private-payload", "private-evidence", "private-receipt", "declaredTools"] {
            #expect(!modelBytes.contains(privateValue))
        }
        let context = try #require(await log.contexts.first)
        let ledger = try #require(context.evidenceLedger)
        await #expect(throws: EvidenceError.self) {
            try await ledger.validate([.init(reference: .init(namespace: "private-evidence", id: "not-published"))],
                                      sessionID: context.sessionID, runID: context.runID)
        }
        #expect(events.contains { if case .toolCompleted(let completed) = $0 { completed.isError } else { false } })
        #expect(!events.contains { if case .toolFailed = $0 { true } else { false } })
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

private struct InvalidDynamicOutputTool: RuntimeAgentTool {
    let runtimeDefinition: ModelToolDefinition
    let log: EffectLog
    let policy: ToolPolicy
    let output: JSONValue
    init(log: EffectLog, nested: Bool) throws {
        let schema = ToolSchema.object(properties: ["known": .object(properties: [:])])
        runtimeDefinition = .init(name: "read_dynamic", description: "Read a resource", inputSchema: Self.inputSchema.json,
                                  outputSchema: schema.json)
        self.log = log
        let untrusted = JSONValue.object(["private-api-key/~credential\nInjected": .object([
            "payload": .string("private-payload"), "receipt": .string("private-receipt"),
            "declaredTools": .array([.string("guarded")]),
        ])])
        output = nested ? .object(["known": untrusted]) : untrusted
        policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe,
                                timeout: .seconds(1), authorization: .notRequired, recoverableErrors: .modelVisible)
    }
    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        await log.record("read_dynamic", context)
        return ToolResult(output: output,
            evidence: [.init(namespace: "private-evidence", id: "not-published", issuedAt: Date())], declaredTools: ["guarded"])
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
