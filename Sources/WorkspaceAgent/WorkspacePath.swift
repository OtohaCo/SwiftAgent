import Foundation

public struct WorkspacePath: Hashable, Sendable {
    public let relativePath: String
    public let url: URL

    public var parentRelativePath: String {
        let parts = relativePath.split(separator: "/")
        guard parts.count > 1 else { return "." }
        return parts.dropLast().joined(separator: "/")
    }

    public static func root(in root: URL) -> WorkspacePath {
        WorkspacePath(relativePath: ".", url: root)
    }

    public static func parse(_ raw: String, root: URL) throws -> WorkspacePath {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "." { return .root(in: root) }
        guard !trimmed.isEmpty else { throw WorkspaceFileError.rejectedPath(raw) }
        guard !trimmed.contains("\0"), !trimmed.contains("\\"), !trimmed.contains(":") else {
            throw WorkspaceFileError.rejectedPath(raw)
        }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw WorkspaceFileError.rejectedPath(raw)
        }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WorkspaceFileError.rejectedPath(raw)
        }
        let relativePath = segments.joined(separator: "/")
        let candidate = segments.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
        try validate(candidate, root: root)
        return WorkspacePath(relativePath: relativePath, url: candidate)
    }

    static func validate(_ url: URL, root: URL) throws {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path
        let candidatePath = resolved.path
        if candidatePath == rootPath { return }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(prefix) else {
            throw WorkspaceFileError.rejectedPath(url.path)
        }
    }
}
