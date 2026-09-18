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
        let sessionB = try b.makeSession()
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

    @Test func sameSessionWaitsForTimedOutToolWorkerBeforeStartingNextRun() async throws {
        let scheduler = ToolScheduler()
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "A entered")
        let returned = XCTestExpectation(description: "A returned")
        let probe = IsolationProbe()
        let providerProbe = ProviderStartProbe()
        let agent = try isolationAgent(
            scheduler: scheduler,
            tool: LeaseProbe(
                gate: gate,
                entered: entered,
                returned: returned,
                probe: probe,
                timeout: .milliseconds(100)
            ),
            providerProbe: providerProbe
        )
        let session = try agent.makeSession()
        let first = try await session.run("A")

        #expect(await providerProbe.waitUntilStarted("A"))
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        await #expect(throws: AgentLoopError.toolTimedOut(.init(rawValue: "A"))) {
            try await first.wait()
        }

        let replacement = Task { try await session.run("B") }
        try await Task.sleep(for: .milliseconds(80))
        let labelsBeforeSecondWorker = await providerProbe.labels
        #expect(labelsBeforeSecondWorker == ["A"])
        #expect(await probe.labels == ["A"])

        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        let second = try await replacement.value
        _ = try await second.wait()
        #expect(await providerProbe.labels == ["A", "B"])
        #expect(await probe.labels == ["A", "B"])
    }

    @Test func sameSessionWaitsForEveryParallelToolWorkerBeforeStartingNextRun() async throws {
        let scheduler = ToolScheduler()
        let gateA = ManualGate()
        let gateB = ManualGate()
        let enteredA = XCTestExpectation(description: "A1 entered")
        let enteredB = XCTestExpectation(description: "A2 entered")
        let returnedA = XCTestExpectation(description: "A1 returned")
        let returnedB = XCTestExpectation(description: "A2 returned")
        let providerProbe = ProviderStartProbe()
        let tool = try ParallelDrainProbe(
            gateA: gateA,
            gateB: gateB,
            enteredA: enteredA,
            enteredB: enteredB,
            returnedA: returnedA,
            returnedB: returnedB
        )
        let provider = ScriptedProvider { request, _ in
            if request.messages.last == .user([.text("A")]) {
                await providerProbe.record("A")
                return toolResponse(request, [
                    .init(id: .init(rawValue: "A1"), name: ParallelDrainProbe.name,
                          argumentsJSON: #"{"label":"A1"}"#, completeness: .complete),
                    .init(id: .init(rawValue: "A2"), name: ParallelDrainProbe.name,
                          argumentsJSON: #"{"label":"A2"}"#, completeness: .complete)
                ])
            }
            await providerProbe.record("B")
            return textResponse(request, "Done")
        }
        let agent = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [tool],
            configuration: AgentConfiguration(scheduler: scheduler)
        )
        let session = try agent.makeSession()
        let first = try await session.run("A")

        #expect(await XCTWaiter.fulfillment(of: [enteredA, enteredB], timeout: 1) == .completed)
        await first.cancel()
        await #expect(throws: CancellationError.self) { try await first.wait() }

        await gateA.open()
        #expect(await XCTWaiter.fulfillment(of: [returnedA], timeout: 1) == .completed)

        let replacement = Task { try await session.run("B") }
        try await Task.sleep(for: .milliseconds(80))
        let labelsBeforeSecondWorker = await providerProbe.labels
        #expect(labelsBeforeSecondWorker == ["A"])

        await gateB.open()
        #expect(await XCTWaiter.fulfillment(of: [returnedB], timeout: 1) == .completed)
        let second = try await replacement.value
        _ = try await second.wait()
        let labelsAfterSecondWorker = await providerProbe.labels
        #expect(labelsAfterSecondWorker == ["A", "B"])
    }
}

private func isolationAgent(
    scheduler: ToolScheduler,
    tool: LeaseProbe,
    providerProbe: ProviderStartProbe? = nil
) throws -> Agent {
    let provider = ScriptedProvider { request, _ in
        if case .tool = request.messages.last { return textResponse(request, "Done") }
        guard case .user(let content) = request.messages.last, case .text(let label) = content.last else {
            throw FixtureError.invalidOperation
        }
        await providerProbe?.record(label)
        let resource = label == "other" ? "other" : "shared"
        return toolResponse(request, [.init(id: .init(rawValue: label), name: LeaseProbe.name,
                                           argumentsJSON: "{\"label\":\"\(label)\",\"resource\":\"\(resource)\"}", completeness: .complete)])
    }
    return try Agent(
        model: fixtureModel,
        provider: provider,
        tools: [tool],
        configuration: AgentConfiguration(scheduler: scheduler)
    )
}

private actor IsolationProbe {
    private(set) var labels: [String] = []
    func record(_ label: String) { labels.append(label) }
}

private actor ProviderStartProbe {
    private(set) var labels: [String] = []
    private var waiters: [String: [CheckedContinuation<Bool, Never>]] = [:]

    func record(_ label: String) {
        labels.append(label)
        let continuations = waiters.removeValue(forKey: label) ?? []
        continuations.forEach { $0.resume(returning: true) }
    }

    func waitUntilStarted(_ label: String) async -> Bool {
        if labels.contains(label) { return true }
        return await withCheckedContinuation { continuation in
            if labels.contains(label) {
                continuation.resume(returning: true)
            } else {
                waiters[label, default: []].append(continuation)
            }
        }
    }
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

private struct ParallelDrainProbe: AgentTool {
    struct Input: Codable, Sendable { let label: String }
    typealias Output = String
    static let name = "parallel_drain_probe"
    static let description = "Wait for one of two resources"
    static let inputSchema = ToolSchema.object(properties: ["label": .string], required: ["label"])
    static let outputSchema = ToolSchema.string

    let gateA: ManualGate
    let gateB: ManualGate
    let enteredA: XCTestExpectation
    let enteredB: XCTestExpectation
    let returnedA: XCTestExpectation
    let returnedB: XCTestExpectation
    let policy: ToolPolicy

    init(
        gateA: ManualGate,
        gateB: ManualGate,
        enteredA: XCTestExpectation,
        enteredB: XCTestExpectation,
        returnedA: XCTestExpectation,
        returnedB: XCTestExpectation
    ) throws {
        self.gateA = gateA
        self.gateB = gateB
        self.enteredA = enteredA
        self.enteredB = enteredB
        self.returnedA = returnedA
        self.returnedB = returnedB
        policy = try .init(effect: .readOnly, execution: .parallel, idempotency: .safe,
                           timeout: .seconds(5), authorization: .notRequired)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "parallel", id: "shared"))]
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        if input.label == "A1" {
            enteredA.fulfill()
            await gateA.wait()
            returnedA.fulfill()
        } else {
            enteredB.fulfill()
            await gateB.wait()
            returnedB.fulfill()
        }
        return .init(output: input.label)
    }
}
