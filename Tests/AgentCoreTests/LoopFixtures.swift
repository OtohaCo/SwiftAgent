import AgentCore
import AgentModels
import AgentTools
import Foundation

let fixtureModel = ModelID(provider: "fixture", name: "test")

func testBudget(turns: Int = 4, calls: Int = 8) throws -> AgentBudget {
    try AgentBudget(maxModelTurns: turns, maxToolCalls: calls, deadline: .now.advanced(by: .seconds(10)))
}

actor RequestLog {
    private(set) var requests: [ModelRequest] = []
    func record(_ request: ModelRequest) -> Int {
        requests.append(request)
        return requests.count
    }
}

struct ScriptedProvider: ModelProvider {
    var descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.streaming, .multiTurn, .tools, .structuredOutput])
    let log = RequestLog()
    let respond: @Sendable (ModelRequest, Int) async throws -> [ModelEvent]

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let turn = await log.record(request)
            for event in try await respond(request, turn) { try emit(event) }
        }
    }
}

func textResponse(_ request: ModelRequest, _ text: String, stop: StopReason = .endTurn) -> [ModelEvent] {
    let info = ResponseInfo(id: "response", model: request.model)
    return [.responseStarted(info), .textDelta(text), .responseCompleted(.init(info: info, content: [.text(text)], stopReason: stop))]
}

func toolResponse(_ request: ModelRequest, _ calls: [ToolCall], stop: StopReason = .toolCalls) -> [ModelEvent] {
    let info = ResponseInfo(id: "response", model: request.model)
    var events: [ModelEvent] = [.responseStarted(info)]
    for call in calls {
        events.append(.toolCallStarted(call.id, name: call.name))
        events.append(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
        if call.completeness == .complete { events.append(.toolCallCompleted(call)) }
    }
    events.append(.responseCompleted(.init(info: info, toolCalls: calls, stopReason: stop)))
    return events
}

actor EffectLog {
    private(set) var names: [String] = []
    private(set) var contexts: [ToolContext] = []
    func record(_ name: String, _ context: ToolContext) {
        names.append(name)
        contexts.append(context)
    }
}

struct AddTool: AgentTool {
    struct Input: Codable, Sendable { let lhs: Int; let rhs: Int }
    struct Output: Codable, Sendable { let sum: Int }
    static let name = "add"
    static let description = "Add two integers"
    static let inputSchema = ToolSchema.object(properties: ["lhs": .integer, "rhs": .integer], required: ["lhs", "rhs"])
    static let outputSchema = ToolSchema.object(properties: ["sum": .integer], required: ["sum"])
    let log: EffectLog
    let policy: ToolPolicy
    init(log: EffectLog) throws {
        self.log = log
        policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                timeout: .seconds(2), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record(Self.name, context)
        let (sum, overflow) = input.lhs.addingReportingOverflow(input.rhs)
        guard !overflow else { throw FixtureError.invalidOperation }
        return ToolResult(output: Output(sum: sum))
    }
}

struct LookupTool: AgentTool {
    struct Input: Codable, Sendable { let query: String }
    struct Output: Codable, Sendable { let references: [String] }
    static let name = "search"
    static let description = "Search resources"
    static let inputSchema = ToolSchema.object(properties: ["query": .string], required: ["query"])
    static let outputSchema = ToolSchema.object(properties: ["references": .array(items: .string)], required: ["references"])
    let log: EffectLog
    let policy: ToolPolicy
    init(log: EffectLog) throws {
        self.log = log
        policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                timeout: .seconds(2), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record(Self.name, context)
        return ToolResult(output: Output(references: [input.query]))
    }
}

enum FixtureError: Error { case invalidOperation }
