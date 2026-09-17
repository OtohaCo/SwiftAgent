import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentEventStreamingTests {
    @Test func textDeltaArrivesBeforeProviderFinishes() async throws {
        let gate = ManualGate()
        let received = XCTestExpectation(description: "Delta received")
        let provider = LiveProvider { request, emit in
            let info = ResponseInfo(id: "live", model: request.model)
            try emit(.responseStarted(info))
            try emit(.textDelta("First"))
            await gate.wait()
            try emit(.textDelta(" second"))
            try emit(.responseCompleted(.init(info: info, content: [.text("First second")], stopReason: .endTurn)))
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let stream = loop.events(messages: [], sessionID: UUID(), budget: try testBudget())
        let observer = Task {
            var events: [AgentEvent] = []
            for await event in stream {
                events.append(event)
                if event == .model(.textDelta("First")) { received.fulfill() }
            }
            return events
        }
        #expect(await XCTWaiter.fulfillment(of: [received], timeout: 1) == .completed)
        await gate.open()
        let events = await observer.value
        guard case .runFinished(.result(let result)) = events.last else { Issue.record("Missing result"); return }
        #expect(result.response.content == [.text("First second")])
    }

    @Test func terminalBeforeTransportFailureIsNeverPublishedAsModelCompletion() async throws {
        let provider = LiveProvider { request, emit in
            for event in textResponse(request, "Provisional") { try emit(event) }
            throw FixtureError.invalidOperation
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        #expect(!events.contains { if case .model(.responseCompleted) = $0 { true } else { false } })
        #expect(events.last == .runFinished(.failed(.unclassified)))
        #expect(events.filter { if case .runFinished = $0 { true } else { false } }.count == 1)
    }

    @Test func wrongModelIdentityIsNotForwardedToConsumers() async throws {
        let provider = LiveProvider { _, emit in
            try emit(.responseStarted(.init(id: "wrong", model: .init(provider: "fixture", name: "other"))))
            try emit(.textDelta("Wrong answer"))
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        #expect(events.last == .runFinished(.failed(.loop(.modelMismatch))))
        #expect(!events.contains { if case .model = $0 { true } else { false } })
    }

    @Test func missingTerminalAndTrailingFramesEndWithProtocolFailure() async throws {
        for trailing in [false, true] {
            let provider = ScriptedProvider { request, _ in
                let events = textResponse(request, "Provisional")
                return trailing ? events + [.textDelta("late")] : Array(events.dropLast())
            }
            let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
            let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
            let failure = AgentFailure.modelStream(trailing ? .eventAfterTerminal : .missingTerminal)
            #expect(Array(events.dropFirst(2)) == [.model(.responseStarted(.init(id: "response", model: fixtureModel))),
                                                   .model(.textDelta("Provisional")), .runFinished(.failed(failure))])
        }
    }

    @Test func reasoningUsageAndNonCompletedOutcomesRemainTyped() async throws {
        for stop in [StopReason.refusal, .maxOutputTokens] {
            let usage = ModelUsage(inputTokens: 3, outputTokens: 2, reasoningTokens: 1)
            let provider = ScriptedProvider { request, _ in
                let info = ResponseInfo(id: "r", model: request.model)
                return [.responseStarted(info), .reasoningDelta("Checking"), .textDelta("Partial"), .usage(usage),
                        .responseCompleted(.init(info: info, content: [.reasoning("Checking"), .text("Partial")], usage: usage, stopReason: stop))]
            }
            let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
            let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
            #expect(Array(events.dropFirst(3).prefix(3)) == [.model(.reasoningDelta("Checking")), .model(.textDelta("Partial")), .model(.usage(usage))])
            guard case .runFinished(.result(let result)) = events.last else { Issue.record("Missing terminal result"); continue }
            #expect(result.outcome == (stop == .refusal ? .refused : .incomplete(stop)))
            #expect(result.response.usage == usage)
        }
    }
}

struct LiveProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.streaming, .tools, .multiTurn, .structuredOutput])
    let produce: @Sendable (ModelRequest, @escaping ModelEventStream.Emit) async throws -> Void
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in try await produce(request, emit) }
    }
}

func collectEvents(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in stream { events.append(event) }
    return events
}
