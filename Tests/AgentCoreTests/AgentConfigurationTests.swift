import AgentCore
import AgentModels
import Foundation
import Testing

struct AgentConfigurationTests {
    @Test func configurationRejectsInvalidLimitsAndPreservesStructuredOutput() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, #"{"value":1}"#) }
        #expect(throws: AgentLoopError.invalidBudget) { try Agent(model: fixtureModel, provider: provider, maxModelTurns: 0) }
        #expect(throws: AgentLoopError.invalidBudget) { try Agent(model: fixtureModel, provider: provider, maxToolCalls: -1) }
        #expect(throws: AgentLoopError.invalidBudget) { try Agent(model: fixtureModel, provider: provider, runTimeout: .zero) }
        let schema = StructuredOutputSchema(name: "value", schema: .object(["type": .string("object")]))
        let session = try Agent(model: fixtureModel, provider: provider, structuredOutput: schema).makeSession()
        let run = try await session.run("value")
        _ = try await run.wait()
        #expect(await provider.log.requests.first?.structuredOutput == schema)
    }

    @Test func cancelledOrExpiredCallerDoesNotAppendUserInput() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "Unexpected") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let expired = try AgentBudget(maxModelTurns: 1, maxToolCalls: 0, deadline: .now.advanced(by: .seconds(-1)))
        await #expect(throws: AgentLoopError.deadlineExceeded) { try await session.run("expired", budget: expired) }
        let gate = ManualGate()
        let caller = Task { await gate.wait(); return try await session.run("cancelled") }
        caller.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(await session.history.isEmpty)
        #expect(await provider.log.requests.isEmpty)
    }
}
