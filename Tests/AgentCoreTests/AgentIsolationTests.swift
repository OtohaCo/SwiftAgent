import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentIsolationTests {
    @Test(arguments: [false, true])
    func timedOutOrCancelledExecutorKeepsItsLeaseUntilItActuallyReturns(cancel: Bool) async throws {
        let scheduler = ToolScheduler()
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "A entered"), returned = XCTestExpectation(description: "A returned")
        let probe = IsolationProbe()
        let a = try isolationAgent(scheduler: scheduler, tool: LeaseProbe(gate: gate, entered: entered, returned: returned,
                                                                         probe: probe, timeout: cancel ? .seconds(5) : .milliseconds(100)))
        let b = try isolationAgent(scheduler: scheduler, tool: LeaseProbe(gate: gate, entered: entered, returned: returned,
                                                                         probe: probe, timeout: .milliseconds(100)))
        let run = try await a.makeSession().run("A")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        if cancel {
            await run.cancel()
            await #expect(throws: CancellationError.self) { try await run.wait() }
        } else {
            await #expect(throws: AgentLoopError.toolTimedOut(.init(rawValue: "A"))) { try await run.wait() }
        }
        let sessionB = b.makeSession()
        await #expect(throws: AgentLoopError.toolTimedOut(.init(rawValue: "B"))) { try await sessionB.run("B").wait() }
        #expect(await probe.labels == ["A"])
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        #expect(try await sessionB.run("C").wait().outcome == .completed)
        #expect(await probe.labels == ["A", "C"])
    }

    @Test func unrelatedResourcesCanProgressWhileAnExclusiveExecutorIsStillActive() async throws {
        let scheduler = ToolScheduler(), gate = ManualGate()
        let entered = XCTestExpectation(description: "A entered"), returned = XCTestExpectation(description: "A returned")
        let probe = IsolationProbe()
        let agent = try isolationAgent(scheduler: scheduler, tool: LeaseProbe(gate: gate, entered: entered, returned: returned,
                                                                             probe: probe, timeout: .seconds(3)))
        let a = try await agent.makeSession().run("A")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        #expect(try await agent.makeSession().run("other").wait().outcome == .completed)
        #expect(await probe.labels == ["A", "other"])
        await gate.open()
        #expect(try await a.wait().outcome == .completed)
    }
}

private func isolationAgent(scheduler: ToolScheduler, tool: LeaseProbe) throws -> Agent {
    let provider = ScriptedProvider { request, _ in
        if case .tool = request.messages.last { return textResponse(request, "Done") }
        guard case .user(let content) = request.messages.last, case .text(let label) = content.last else {
            throw FixtureError.invalidOperation
        }
        let resource = label == "other" ? "other" : "shared"
        return toolResponse(request, [.init(id: .init(rawValue: label), name: LeaseProbe.name,
                                           argumentsJSON: "{\"label\":\"\(label)\",\"resource\":\"\(resource)\"}", completeness: .complete)])
    }
    return try Agent(model: fixtureModel, provider: provider, tools: [tool], scheduler: scheduler)
}

private actor IsolationProbe {
    private(set) var labels: [String] = []
    func record(_ label: String) { labels.append(label) }
}

private struct LeaseProbe: AgentTool {
    struct Input: Codable, Sendable { let label: String; let resource: String }
    typealias Output = String
    static let name = "lease_probe"
    static let description = "Read a resource under an exclusive lease"
    static let inputSchema = ToolSchema.object(properties: ["label": .string, "resource": .string], required: ["label", "resource"])
    static let outputSchema = ToolSchema.string
    let policy: ToolPolicy
    let gate: ManualGate
    let entered: XCTestExpectation, returned: XCTestExpectation
    let probe: IsolationProbe
    init(gate: ManualGate, entered: XCTestExpectation, returned: XCTestExpectation, probe: IsolationProbe, timeout: Duration) throws {
        self.gate = gate; self.entered = entered; self.returned = returned; self.probe = probe
        policy = try .init(effect: .readOnly, execution: .exclusive, idempotency: .safe, timeout: timeout, authorization: .notRequired)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "resource", id: input.resource))]
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        await probe.record(input.label)
        if input.label == "A" { entered.fulfill(); await gate.wait(); returned.fulfill() }
        return .init(output: input.label)
    }
}
