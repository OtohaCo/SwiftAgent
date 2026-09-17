import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentReceiptTests {
    @Test func validatedReceiptIsObservableBeforeToolCompletionAndInRunResult() async throws {
        let log = EffectLog()
        let tool = try ReceiptProbe(log: log)
        let call = receiptCall()
        let provider = ScriptedProvider { request, turn in turn == 1 ? toolResponse(request, [call]) : textResponse(request, "Verified") }
        let run = try await Agent(model: fixtureModel, provider: provider, tools: [tool]).makeSession().run("read")
        let events = await collectEvents(run.events)
        let result = try await run.wait()
        let receipt = try #require(result.receipts.first)
        #expect(result.receipts.count == 1)
        #expect(receipt.callID == call.id)
        #expect(receipt.effect == .readOnly)
        #expect(receipt.receipt.operationID == (await log.contexts.first?.idempotencyKey))
        #expect(receipt.receipt.confirmedTargets == [.init(namespace: "resource", id: "r1")])
        let receiptIndex = try #require(events.firstIndex(of: .toolReceiptValidated(receipt)))
        let completionIndex = try #require(events.firstIndex { if case .toolCompleted = $0 { true } else { false } })
        #expect(receiptIndex < completionIndex)
    }

    @Test func claimedSuccessWithoutReceiptFailsWithoutSuccessEventsOrAnotherModelTurn() async throws {
        let provider = ScriptedProvider { request, _ in toolResponse(request, [receiptCall()]) }
        let tool = try ReceiptProbe(log: EffectLog(), returnsReceipt: false)
        let run = try await Agent(model: fixtureModel, provider: provider, tools: [tool]).makeSession().run("confirm")
        let events = await collectEvents(run.events)
        await #expect(throws: ToolReceiptError.missing) { try await run.wait() }
        #expect(events.last == .runFinished(.failed(.receipt(.missing))))
        #expect(!events.contains { if case .toolReceiptValidated = $0 { true } else { false } })
        #expect(!events.contains { if case .toolCompleted = $0 { true } else { false } })
        #expect(await provider.log.requests.count == 1)
    }

    @Test func invalidOutputAndUnavailableMutationCannotPublishReceiptSuccess() async throws {
        for mutation in [false, true] {
            let log = EffectLog()
            let tool = try ReceiptProbe(log: log, invalidOutput: !mutation, effect: mutation ? .mutation : .readOnly)
            let provider = ScriptedProvider { request, _ in toolResponse(request, [receiptCall()]) }
            let run = try await Agent(model: fixtureModel, provider: provider, tools: [tool]).makeSession().run("work")
            let events = await collectEvents(run.events)
            if mutation {
                await #expect(throws: ToolInvocationError.mutationIntegrityUnavailable) { try await run.wait() }
                #expect(events.last == .runFinished(.failed(.toolInvocation(.mutationIntegrityUnavailable))))
            } else {
                await #expect(throws: ToolRegistryError.self) { try await run.wait() }
                guard case .runFinished(.failed(.toolRegistry(.invalidOutput(let issue)))) = events.last else {
                    Issue.record("Wrong invalid-output failure"); continue
                }
                #expect(issue.path == "/status")
                #expect(issue.keyword == "type")
            }
            #expect(!events.contains { if case .toolReceiptValidated = $0 { true } else { false } })
            #expect(!events.contains { if case .toolCompleted = $0 { true } else { false } })
            #expect(await log.names.count == (mutation ? 0 : 1))
            #expect(await provider.log.requests.count == 1)
        }
    }

    @Test func modelTextClaimingAnEffectDoesNotCreateAReceipt() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "The document has been updated.") }
        let run = try await Agent(model: fixtureModel, provider: provider).makeSession().run("update")
        let events = await collectEvents(run.events)
        #expect(try await run.wait().receipts.isEmpty)
        #expect(!events.contains { if case .toolReceiptValidated = $0 { true } else { false } })
    }

    @Test func lateValidReceiptAfterTimeoutOrCancellationCannotBecomeSuccess() async throws {
        for cancel in [false, true] {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Receipt executor entered")
        let returned = XCTestExpectation(description: "Receipt executor returned")
        let base = try ReceiptProbe(log: EffectLog())
        let tool = try LateReceiptProbe(base: base, gate: gate, entered: entered, returned: returned,
                                       timeout: cancel ? .seconds(5) : .milliseconds(100))
        let provider = ScriptedProvider { request, _ in toolResponse(request, [receiptCall()]) }
        let run = try await Agent(model: fixtureModel, provider: provider, tools: [tool]).makeSession().run("read")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        if cancel {
            await run.cancel()
            await #expect(throws: CancellationError.self) { try await run.wait() }
        } else {
            await #expect(throws: AgentLoopError.toolTimedOut(receiptCall().id)) { try await run.wait() }
        }
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        let events = await collectEvents(run.events)
        #expect(!events.contains { if case .toolReceiptValidated = $0 { true } else { false } })
        #expect(!events.contains { if case .toolCompleted = $0 { true } else { false } })
        #expect(await provider.log.requests.count == 1)
        }
    }
}

