import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest
@testable import AgentAppleProvider

struct AppleExecutionBoundaryTests {
    @Test func coreAloneExecutesAndFeedsTheResultIntoTheNextModelTurn() async throws {
        let probe = BoundaryProbe()
        let provider = AppleFoundationProvider { request in
            await probe.request(request)
            if request.messages.contains(where: { $0.role == .tool }) {
                return .init(kind: .answer, text: "Verified", toolCalls: [])
            }
            return .init(kind: .tools, text: "", toolCalls: [.init(name: BoundaryTool.name, argumentsJSON: "{}")])
        }
        let result = try await Agent(model: AppleFoundationProvider.modelID, provider: provider,
                                     tools: [BoundaryTool(probe: probe)]).makeSession().run("Read").wait()
        #expect(result.modelTurns == 2)
        #expect(await probe.executions == 1)
        let requests = await probe.requests
        #expect(requests.count == 2)
        #expect(requests.last?.messages.contains { if case .tool(let output) = $0 { output.content == [.json(.string("Observed"))] } else { false } } == true)
    }

    @Test func modelProposalCannotBypassClosedMutationAdmission() async throws {
        let probe = BoundaryProbe()
        let provider = AppleFoundationProvider { request in
            await probe.request(request)
            return .init(kind: .tools, text: "", toolCalls: [.init(name: BoundaryTool.name, argumentsJSON: "{}")])
        }
        let agent = try Agent(model: AppleFoundationProvider.modelID, provider: provider,
                               tools: [BoundaryTool(probe: probe, effect: .mutation)])
        #expect(throws: AgentSessionError.durableJournalRequired) { try agent.makeSession() }
        #expect(await probe.executions == 0)
        #expect(await probe.requests.isEmpty)
    }

    @Test func cancelledNativeWorkCannotPublishALateToolPlan() async throws {
        let entered = XCTestExpectation(description: "Native generation entered")
        let returned = XCTestExpectation(description: "Native generation returned")
        let cancelled = XCTestExpectation(description: "Cancellation reached generation")
        let gate = BoundaryGate(), probe = BoundaryProbe()
        let provider = AppleFoundationProvider { request in
            await probe.request(request)
            entered.fulfill()
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: { cancelled.fulfill() }
            returned.fulfill()
            return .init(kind: .tools, text: "", toolCalls: [.init(name: BoundaryTool.name, argumentsJSON: "{}")])
        }
        let run = try await Agent(model: AppleFoundationProvider.modelID, provider: provider,
                                  tools: [BoundaryTool(probe: probe)]).makeSession().run("Read")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed)
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        #expect(await XCTWaiter.fulfillment(of: [cancelled], timeout: 2) == .completed)
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 2) == .completed)
        #expect(await probe.executions == 0)
        var completedCalls = 0
        for await event in run.events { if case .model(.toolCallCompleted) = event { completedCalls += 1 } }
        #expect(completedCalls == 0)
    }
}

private actor BoundaryProbe {
    private(set) var requests: [ModelRequest] = []
    private(set) var executions = 0
    func request(_ value: ModelRequest) { requests.append(value) }
    func execute() { executions += 1 }
}

private actor BoundaryGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !isOpen { await withCheckedContinuation { waiters.append($0) } } }
    func open() { isOpen = true; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}

private struct BoundaryTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "read_resource"
    static let description = "Read a generic resource"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let policy: ToolPolicy
    let probe: BoundaryProbe
    init(probe: BoundaryProbe, effect: ToolPolicy.Effect = .readOnly) throws {
        self.probe = probe
        policy = try .init(effect: effect, execution: .exclusive, idempotency: .safe, timeout: .seconds(2), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        await probe.execute()
        return .init(output: "Observed")
    }
}
