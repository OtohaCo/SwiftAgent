import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentEvidenceTests {
    @Test func sessionRetainsEvidenceAcrossRunsAndOtherSessionsCannotReuseIt() async throws {
        let provider = ScriptedProvider { request, _ in
            if case .tool = request.messages.last { return textResponse(request, "Done") }
            let query = request.messages.last
            let name = query == .user([.text("discover")]) ? "discover_resource" : "use_resource"
            return toolResponse(request, [.init(id: .init(rawValue: name), name: name, argumentsJSON: "{}", completeness: .complete)])
        }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [ResourceDiscovery(), ResourceUse(scope: .sameSession)])
        let session = try agent.makeSession()
        _ = try await session.run("discover").wait()
        #expect(try await session.run("use").wait().outcome == .completed)
        let other = try agent.makeSession()
        await #expect(throws: EvidenceError.self) { try await other.run("use").wait() }
    }

    @Test func sameRunRequirementRejectsEarlierRunsButWorksWithinAToolBatch() async throws {
        let provider = ScriptedProvider { request, _ in
            if case .tool = request.messages.last { return textResponse(request, "Done") }
            if request.messages.last == .user([.text("both")]) {
                return toolResponse(request, [
                    .init(id: .init(rawValue: "discover"), name: "discover_resource", argumentsJSON: "{}", completeness: .complete),
                    .init(id: .init(rawValue: "use"), name: "use_resource", argumentsJSON: "{}", completeness: .complete),
                ])
            }
            return toolResponse(request, [.init(id: .init(rawValue: "later"), name: "use_resource", argumentsJSON: "{}", completeness: .complete)])
        }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [ResourceDiscovery(), ResourceUse(scope: .sameRun)])
        let session = try agent.makeSession()
        #expect(try await session.run("both").wait().toolCalls == 2)
        await #expect(throws: EvidenceError.self) { try await session.run("later").wait() }
    }

    @Test func rawLoopHistoryDoesNotRecreateTrustedEvidence() async throws {
        let provider = ScriptedProvider { request, turn in
            if case .tool = request.messages.last { return textResponse(request, "Done") }
            let name = request.messages.last == .user([.text("discover")]) ? "discover_resource" : "use_resource"
            return toolResponse(request, [.init(id: .init(rawValue: "call-\(turn)"), name: name, argumentsJSON: "{}", completeness: .complete)])
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(ResourceDiscovery()), AnyAgentTool(ResourceUse(scope: .sameSession))]))
        let sessionID = UUID()
        let first = try await loop.run(messages: [.user([.text("discover")])], sessionID: sessionID, budget: testBudget())
        await #expect(throws: EvidenceError.self) {
            try await loop.run(messages: first.history + [.user([.text("use")])], sessionID: sessionID, budget: testBudget())
        }
    }

    @Test func lateTimedOutResultCannotPublishEvidenceIntoFollowingRun() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Discovery entered")
        let returned = XCTestExpectation(description: "Discovery returned")
        let provider = ScriptedProvider { request, turn in
            if case .tool = request.messages.last { return textResponse(request, "Done") }
            let name = request.messages.last == .user([.text("discover")]) ? "late_discovery" : "use_resource"
            return toolResponse(request, [.init(id: .init(rawValue: "call-\(turn)"), name: name, argumentsJSON: "{}", completeness: .complete)])
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [
            LateEvidenceTool(gate: gate, entered: entered, returned: returned), ResourceUse(scope: .sameSession),
        ]).makeSession()
        let first = try await session.run("discover")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        await #expect(throws: AgentLoopError.toolTimedOut(.init(rawValue: "call-1"))) { try await first.wait() }
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        await #expect(throws: EvidenceError.self) { try await session.run("use").wait() }
    }
}

struct ResourceDiscovery: AgentTool {
    typealias Input = BlockingTool.Input
    typealias Output = String
    static let name = "discover_resource"
    static let description = "Discover a resource"
    static let inputSchema = BlockingTool.inputSchema
    static let outputSchema = ToolSchema.string
    let policy: ToolPolicy
    init() throws { policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1), authorization: .notRequired) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        ToolResult(output: "resource-1", evidence: [.init(namespace: "resource", id: "1", issuedAt: Date())])
    }
}

struct ResourceUse: AgentTool {
    typealias Input = BlockingTool.Input
    typealias Output = String
    static let name = "use_resource"
    static let description = "Read a verified resource"
    static let inputSchema = BlockingTool.inputSchema
    static let outputSchema = ToolSchema.string
    let policy: ToolPolicy
    let scope: EvidenceScope
    init(scope: EvidenceScope) throws {
        self.scope = scope
        policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe,
                                timeout: .seconds(1), authorization: .notRequired, evidence: .required)
    }
    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        [.init(reference: .init(namespace: "resource", id: "1"), scope: scope)]
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> { ToolResult(output: "Verified") }
}

struct LateEvidenceTool: AgentTool {
    typealias Input = BlockingTool.Input
    typealias Output = String
    static let name = "late_discovery"
    static let description = "Discover a delayed resource"
    static let inputSchema = BlockingTool.inputSchema
    static let outputSchema = ToolSchema.string
    let gate: ManualGate
    let entered: XCTestExpectation
    let returned: XCTestExpectation
    let policy: ToolPolicy
    init(gate: ManualGate, entered: XCTestExpectation, returned: XCTestExpectation) throws {
        self.gate = gate; self.entered = entered; self.returned = returned
        policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe, timeout: .milliseconds(100), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        defer { returned.fulfill() }
        entered.fulfill()
        await gate.wait()
        return ToolResult(output: "resource-1", evidence: [.init(namespace: "resource", id: "1", issuedAt: Date())])
    }
}
