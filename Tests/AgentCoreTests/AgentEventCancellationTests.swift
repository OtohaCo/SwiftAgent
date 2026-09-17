import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentEventCancellationTests {
    @Test func modelCancellationIsAnObservableTerminalEvent() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "Stopped", stop: .cancelled) }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        #expect(events.last == .runFinished(.cancelled))
        #expect(events.filter { if case .runFinished = $0 { true } else { false } }.count == 1)
    }

    @Test func alreadyCancelledCreatorPublishesCancellationWithoutStartingProvider() async throws {
        let gate = ManualGate()
        let provider = ScriptedProvider { request, _ in textResponse(request, "Unexpected") }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let sessionID = UUID(), runID = UUID(), budget = try testBudget()
        let creator = Task {
            await gate.wait()
            return loop.events(messages: [], sessionID: sessionID, runID: runID, budget: budget)
        }
        creator.cancel()
        await gate.open()
        let events = await collectEvents(await creator.value)
        #expect(events == [.runStarted(.init(sessionID: sessionID, runID: runID, model: fixtureModel)), .runFinished(.cancelled)])
        #expect(await provider.log.requests.isEmpty)
    }

    @Test func cancellingConsumerCancelsProviderAndDoesNotAffectAnotherStream() async throws {
        let entered = XCTestExpectation(description: "Provider entered")
        let cancelled = XCTestExpectation(description: "Provider cancelled")
        let stopped = XCTestExpectation(description: "Provider stopped")
        let enteredB = XCTestExpectation(description: "B entered")
        let gateB = ManualGate()
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let provider = LiveProvider { request, emit in
            if request.messages == [.user([.text("B")])] {
                enteredB.fulfill()
                await gateB.wait()
                for event in textResponse(request, "B result") { try emit(event) }
                return
            }
            defer { stopped.fulfill() }
            entered.fulfill()
            await withTaskCancellationHandler {
                for await _ in gate.stream {}
            } onCancel: { cancelled.fulfill() }
            try Task.checkCancellation()
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let a = loop.events(messages: [.user([.text("A")])], sessionID: UUID(), budget: try testBudget())
        let observer = Task { await collectEvents(a) }
        let bStream = loop.events(messages: [.user([.text("B")])], sessionID: UUID(), budget: try testBudget())
        let observerB = Task { await collectEvents(bStream) }
        #expect(await XCTWaiter.fulfillment(of: [entered, enteredB], timeout: 1) == .completed)
        observer.cancel()
        _ = await observer.value
        #expect(await XCTWaiter.fulfillment(of: [cancelled, stopped], timeout: 1) == .completed)
        await gateB.open()
        let b = await observerB.value
        guard case .runFinished(.result(let result)) = b.last else { Issue.record("Second stream failed"); return }
        #expect(result.response.content == [.text("B result")])
        #expect(!b.contains(.model(.textDelta("A"))))
    }

    @Test func overallDeadlineClosesThePendingToolBeforeRun() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Tool entered")
        let returned = XCTestExpectation(description: "Tool returned")
        let finished = XCTestExpectation(description: "Stream finished")
        let tool = try BlockingTool(gate: gate, entered: entered, returned: returned, timeout: .seconds(5))
        let provider = ScriptedProvider { request, _ in toolResponse(request, [blockingCall]) }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(tool)]))
        let budget = try AgentBudget(maxModelTurns: 2, maxToolCalls: 1, deadline: .now.advanced(by: .milliseconds(150)))
        let stream = loop.events(messages: [], sessionID: UUID(), budget: budget)
        let observer = Task {
            let events = await collectEvents(stream)
            finished.fulfill()
            return events
        }
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        #expect(await XCTWaiter.fulfillment(of: [finished], timeout: 1) == .completed)
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        let failure = AgentFailure.loop(.deadlineExceeded)
        #expect(Array(await observer.value.suffix(3)) == [
            .toolStarted(blockingCall), .toolFailed(blockingCall.id, failure), .runFinished(.failed(failure)),
        ])
    }

    @Test func consumerCancellationReachesActiveAuthorizationAndExecution() async throws {
        for phase in [EventWaitPhase.authorization, .execution] {
            let entered = XCTestExpectation(description: "Tool phase entered")
            let cancelled = XCTestExpectation(description: "Tool phase cancelled")
            let stopped = XCTestExpectation(description: "Tool phase stopped")
            let gate = AsyncStream<Void>.makeStream()
            defer { gate.continuation.finish() }
            let log = EffectLog()
            let tool = try EventCancellableTool(phase: phase, gate: gate.stream, entered: entered,
                                                cancelled: cancelled, stopped: stopped, log: log)
            let call = ToolCall(id: .init(rawValue: "wait"), name: "event_wait", argumentsJSON: "{}", completeness: .complete)
            let provider = ScriptedProvider { request, turn in
                turn == 1 ? toolResponse(request, [call]) : textResponse(request, "Unexpected")
            }
            let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(tool)]))
            let stream = loop.events(messages: [], sessionID: UUID(), budget: try testBudget())
            let observer = Task { await collectEvents(stream) }
            #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
            observer.cancel()
            _ = await observer.value
            #expect(await XCTWaiter.fulfillment(of: [cancelled, stopped], timeout: 1) == .completed)
            #expect(await log.names == (phase == .authorization ? [] : ["execute"]))
            #expect(await provider.log.requests.count == 1)
        }
    }
}

enum EventWaitPhase: Sendable { case authorization, execution }

struct EventCancellableTool: AgentTool {
    typealias Input = BlockingTool.Input
    typealias Output = String
    static let name = "event_wait"
    static let description = "Read a cancellable resource"
    static let inputSchema = BlockingTool.inputSchema
    static let outputSchema = ToolSchema.string
    let phase: EventWaitPhase
    let gate: AsyncStream<Void>
    let entered: XCTestExpectation
    let cancelled: XCTestExpectation
    let stopped: XCTestExpectation
    let log: EffectLog
    let policy: ToolPolicy

    init(phase: EventWaitPhase, gate: AsyncStream<Void>, entered: XCTestExpectation,
         cancelled: XCTestExpectation, stopped: XCTestExpectation, log: EffectLog) throws {
        self.phase = phase
        self.gate = gate
        self.entered = entered
        self.cancelled = cancelled
        self.stopped = stopped
        self.log = log
        policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe,
                                timeout: .seconds(5), authorization: phase == .authorization ? .required : .notRequired)
    }
    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        if phase == .authorization { try await waitForCancellation() }
        return .allowed
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record("execute", context)
        if phase == .execution { try await waitForCancellation() }
        return ToolResult(output: "Ready")
    }
    private func waitForCancellation() async throws {
        defer { stopped.fulfill() }
        entered.fulfill()
        await withTaskCancellationHandler {
            for await _ in gate {}
        } onCancel: { cancelled.fulfill() }
        try Task.checkCancellation()
    }
}
