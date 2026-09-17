import AgentCore
import AgentModels
import AgentProviders
import AgentTools
import Foundation

public struct WorkspaceAgentHost: Sendable {
    public static let defaultInstructions = """
    You are a workspace file agent. Stay inside the sandbox. Use list_files, read_file and search_files to observe files. \
    Before changing an existing file, read it and pass that exact content hash as expectedHash. \
    Creating a file requires a current listing of its parent directory. \
    After write_file or move_file, only tell the user the change succeeded when a tool receipt confirmed it.
    """

    public let store: WorkspaceFileStore
    public let scheduler: ToolScheduler
    public let journal: AgentJournal
    private let agent: Agent

    public init(
        store: WorkspaceFileStore,
        provider: any ModelProvider,
        model: ModelID,
        journal: AgentJournal,
        scheduler: ToolScheduler = ToolScheduler(),
        instructions: String = defaultInstructions,
        tools: [any AgentTool]? = nil
    ) throws {
        self.store = store
        self.scheduler = scheduler
        self.journal = journal
        agent = try Agent(
            model: model,
            provider: provider,
            tools: tools ?? Self.makeTools(store: store),
            instructions: instructions,
            scheduler: scheduler
        )
    }

    public init(
        root: URL,
        provider: any ModelProvider,
        model: ModelID,
        journal: AgentJournal,
        scheduler: ToolScheduler = ToolScheduler(),
        instructions: String = defaultInstructions
    ) throws {
        try self.init(
            store: WorkspaceFileStore(root: root),
            provider: provider,
            model: model,
            journal: journal,
            scheduler: scheduler,
            instructions: instructions
        )
    }

    public static func makeTools(store: WorkspaceFileStore) throws -> [any AgentTool] {
        [
            try WorkspaceListFilesTool(store: store),
            try WorkspaceReadFileTool(store: store),
            try WorkspaceSearchFilesTool(store: store),
            try WorkspaceWriteFileTool(store: store),
            try WorkspaceMoveFileTool(store: store),
        ]
    }

    public static func anthropic(
        root: URL,
        apiKey: String,
        model: String = "claude-sonnet-4-6",
        journal: AgentJournal,
        scheduler: ToolScheduler = ToolScheduler()
    ) throws -> WorkspaceAgentHost {
        try WorkspaceAgentHost(
            root: root,
            provider: AnthropicProvider(apiKey: apiKey),
            model: ModelID(provider: "anthropic", name: model),
            journal: journal,
            scheduler: scheduler
        )
    }

    public func makeSession(id: UUID = UUID()) throws -> AgentSession {
        try agent.makeSession(id: id, journal: journal)
    }
}
