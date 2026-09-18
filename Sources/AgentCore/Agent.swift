import AgentModels
import Foundation
import AgentTools

/// Long-lived defaults for every Session created from an Agent.
///
/// `scheduler` is a resource coordinator, not a per-session queue. Share one
/// scheduler across every Session that can touch the same real resources.
public struct AgentConfiguration: Sendable {
    public var instructions: String
    public var structuredOutput: StructuredOutputSchema?
    public var maxModelTurns: Int
    public var maxToolCalls: Int
    public var runTimeout: Duration
    public var scheduler: ToolScheduler

    public init(
        instructions: String = "",
        structuredOutput: StructuredOutputSchema? = nil,
        maxModelTurns: Int = 8,
        maxToolCalls: Int = 16,
        runTimeout: Duration = .seconds(30),
        scheduler: ToolScheduler = .init()
    ) {
        self.instructions = instructions
        self.structuredOutput = structuredOutput
        self.maxModelTurns = maxModelTurns
        self.maxToolCalls = maxToolCalls
        self.runTimeout = runTimeout
        self.scheduler = scheduler
    }
}

/// Sendable factory for isolated Sessions. An Agent holds configuration only;
/// it never owns conversation history or an in-flight Run.
///
/// Replace `provider` without changing tools. When any registered tool is a
/// mutation, every Session must receive a journal whose `storage` is
/// `.durable`. Read-only Agents may omit a journal or use memory storage.
public struct Agent: Sendable {
    private let loop: AgentLoop
    private let configuration: AgentConfiguration
    private let requiresDurableJournal: Bool

    public init(
        model: ModelID,
        provider: any ModelProvider,
        tools: [any AgentTool] = [],
        configuration: AgentConfiguration = .init()
    ) throws {
        guard configuration.runTimeout > .zero else { throw AgentLoopError.invalidBudget }
        _ = try AgentBudget(
            maxModelTurns: configuration.maxModelTurns,
            maxToolCalls: configuration.maxToolCalls,
            deadline: .now
        )
        loop = AgentLoop(
            model: model,
            provider: provider,
            tools: try ToolRegistry(tools: tools.map { try AnyAgentTool($0) }),
            scheduler: configuration.scheduler
        )
        self.configuration = configuration
        requiresDurableJournal = tools.contains { $0.policy.effect == .mutation }
    }

    /// Convenience for the common instructions-only case. Limits, structured
    /// output, and the shared scheduler belong on `AgentConfiguration`.
    public init(
        model: ModelID,
        provider: any ModelProvider,
        tools: [any AgentTool] = [],
        instructions: String
    ) throws {
        try self.init(
            model: model,
            provider: provider,
            tools: tools,
            configuration: AgentConfiguration(instructions: instructions)
        )
    }

    /// Creates an isolated Session. Mutation tools require a durable journal;
    /// `nil` and memory-only journals fail here instead of during execution.
    public func makeSession(id: UUID = UUID(), journal: AgentJournal? = nil) throws -> AgentSession {
        if requiresDurableJournal, journal?.storage != .durable {
            throw AgentSessionError.durableJournalRequired
        }
        return AgentSession(
            id: id, loop: loop, instructions: configuration.instructions,
            structuredOutput: configuration.structuredOutput, maxModelTurns: configuration.maxModelTurns,
            maxToolCalls: configuration.maxToolCalls, runTimeout: configuration.runTimeout, journal: journal
        )
    }
}
