import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

struct AgentLoopFailureTests {
    @Test func authorizationMutationAndInvalidOutputStayFailClosed() async throws {
        let cases: [(ToolPolicy, Double, ToolInvocationError?)] = [
            (try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe, timeout: .seconds(1)), 1, .authorizationDenied),
            (try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .safe,
                            timeout: .seconds(1), authorization: .notRequired), 1, .mutationIntegrityUnavailable),
            (try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe,
                            timeout: .seconds(1), authorization: .notRequired), 1.5, nil),
        ]
        for (policy, output, expected) in cases {
            let log = EffectLog()
            let registry = try ToolRegistry(tools: [AnyAgentTool(GuardedTool(log: log, policy: policy, output: output))])
            let call = ToolCall(id: .init(rawValue: "guard"), name: "guarded", argumentsJSON: "{}", completeness: .complete)
            let provider = ScriptedProvider { request, turn in
                turn == 1 ? toolResponse(request, [call]) : textResponse(request, "Unexpected")
            }
            let loop = AgentLoop(model: fixtureModel, provider: provider, tools: registry)
            do {
                _ = try await loop.run(messages: [], sessionID: UUID(), budget: testBudget())
                Issue.record("Rejected tool was treated as success")
            } catch {
                if let expected { #expect(error as? ToolInvocationError == expected) }
                else if case .invalidOutput = error as? ToolRegistryError {} else { Issue.record("Wrong output error") }
            }
            #expect(await provider.log.requests.count == 1)
            #expect(await log.names.count == (expected == nil ? 1 : 0))
        }
    }

    @Test func transportFailureAfterTerminalDoesNotDispatchOrRetry() async throws {
        let log = EffectLog()
        let registry = try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log))])
        let provider = FailingStreamProvider()
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: registry)
        await #expect(throws: FixtureError.self) { try await loop.run(messages: [], sessionID: UUID(), budget: testBudget()) }
        #expect(await log.names.isEmpty)
        #expect(await provider.log.requests.count == 1)
    }

    @Test func cancelledCallerCannotContactProvider() async throws {
        let gate = ManualGate()
        let provider = ScriptedProvider { request, _ in textResponse(request, "Unexpected") }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let task = Task {
            await gate.wait()
            return try await loop.run(messages: [], sessionID: UUID(), budget: testBudget())
        }
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await provider.log.requests.isEmpty)
    }
}

struct GuardedTool: AgentTool {
    typealias Input = BlockingTool.Input
    typealias Output = Double
    static let name = "guarded"
    static let description = "Read a guarded resource"
    static let inputSchema = BlockingTool.inputSchema
    static let outputSchema = ToolSchema.integer
    let log: EffectLog
    let policy: ToolPolicy
    let output: Double
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record(Self.name, context)
        return ToolResult(output: output)
    }
}

struct FailingStreamProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.tools, .multiTurn])
    let log = RequestLog()
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            _ = await log.record(request)
            for event in toolResponse(request, [addition("1")]) { try emit(event) }
            throw FixtureError.invalidOperation
        }
    }
}
