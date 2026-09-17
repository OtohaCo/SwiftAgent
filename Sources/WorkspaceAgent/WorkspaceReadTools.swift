import AgentModels
import AgentTools
import Foundation

struct WorkspaceListFilesTool: AgentTool {
    struct Input: Codable, Sendable { var path: String? }
    struct ListedFile: Codable, Sendable { let path: String; let hash: String }
    struct Output: Codable, Sendable { let directory: String; let files: [ListedFile] }

    static let name = "list_files"
    static let description = "List files inside the sandbox workspace."
    static let inputSchema = ToolSchema.object(properties: ["path": .string])
    static let outputSchema = ToolSchema.object(
        properties: [
            "directory": .string,
            "files": .array(items: .object(properties: ["path": .string, "hash": .string], required: ["path", "hash"])),
        ],
        required: ["directory", "files"]
    )

    let store: WorkspaceFileStore
    let policy: ToolPolicy

    init(store: WorkspaceFileStore) throws {
        self.store = store
        policy = try ToolPolicy(
            effect: .readOnly, execution: .parallel, idempotency: .safe,
            timeout: .seconds(5), authorization: .required
        )
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(WorkspaceEvidence.directoryReference(try WorkspacePath.parse(input.path ?? ".", root: store.root)))]
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        _ = try WorkspacePath.parse(input.path ?? ".", root: store.root)
        return .allowed
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let listed = try await store.list(directory: input.path ?? ".")
        let issuedAt = Date()
        var evidence = [WorkspaceEvidence.directory(listed.directory, hash: listed.listingHash, issuedAt: issuedAt)]
        evidence += listed.files.map { WorkspaceEvidence.file($0.path, hash: $0.hash, issuedAt: issuedAt) }
        return ToolResult(
            output: Output(
                directory: listed.directory.relativePath,
                files: listed.files.map { .init(path: $0.path.relativePath, hash: $0.hash) }
            ),
            evidence: evidence
        )
    }
}

struct WorkspaceReadFileTool: AgentTool {
    struct Input: Codable, Sendable { let path: String }
    struct Output: Codable, Sendable { let path: String; let content: String; let hash: String }

    static let name = "read_file"
    static let description = "Read one sandbox file and return its content hash."
    static let inputSchema = ToolSchema.object(properties: ["path": .string], required: ["path"])
    static let outputSchema = ToolSchema.object(
        properties: ["path": .string, "content": .string, "hash": .string],
        required: ["path", "content", "hash"]
    )

    let store: WorkspaceFileStore
    let policy: ToolPolicy

    init(store: WorkspaceFileStore) throws {
        self.store = store
        policy = try ToolPolicy(
            effect: .readOnly, execution: .parallel, idempotency: .safe,
            timeout: .seconds(5), authorization: .required
        )
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(WorkspaceEvidence.fileReference(try WorkspacePath.parse(input.path, root: store.root)))]
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        _ = try WorkspacePath.parse(input.path, root: store.root)
        return .allowed
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let result = try await store.read(input.path)
        return ToolResult(
            output: Output(path: result.file.path.relativePath, content: result.content, hash: result.file.hash),
            evidence: [WorkspaceEvidence.file(result.file.path, hash: result.file.hash, issuedAt: Date())]
        )
    }
}

struct WorkspaceSearchFilesTool: AgentTool {
    struct Input: Codable, Sendable { let query: String; var path: String? }
    struct Match: Codable, Sendable { let path: String; let kind: String }
    struct Output: Codable, Sendable { let matches: [Match] }

    static let name = "search_files"
    static let description = "Search sandbox file names and text content."
    static let inputSchema = ToolSchema.object(properties: ["query": .string, "path": .string], required: ["query"])
    static let outputSchema = ToolSchema.object(
        properties: [
            "matches": .array(items: .object(properties: ["path": .string, "kind": .string], required: ["path", "kind"])),
        ],
        required: ["matches"]
    )

    let store: WorkspaceFileStore
    let policy: ToolPolicy

    init(store: WorkspaceFileStore) throws {
        self.store = store
        policy = try ToolPolicy(
            effect: .readOnly, execution: .parallel, idempotency: .safe,
            timeout: .seconds(5), authorization: .required
        )
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(WorkspaceEvidence.directoryReference(try WorkspacePath.parse(input.path ?? ".", root: store.root)))]
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        _ = try WorkspacePath.parse(input.path ?? ".", root: store.root)
        return .allowed
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let matches = try await store.search(query: input.query, directory: input.path ?? ".")
        return ToolResult(
            output: Output(matches: matches.map { .init(path: $0.path.relativePath, kind: $0.kind.rawValue) })
        )
    }
}
