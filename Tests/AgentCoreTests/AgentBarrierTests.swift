import AgentCore
import AgentModels
import AgentTools
import Testing
import XCTest

struct AgentBarrierTests {
    @Test func sequentialAndExclusiveCallsSeparateParallelGroups() async throws {
        let parallel = XCTestExpectation(description: "Parallel group entered")
        parallel.expectedFulfillmentCount = 2
        let sequential = XCTestExpectation(description: "Sequential entered")
        let exclusive = XCTestExpectation(description: "Exclusive entered")
        let pGate = ManualGate(), sGate = ManualGate(), eGate = ManualGate()
        defer { Task { await pGate.open(); await sGate.open(); await eGate.open() } }
        let probe = BarrierProbe(parallel: parallel, sequential: sequential, exclusive: exclusive,
                                 pGate: pGate, sGate: sGate, eGate: eGate)
        let definitions = [("p1", ParallelKind.name), ("p2", ParallelKind.name), ("s", SequentialKind.name),
                           ("e", ExclusiveKind.name), ("p3", ParallelKind.name)]
        let calls = definitions.map { ToolCall(id: .init(rawValue: $0.0), name: $0.1, argumentsJSON: "{\"label\":\"\($0.0)\"}", completeness: .complete) }
        let provider = ScriptedProvider { request, turn in turn == 1 ? toolResponse(request, calls) : textResponse(request, "Done") }
        let run = try await Agent(model: fixtureModel, provider: provider, tools: [
            BarrierTool<ParallelKind>(probe: probe), BarrierTool<SequentialKind>(probe: probe), BarrierTool<ExclusiveKind>(probe: probe),
        ]).makeSession().run("Read in phases")
        #expect(await XCTWaiter.fulfillment(of: [parallel], timeout: 1) == .completed)
        #expect(await probe.active == Set(["p1", "p2"]))
        await pGate.open()
        #expect(await XCTWaiter.fulfillment(of: [sequential], timeout: 1) == .completed)
        #expect(await probe.active == Set(["s"]))
        await sGate.open()
        #expect(await XCTWaiter.fulfillment(of: [exclusive], timeout: 1) == .completed)
        #expect(await probe.active == Set(["e"]))
        await eGate.open()
        let result = try await run.wait()
        #expect(result.history.compactMap { if case .tool(let value) = $0 { value.callID } else { nil } } == calls.map(\.id))
        #expect(await probe.barrierOverlaps.isEmpty)
    }
}

private actor BarrierProbe {
    private(set) var active = Set<String>()
    private(set) var barrierOverlaps: [String] = []
    let parallel: XCTestExpectation, sequential: XCTestExpectation, exclusive: XCTestExpectation
    let pGate: ManualGate, sGate: ManualGate, eGate: ManualGate
    init(parallel: XCTestExpectation, sequential: XCTestExpectation, exclusive: XCTestExpectation,
         pGate: ManualGate, sGate: ManualGate, eGate: ManualGate) {
        self.parallel = parallel; self.sequential = sequential; self.exclusive = exclusive
        self.pGate = pGate; self.sGate = sGate; self.eGate = eGate
    }
    func execute(_ label: String) async -> String {
        if ["s", "e", "p3"].contains(label), !active.isEmpty { barrierOverlaps.append(label) }
        active.insert(label)
        switch label {
        case "p1", "p2": parallel.fulfill(); await pGate.wait()
        case "s": sequential.fulfill(); await sGate.wait()
        case "e": exclusive.fulfill(); await eGate.wait()
        default: break
        }
        active.remove(label)
        return label
    }
}

private protocol BarrierKind: Sendable { static var name: String { get }; static var execution: ToolPolicy.Execution { get } }
private enum ParallelKind: BarrierKind { static let name = "parallel"; static let execution = ToolPolicy.Execution.parallel }
private enum SequentialKind: BarrierKind { static let name = "sequential"; static let execution = ToolPolicy.Execution.sequential }
private enum ExclusiveKind: BarrierKind { static let name = "exclusive"; static let execution = ToolPolicy.Execution.exclusive }
private struct BarrierInput: Codable, Sendable { let label: String }
private struct BarrierTool<Kind: BarrierKind>: AgentTool {
    typealias Input = BarrierInput
    typealias Output = String
    static var name: String { Kind.name }
    static var description: String { "Read a resource" }
    static var inputSchema: ToolSchema { .object(properties: ["label": .string], required: ["label"]) }
    static var outputSchema: ToolSchema { .string }
    let policy: ToolPolicy
    let probe: BarrierProbe
    init(probe: BarrierProbe) throws {
        self.probe = probe
        policy = try .init(effect: .readOnly, execution: Kind.execution, idempotency: .safe, timeout: .seconds(3), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> { .init(output: await probe.execute(input.label)) }
}
