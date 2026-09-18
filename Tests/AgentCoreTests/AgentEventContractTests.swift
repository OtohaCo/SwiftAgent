import AgentCore
import AgentModels
import Foundation
import Testing
import XCTest

struct AgentEventContractTests {
    @Test func waitMatchesTheSingleTerminalEventOnSuccess() async throws {
        try await verifySessionTerminal { request in
            textResponse(request, "Hello")
        } checkWait: { result in
            #expect(result.outcome == .completed)
        } checkTerminal: { termination in
            guard case .result(let result) = termination else { return false }
            return result.outcome == .completed
        }
    }

    @Test func waitMatchesTheSingleTerminalEventOnRefusal() async throws {
        try await verifySessionTerminal { request in
            textResponse(request, "No", stop: .refusal)
        } checkWait: { result in
            #expect(result.outcome == .refused)
        } checkTerminal: { termination in
            guard case .result(let result) = termination else { return false }
            return result.outcome == .refused
        }
    }

    @Test func waitMatchesTheSingleTerminalEventOnCancellation() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Provider entered")
        let provider = ScriptedProvider { request, _ in
            entered.fulfill()
            await gate.wait()
            return textResponse(request, "Late")
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let run = try await session.run("work")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        let events = await collectEvents(run.events)
        try expectSingleLifecycle(events)
        #expect(events.last == .runFinished(.cancelled))
        await gate.open()
        try await run.waitForDrain()
    }

    @Test func waitMatchesTheSingleTerminalEventOnProviderFailure() async throws {
        let failure = ModelProviderError(kind: .rateLimited, message: "Retry later")
        let session = try Agent(
            model: fixtureModel,
            provider: ScriptedProvider { _, _ in throw failure }
        ).makeSession()
        let run = try await session.run("work")
        await #expect(throws: ModelProviderError.self) { try await run.wait() }
        let events = await collectEvents(run.events)
        try expectSingleLifecycle(events)
        #expect(events.last == .runFinished(.failed(.provider(failure))))
        try await run.waitForDrain()
    }
}

private func verifySessionTerminal(
    respond: @escaping @Sendable (ModelRequest) -> [ModelEvent],
    checkWait: (AgentLoopResult) -> Void,
    checkTerminal: (AgentRunTermination) -> Bool
) async throws {
    let provider = ScriptedProvider { request, _ in respond(request) }
    let session = try Agent(model: fixtureModel, provider: provider).makeSession()
    let run = try await session.run("work")
    let result = try await run.wait()
    checkWait(result)
    let events = await collectEvents(run.events)
    try expectSingleLifecycle(events)
    guard case .runFinished(let termination) = events.last, checkTerminal(termination) else {
        Issue.record("wait() outcome did not match runFinished")
        return
    }
    try await run.waitForDrain()
}

private func expectSingleLifecycle(_ events: [AgentEvent]) throws {
    let started = events.filter { if case .runStarted = $0 { true } else { false } }
    let finished = events.filter { if case .runFinished = $0 { true } else { false } }
    #expect(started.count == 1)
    #expect(finished.count == 1)
    #expect(events.first == started[0])
    #expect(events.last == finished[0])
}
