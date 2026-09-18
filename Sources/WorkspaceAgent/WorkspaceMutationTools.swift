import AgentModels
import AgentTools
import Foundation

struct WorkspaceWriteFileTool: AgentTool {
    struct Input: Codable, Sendable {
        let path: String
        let content: String
        var expectedHash: String?
    }
    struct Output: Codable, Sendable { let path: String; let hash: String; let created: Bool }

    static let name = "write_file"
    static let description = "Create or replace a sandbox file. Existing files require the observed content hash."
    static let inputSchema = ToolSchema.object(
        properties: ["path": .string, "content": .string, "expectedHash": .string],
        required: ["path", "content"]
    )
    static let outputSchema = ToolSchema.object(
        properties: ["path": .string, "hash": .string, "created": .boolean],
        required: ["path", "hash", "created"]
    )

    let store: WorkspaceFileStore
    let policy: ToolPolicy
    private let receiptTransform: (@Sendable (ToolReceipt) -> ToolReceipt)?

    init(store: WorkspaceFileStore, receiptTransform: (@Sendable (ToolReceipt) -> ToolReceipt)? = nil) throws {
        self.store = store
        self.receiptTransform = receiptTransform
        policy = try ToolPolicy(
            effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
            timeout: .seconds(5), authorization: .required, evidence: .required
        )
    }

    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        let path = try WorkspacePath.parse(input.path, root: store.root)
        if let expectedHash = input.expectedHash {
            return [WorkspaceEvidence.fileRequirement(path, hash: expectedHash)]
        }
        return [WorkspaceEvidence.directoryRequirement(try WorkspacePath.parse(path.parentRelativePath, root: store.root))]
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(WorkspaceEvidence.fileReference(try WorkspacePath.parse(input.path, root: store.root)))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        let path = try WorkspacePath.parse(input.path, root: store.root)
        return try .init(
            targets: [WorkspaceEvidence.fileReference(path)],
            revision: .exact(WorkspaceContentHash.hex(input.content))
        )
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        _ = try WorkspacePath.parse(input.path, root: store.root)
        return .allowed
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let requirements = try evidenceRequirements(for: input)
        let observed = try await context.resolveEvidence(requirements)
        let path = try WorkspacePath.parse(input.path, root: store.root)
        if let expectedHash = input.expectedHash {
            guard case .string(let observedHash)? = observed[0].metadata[WorkspaceEvidence.hashKey],
                  observedHash == expectedHash else {
                throw WorkspaceFileError.staleEvidence(path.relativePath)
            }
        }
        let revision = try await store.write(path: input.path, content: input.content, expectedHash: input.expectedHash)
        let receipt = makeReceipt(
            ToolReceipt(
                operationID: context.idempotencyKey ?? "",
                status: .succeeded,
                confirmedTargets: [WorkspaceEvidence.fileReference(revision.path)],
                revision: revision.hash
            )
        )
        return ToolResult(
            output: Output(path: revision.path.relativePath, hash: revision.hash, created: revision.created),
            evidence: [WorkspaceEvidence.file(revision.path, hash: revision.hash, issuedAt: Date())],
            receipt: receipt
        )
    }

    private func makeReceipt(_ receipt: ToolReceipt) -> ToolReceipt {
        receiptTransform?(receipt) ?? receipt
    }
}

struct WorkspaceMoveFileTool: AgentTool {
    struct Input: Codable, Sendable {
        let path: String
        let destination: String
        let expectedHash: String
    }
    struct Output: Codable, Sendable { let path: String; let destination: String; let hash: String }

    static let name = "move_file"
    static let description = "Move or rename a sandbox file. The source file requires its observed content hash."
    static let inputSchema = ToolSchema.object(
        properties: ["path": .string, "destination": .string, "expectedHash": .string],
        required: ["path", "destination", "expectedHash"]
    )
    static let outputSchema = ToolSchema.object(
        properties: ["path": .string, "destination": .string, "hash": .string],
        required: ["path", "destination", "hash"]
    )

    let store: WorkspaceFileStore
    let policy: ToolPolicy

    init(store: WorkspaceFileStore) throws {
        self.store = store
        policy = try ToolPolicy(
            effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
            timeout: .seconds(5), authorization: .required, evidence: .required
        )
    }

    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        [WorkspaceEvidence.fileRequirement(try WorkspacePath.parse(input.path, root: store.root), hash: input.expectedHash)]
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [
            .named(WorkspaceEvidence.fileReference(try WorkspacePath.parse(input.path, root: store.root))),
            .named(WorkspaceEvidence.fileReference(try WorkspacePath.parse(input.destination, root: store.root))),
        ]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(
            targets: [WorkspaceEvidence.fileReference(try WorkspacePath.parse(input.destination, root: store.root))],
            revision: .exact(input.expectedHash)
        )
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        _ = try WorkspacePath.parse(input.path, root: store.root)
        _ = try WorkspacePath.parse(input.destination, root: store.root)
        return .allowed
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let observed = try await context.resolveEvidence(try evidenceRequirements(for: input))
        guard case .string(let observedHash)? = observed[0].metadata[WorkspaceEvidence.hashKey],
              observedHash == input.expectedHash else {
            throw WorkspaceFileError.staleEvidence(input.path)
        }
        let revision = try await store.move(from: input.path, to: input.destination, expectedHash: input.expectedHash)
        let receipt = ToolReceipt(
            operationID: context.idempotencyKey ?? "",
            status: .succeeded,
            confirmedTargets: [WorkspaceEvidence.fileReference(revision.path)],
            revision: revision.hash
        )
        return ToolResult(
            output: Output(path: input.path, destination: revision.path.relativePath, hash: revision.hash),
            evidence: [WorkspaceEvidence.file(revision.path, hash: revision.hash, issuedAt: Date())],
            receipt: receipt
        )
    }
}
