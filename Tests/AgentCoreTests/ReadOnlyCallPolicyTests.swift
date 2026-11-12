import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest
@testable import AgentCore

/// A mutation tool may say, for one input, that the call only observes (`AgentTool.readOnlyPolicy(for:)`): such calls
/// run as reads, beside neighbouring parallel reads and without a mutation intent, while its other calls stay exclusive.
@Suite(.manualClock) struct ReadOnlyCallPolicyTests {
    @Test func callsThatOnlyObserveRunTogetherAndChangesStayExclusive() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swift-agent-read-policy-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + ".lock") }
        let together = XCTestExpectation(description: "Both observing calls entered")
        together.expectedFulfillmentCount = 2
        let changing = XCTestExpectation(description: "The change entered")
        let readsGate = ManualGate(), changeGate = ManualGate()
        defer { Task { await readsGate.open(); await changeGate.open() } }
        let probe = ShellProbe(together: together, changing: changing, readsGate: readsGate, changeGate: changeGate)
        let labels = [("r1", true), ("r2", true), ("w", false), ("r3", true)]
        let calls = labels.map {
            ToolCall(id: .init(rawValue: $0.0), name: ShellTool.name, argumentsJSON: #"{"label":"\#($0.0)","reads":\#($0.1)}"#, completeness: .complete)
        }
        let provider = ScriptedProvider { request, turn in turn == 1 ? toolResponse(request, calls) : textResponse(request, "Done") }
        let journal = try makeTestJournal(at: url)
        let run = try await Agent(model: fixtureModel, provider: provider, tools: [try ShellTool(probe: probe)])
            .makeSession(journal: journal).run("Look, then change")
        #expect(await XCTWaiter.fulfillment(of: [together], timeout: 60) == .completed)
        #expect(await probe.active == ["r1", "r2"])
        await readsGate.open()
        #expect(await XCTWaiter.fulfillment(of: [changing], timeout: 60) == .completed)
        #expect(await probe.active == ["w"])
        await changeGate.open()
        let result = try await run.wait()
        try await run.waitForDrain()
        #expect(result.history.compactMap { if case .tool(let value) = $0 { value.callID } else { nil } } == calls.map(\.id))
        #expect(await probe.overlapsWithChange.isEmpty)
        #expect(result.receipts.map(\.callID.rawValue) == ["w"])
        #expect(result.receipts.map(\.effect) == [.mutation])
        #expect(try await journal.pendingMutations().isEmpty)
        #expect(await probe.effects == ["r1": .readOnly, "r2": .readOnly, "w": .mutation, "r3": .readOnly], "the tool is told how each call runs")
    }

    @Test func aPolicyThatIsNotReadOnlyFailsThePreparation() throws {
        let registry = try ToolRegistry(tools: [AnyAgentTool(try NarrowingTool(narrowed: try .mutation(evidence: .none)))])
        let call = ToolCall(id: .init(rawValue: "c"), name: NarrowingTool.name, argumentsJSON: "{}", completeness: .complete)
        #expect(throws: ToolInvocationError.invalidDefinition) {
            try registry.prepare(call, context: ToolContext(sessionID: UUID(), runID: UUID(), callID: call.id,
                deadline: AgentClock.now.advanced(by: .seconds(5))))
        }
        let reads = try ToolRegistry(tools: [AnyAgentTool(try NarrowingTool(narrowed: try .readOnly(authorization: .notRequired)))])
        let prepared = try reads.prepare(call, context: ToolContext(sessionID: UUID(), runID: UUID(), callID: call.id,
            deadline: AgentClock.now.advanced(by: .seconds(5))))
        #expect(prepared.policy.effect == .readOnly && prepared.policy.execution == .parallel)
        // A change that proves its refusals had no effect can still run a call that only observes as a read.
        let proving = try ToolRegistry(tools: [AnyAgentTool(try NarrowingTool(narrowed: try .readOnly(authorization: .notRequired),
            declared: try .mutation(evidence: .none, recoverableErrors: .confirmedNoEffect)))])
        let narrowed = try proving.prepare(call, context: ToolContext(sessionID: UUID(), runID: UUID(), callID: call.id,
            deadline: AgentClock.now.advanced(by: .seconds(5))))
        #expect(narrowed.policy.effect == .readOnly && narrowed.policy.recoverableErrors == .failClosed)
    }
}

private actor ShellProbe {
    private(set) var active = Set<String>()
    private(set) var overlapsWithChange: [String] = []
    private(set) var effects: [String: ToolPolicy.Effect] = [:]
    let together: XCTestExpectation, changing: XCTestExpectation
    let readsGate: ManualGate, changeGate: ManualGate
    init(together: XCTestExpectation, changing: XCTestExpectation, readsGate: ManualGate, changeGate: ManualGate) {
        self.together = together; self.changing = changing; self.readsGate = readsGate; self.changeGate = changeGate
    }
    func execute(_ label: String, effect: ToolPolicy.Effect?) async {
        effects[label] = effect
        if label == "w" || label == "r3", !active.isEmpty { overlapsWithChange.append(label) }
        active.insert(label)
        switch label {
        case "r1", "r2": together.fulfill(); await readsGate.wait()
        case "w": changing.fulfill(); await changeGate.wait()
        default: break
        }
        active.remove(label)
    }
}

private struct ShellTool: AgentTool {
    struct Input: Codable, Sendable { let label: String; let reads: Bool }
    typealias Output = String
    static let name = "shell"
    static let description = "Run a command"
    static let inputSchema = ToolSchema.object(properties: ["label": .string, "reads": .boolean], required: ["label", "reads"])
    static let outputSchema = ToolSchema.string
    let policy: ToolPolicy
    let probe: ShellProbe
    init(probe: ShellProbe) throws {
        self.probe = probe
        policy = try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
                                timeout: .seconds(3), authorization: .notRequired)
    }
    func readOnlyPolicy(for input: Input) throws -> ToolPolicy? {
        input.reads ? try .readOnly(timeout: .seconds(3), authorization: .notRequired) : nil
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "workspace", id: "project"))] }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        input.reads ? nil : try .init(targets: [.init(namespace: "workspace", id: "project")], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        await probe.execute(input.label, effect: context.effect)
        // A read returns no receipt: settled as a mutation, it would fail.
        guard !input.reads else { return .init(output: input.label) }
        return .init(output: input.label, receipt: ToolReceipt(operationID: context.idempotencyKey ?? "missing", status: .succeeded,
            confirmedTargets: [.init(namespace: "workspace", id: "project")], revision: "after"))
    }
}

private struct NarrowingTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "narrowing"
    static let description = "Narrows its policy"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let policy: ToolPolicy
    let narrowed: ToolPolicy
    init(narrowed: ToolPolicy, declared: ToolPolicy? = nil) throws {
        self.narrowed = narrowed
        policy = try declared ?? .mutation(evidence: .none)
    }
    func readOnlyPolicy(for input: Input) throws -> ToolPolicy? { narrowed }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> { .init(output: "") }
}
