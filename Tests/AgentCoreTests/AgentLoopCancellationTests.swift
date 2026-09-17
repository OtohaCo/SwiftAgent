import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentLoopCancellationTests {
    @Test func deadlineEndsAStalledProviderRequest() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Provider entered")
        let finished = XCTestExpectation(description: "Run finished")
        let provider = ScriptedProvider { request, _ in
            entered.fulfill()
            await gate.wait()
            return textResponse(request, "Late answer")
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let budget = try AgentBudget(maxModelTurns: 2, maxToolCalls: 1, deadline: .now.advanced(by: .milliseconds(150)))
        let task = Task {
            defer { finished.fulfill() }
            do { return Result<AgentLoopResult, Error>.success(try await loop.run(messages: [], sessionID: UUID(), budget: budget)) }
            catch { return .failure(error) }
        }
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        #expect(await XCTWaiter.fulfillment(of: [finished], timeout: 1) == .completed)
        await gate.open()
        let result = await task.value
        guard case .failure(let error) = result else { Issue.record("Late answer accepted"); return }
        #expect(error as? AgentLoopError == .deadlineExceeded)
    }

    @Test func cancellationReturnsWithoutWaitingForAnUncooperativeTool() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Tool entered")
        let finished = XCTestExpectation(description: "Run finished")
        let returned = XCTestExpectation(description: "Tool returned")
        let log = EffectLog()
        let tool = try BlockingTool(gate: gate, entered: entered, returned: returned, timeout: .seconds(5))
        let registry = try ToolRegistry(tools: [AnyAgentTool(tool), AnyAgentTool(AddTool(log: log))])
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [blockingCall, addition("after")]) : textResponse(request, "Unexpected")
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: registry)
        let task = Task {
            defer { finished.fulfill() }
            do { return Result<AgentLoopResult, Error>.success(try await loop.run(messages: [], sessionID: UUID(), budget: testBudget())) }
            catch { return .failure(error) }
        }
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        task.cancel()
        #expect(await XCTWaiter.fulfillment(of: [finished], timeout: 1) == .completed)
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        guard case .failure(let error) = await task.value else { Issue.record("Cancelled run succeeded"); return }
        #expect(error is CancellationError)
        #expect(await log.names.isEmpty)
        #expect(await provider.log.requests.count == 1)
    }

    @Test func toolTimeoutEndsRunBeforeOverallDeadlineAndDiscardsLateResult() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Tool entered")
        let returned = XCTestExpectation(description: "Tool returned")
        let finished = XCTestExpectation(description: "Run finished")
        let log = EffectLog()
        let registry = try ToolRegistry(tools: [
            AnyAgentTool(BlockingTool(gate: gate, entered: entered, returned: returned, timeout: .milliseconds(100))),
            AnyAgentTool(AddTool(log: log)),
        ])
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [blockingCall, addition("after")]) : textResponse(request, "Unexpected")
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: registry)
        let task = Task {
            defer { finished.fulfill() }
            do { return Result<AgentLoopResult, Error>.success(try await loop.run(messages: [], sessionID: UUID(), budget: testBudget())) }
            catch { return .failure(error) }
        }
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        #expect(await XCTWaiter.fulfillment(of: [finished], timeout: 1) == .completed)
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        guard case .failure(let error) = await task.value else { Issue.record("Late tool result accepted"); return }
        #expect(error as? AgentLoopError == .toolTimedOut(blockingCall.id))
        #expect(await log.names.isEmpty)
        #expect(await provider.log.requests.count == 1)
    }

    @Test func concurrentRunsKeepCancellationAndHistoryIndependent() async throws {
        let gateA = ManualGate(), gateB = ManualGate()
        let enteredA = XCTestExpectation(description: "A entered"), enteredB = XCTestExpectation(description: "B entered")
        let messagesA: [ModelMessage] = [.user([.text("A")])], messagesB: [ModelMessage] = [.user([.text("B")])]
        let provider = ScriptedProvider { request, _ in
            if request.messages == messagesA {
                enteredA.fulfill()
                await gateA.wait()
                return textResponse(request, "A result")
            }
            enteredB.fulfill()
            await gateB.wait()
            return textResponse(request, "B result")
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let a = Task { try await loop.run(messages: messagesA, sessionID: UUID(), budget: testBudget()) }
        let b = Task { try await loop.run(messages: messagesB, sessionID: UUID(), budget: testBudget()) }
        #expect(await XCTWaiter.fulfillment(of: [enteredA, enteredB], timeout: 1) == .completed)
        a.cancel()
        await #expect(throws: CancellationError.self) { try await a.value }
        await gateB.open()
        #expect(try await b.value.history == messagesB + [.assistant(content: [.text("B result")], toolCalls: [])])
        await gateA.open()
    }

    @Test func lateAuthorizationCannotExecuteAndReceivesTheToolDeadline() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Authorization entered")
        let returned = XCTestExpectation(description: "Authorization returned")
        let finished = XCTestExpectation(description: "Run finished")
        let log = EffectLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe, timeout: .milliseconds(100))
        let tool = ApprovalTool(gate: gate, log: log, entered: entered, returned: returned, policy: policy)
        let call = ToolCall(id: .init(rawValue: "approve"), name: "approval", argumentsJSON: "{}", completeness: .complete)
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "Unexpected")
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(tool)]))
        let budget = try testBudget()
        let task = Task {
            defer { finished.fulfill() }
            do { return Result<AgentLoopResult, Error>.success(try await loop.run(messages: [], sessionID: UUID(), budget: budget)) }
            catch { return .failure(error) }
        }
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        if let deadline = await log.contexts.first?.deadline { #expect(deadline < budget.deadline) }
        else { Issue.record("Tool deadline missing") }
        #expect(await XCTWaiter.fulfillment(of: [finished], timeout: 1) == .completed)
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        guard case .failure(let error) = await task.value else { Issue.record("Late authorization succeeded"); return }
        #expect(error as? AgentLoopError == .toolTimedOut(call.id))
        #expect(await log.names == ["authorize"])
        #expect(await provider.log.requests.count == 1)
    }
}

actor ManualGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { waiters.append(continuation) }
        }
    }
    func open() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

let blockingCall = ToolCall(id: .init(rawValue: "block"), name: "blocking", argumentsJSON: "{}", completeness: .complete)

struct BlockingTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "blocking"
    static let description = "Wait for a resource"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let gate: ManualGate
    let entered: XCTestExpectation
    let returned: XCTestExpectation
    let policy: ToolPolicy
    init(gate: ManualGate, entered: XCTestExpectation, returned: XCTestExpectation, timeout: Duration) throws {
        self.gate = gate
        self.entered = entered
        self.returned = returned
        policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe,
                                timeout: timeout, authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        defer { returned.fulfill() }
        entered.fulfill()
        await gate.wait()
        return ToolResult(output: "Late result")
    }
}

struct ApprovalTool: AgentTool {
    typealias Input = BlockingTool.Input
    typealias Output = String
    static let name = "approval"
    static let description = "Read an authorized resource"
    static let inputSchema = BlockingTool.inputSchema
    static let outputSchema = ToolSchema.string
    let gate: ManualGate
    let log: EffectLog
    let entered: XCTestExpectation
    let returned: XCTestExpectation
    let policy: ToolPolicy
    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        defer { returned.fulfill() }
        await log.record("authorize", context)
        entered.fulfill()
        await gate.wait()
        return .allowed
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record("execute", context)
        return ToolResult(output: "Ready")
    }
}