func receiptCall() -> ToolCall {
    .init(id: .init(rawValue: "confirm-1"), name: ReceiptProbe.name, argumentsJSON: #"{"resource":"r1"}"#, completeness: .complete)
}

struct ReceiptProbe: AgentTool {
    struct Input: Codable, Sendable { let resource: String }
    typealias Output = JSONValue
    static let name = "confirm_read"
    static let description = "Read a resource with a receipt"
    static let inputSchema = ToolSchema.object(properties: ["resource": .string], required: ["resource"])
    static let outputSchema = ToolSchema.object(properties: ["status": .string], required: ["status"])
    let policy: ToolPolicy
    let log: EffectLog
    let returnsReceipt: Bool
    let invalidOutput: Bool
    init(log: EffectLog, returnsReceipt: Bool = true, invalidOutput: Bool = false, effect: ToolPolicy.Effect = .readOnly) throws {
        self.log = log; self.returnsReceipt = returnsReceipt; self.invalidOutput = invalidOutput
        policy = try ToolPolicy(effect: effect, execution: effect == .mutation ? .exclusive : .sequential,
                                idempotency: .requiresReceipt, timeout: .seconds(1), authorization: .notRequired)
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try ToolReceiptExpectation(targets: [.init(namespace: "resource", id: input.resource)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record(Self.name, context)
        let receipt: ToolReceipt? = returnsReceipt ? .init(operationID: context.idempotencyKey ?? "missing", status: .succeeded,
            confirmedTargets: [.init(namespace: "resource", id: input.resource)], revision: "v2") : nil
        return ToolResult(output: .object(["status": invalidOutput ? .number(1) : .string("succeeded")]), receipt: receipt)
    }
}

struct LateReceiptProbe: AgentTool {
    typealias Input = ReceiptProbe.Input
    typealias Output = ReceiptProbe.Output
    static let name = ReceiptProbe.name
    static let description = ReceiptProbe.description
    static let inputSchema = ReceiptProbe.inputSchema
    static let outputSchema = ReceiptProbe.outputSchema
    let base: ReceiptProbe
    let gate: ManualGate
    let entered: XCTestExpectation
    let returned: XCTestExpectation
    let policy: ToolPolicy
    init(base: ReceiptProbe, gate: ManualGate, entered: XCTestExpectation, returned: XCTestExpectation, timeout: Duration) throws {
        self.base = base; self.gate = gate; self.entered = entered; self.returned = returned
        policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .requiresReceipt,
                                timeout: timeout, authorization: .notRequired)
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try base.receiptExpectation(for: input) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        defer { returned.fulfill() }
        entered.fulfill()
        await gate.wait()
        return try await base.execute(input, context: context)
    }
}
