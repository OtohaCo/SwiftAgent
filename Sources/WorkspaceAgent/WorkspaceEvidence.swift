import AgentModels
import AgentTools
import Foundation

enum WorkspaceEvidence {
    static let fileNamespace = "workspace.file"
    static let directoryNamespace = "workspace.dir"
    static let hashKey = "hash"
    static let pathKey = "path"

    static func fileReference(_ path: WorkspacePath) -> EvidenceReference {
        .init(namespace: fileNamespace, id: path.relativePath)
    }

    static func directoryReference(_ path: WorkspacePath) -> EvidenceReference {
        .init(namespace: directoryNamespace, id: path.relativePath)
    }

    static func file(_ path: WorkspacePath, hash: String, issuedAt: Date) -> Evidence {
        Evidence(
            namespace: fileNamespace,
            id: path.relativePath,
            issuedAt: issuedAt,
            metadata: [
                hashKey: .string(hash),
                pathKey: .string(path.relativePath),
            ]
        )
    }

    static func directory(_ path: WorkspacePath, hash: String, issuedAt: Date) -> Evidence {
        Evidence(
            namespace: directoryNamespace,
            id: path.relativePath,
            issuedAt: issuedAt,
            metadata: [
                hashKey: .string(hash),
                pathKey: .string(path.relativePath),
            ]
        )
    }

    static func fileRequirement(_ path: WorkspacePath, hash: String) -> EvidenceRequirement {
        EvidenceRequirement(
            reference: fileReference(path),
            scope: .sameRun,
            metadata: [hashKey: .string(hash)]
        )
    }

    static func directoryRequirement(_ path: WorkspacePath) -> EvidenceRequirement {
        EvidenceRequirement(reference: directoryReference(path), scope: .sameRun)
    }
}
