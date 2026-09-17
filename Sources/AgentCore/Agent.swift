import AgentModels
import AgentTools

public struct Agent: Sendable {
    private let loop: AgentLoop
    private let instructions: String
    private let structuredOutput: StructuredOutputSchema?
    private let maxModelTurns: Int
    private let maxToolCalls: Int
    private let runTimeout: Duration

    public init(
        model: ModelID, provider: any ModelProvider, tools: [any AgentTool] = [], instructions: String = "",
        structuredOutput: StructuredOutputSchema? = nil,
        maxModelTurns: Int = 8, maxToolCalls: Int = 16, runTimeout: Duration = .seconds(30),
        scheduler: ToolScheduler = .init()
    ) throws {
        guard runTimeout > .zero else { throw AgentLoopError.invalidBudget }
        _ = try AgentBudget(maxModelTurns: maxModelTurns, maxToolCalls: maxToolCalls, deadline: .now)
        loop = AgentLoop(model: model, provider: provider, tools: try ToolRegistry(tools: tools.map { try AnyAgentTool($0) }), scheduler: scheduler)
        self.instructions = instructions
        self.structuredOutput = structuredOutput
        self.maxModelTurns = maxModelTurns
        self.maxToolCalls = maxToolCalls
        self.runTimeout = runTimeout
    }

    public func makeSession() -> AgentSession {
        AgentSession(loop: loop, instructions: instructions, structuredOutput: structuredOutput, maxModelTurns: maxModelTurns,
                     maxToolCalls: maxToolCalls, runTimeout: runTimeout)
    }
}
