import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentSchedulingTests {
    @Test func oneReadFailureDoesNotCancelAnAlreadyStartedIndependentRead() async throws {
        let firstGate = ManualGate(), secondGate = ManualGate()
        await firstGate.open()
        defer { Task { await secondGate.open() } }
        let tool = try ParallelProbe(first: .init(description: "First entered"), second: .init(description: "Second entered"),
                                     secondDone: .init(description: "Second returned"), firstGate: firstGate, secondGate: secondGate,
                                     order: SchedulingOrder(), failFirst: true)
        let calls = [1, 2].map { ToolCall(id: .init(rawValue: "call-\($0)"), name: ParallelProbe.name,
                                         argumentsJSON: "{\"value\":\($0)}", completeness: .complete) }
        let provider = ScriptedProvider { request, _ in toolResponse(request, calls) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [tool]).makeSession()
        let run = try await session.run("Read both")
        let observer = Task {
            var events: [AgentEvent] = []
            for await event in run.events {
                events.append(event)
                if case .toolFailed(let id, _) = event, id == calls[0].id { await secondGate.open() }
            }
            return events
        }
        await #expect(throws: FixtureError.invalidOperation) { try await run.wait() }
        let events = await observer.value
        #expect(events.contains { if case .toolCompleted(let result) = $0 { result.callID == calls[1].id } else { false } })
        #expect(await session.history.contains(.assistant(content: [], toolCalls: [calls[1]])))
    }

    @Test func readOnlyCallsOverlapButHistoryKeepsProposalOrder() async throws {
        let first = XCTestExpectation(description: "First entered"), second = XCTestExpectation(description: "Second entered")
        let secondDone = XCTestExpectation(description: "Second finished")
        let secondCommitted = XCTestExpectation(description: "Second result committed")
        let firstGate = ManualGate(), secondGate = ManualGate()
        let order = SchedulingOrder()
        let tool = try ParallelProbe(first: first, second: second, secondDone: secondDone,
                                     firstGate: firstGate, secondGate: secondGate, order: order)
        let calls = [1, 2].map { ToolCall(id: .init(rawValue: "call-\($0)"), name: ParallelProbe.name,
                                         argumentsJSON: "{\"value\":\($0)}", completeness: .complete) }
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, calls) : textResponse(request, "Done")
        }
        let run = try await Agent(model: fixtureModel, provider: provider, tools: [tool]).makeSession().run("Read both")
        let events = Task {
            var observed: [AgentEvent] = []
            for await event in run.events {
                observed.append(event)
                if case .toolCompleted(let result) = event, result.callID == calls[1].id { secondCommitted.fulfill() }
            }
            return observed
        }
        #expect(await XCTWaiter.fulfillment(of: [first, second], timeout: 1) == .completed)
        await secondGate.open()
        #expect(await XCTWaiter.fulfillment(of: [secondDone], timeout: 1) == .completed)
        #expect(await XCTWaiter.fulfillment(of: [secondCommitted], timeout: 1) == .completed)
        await firstGate.open()
        let result = try await run.wait()
        #expect(await order.values == [2, 1])
        #expect(result.history.compactMap { if case .tool(let result) = $0 { result.callID } else { nil } } == calls.map(\.id))
        #expect(result.toolCalls == 2)
        let observed = await events.value
        #expect(observed.compactMap { if case .toolStarted(let call) = $0 { call.id } else { nil } } == calls.map(\.id))
        #expect(observed.compactMap { if case .toolCompleted(let result) = $0 { result.callID } else { nil } } == [calls[1].id, calls[0].id])
    }

    @Test func parallelFailureRetainsACompletedLaterCallWithoutDanglingProposals() async throws {
        let first = XCTestExpectation(description: "First entered"), second = XCTestExpectation(description: "Second entered")
        let secondDone = XCTestExpectation(description: "Second returned")
        let firstGate = ManualGate(), secondGate = ManualGate()
        await secondGate.open()
        let tool = try ParallelProbe(first: first, second: second, secondDone: secondDone,
                                     firstGate: firstGate, secondGate: secondGate, order: SchedulingOrder(), failFirst: true)
        let calls = [1, 2].map { ToolCall(id: .init(rawValue: "call-\($0)"), name: ParallelProbe.name,
                                         argumentsJSON: "{\"value\":\($0)}", completeness: .complete) }
        let provider = ScriptedProvider { request, _ in toolResponse(request, calls) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [tool]).makeSession()
        let run = try await session.run("Read both")
        let observer = Task {
            for await event in run.events {
                if case .toolCompleted(let result) = event, result.callID == calls[1].id { await firstGate.open() }
            }
        }
        await #expect(throws: FixtureError.invalidOperation) { try await run.wait() }
        await observer.value
        let history = await session.history
        #expect(history == [.user([.text("Read both")]), .assistant(content: [], toolCalls: [calls[1]]),
                            .tool(.init(callID: calls[1].id, content: [.json(.number(2))], isError: false))])
        #expect(await provider.log.requests.count == 1)
    }
}

private actor SchedulingOrder {
    private(set) var values: [Int] = []
    func record(_ value: Int) { values.append(value) }
}

private struct ParallelProbe: AgentTool {
    struct Input: Codable, Sendable { let value: Int }
    typealias Output = Int
    static let name = "parallel_probe"
    static let description = "Read independent resources"
    static let inputSchema = ToolSchema.object(properties: ["value": .integer], required: ["value"])
    static let outputSchema = ToolSchema.integer
    let policy: ToolPolicy
    let first: XCTestExpectation, second: XCTestExpectation, secondDone: XCTestExpectation
    let firstGate: ManualGate, secondGate: ManualGate
    let order: SchedulingOrder
    let failFirst: Bool
    init(first: XCTestExpectation, second: XCTestExpectation, secondDone: XCTestExpectation,
         firstGate: ManualGate, secondGate: ManualGate, order: SchedulingOrder, failFirst: Bool = false) throws {
        self.first = first; self.second = second; self.secondDone = secondDone
        self.firstGate = firstGate; self.secondGate = secondGate; self.order = order
        self.failFirst = failFirst
        policy = try .init(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(5), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Int> {
        if input.value == 1 { first.fulfill(); await firstGate.wait() }
        else { second.fulfill(); await secondGate.wait() }
        if input.value == 1, failFirst { throw FixtureError.invalidOperation }
        await order.record(input.value)
        if input.value == 2 { secondDone.fulfill() }
        return .init(output: input.value)
    }
}
