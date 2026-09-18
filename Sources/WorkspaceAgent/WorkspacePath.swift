#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

struct WorkspaceRootIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

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
        try parse(raw, root: root, identity: nil)
    }

    static func parse(_ raw: String, root: URL, identity: WorkspaceRootIdentity?) throws -> WorkspacePath {
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
        try validate(candidate, root: root, identity: identity)
        return WorkspacePath(relativePath: relativePath, url: candidate)
    }

    static func validate(_ url: URL, root: URL, identity: WorkspaceRootIdentity? = nil) throws {
        try ensureAuthorizedRoot(root, identity: identity)
        let rootPath = root.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        if candidatePath == rootPath { return }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(prefix) else {
            throw WorkspaceFileError.rejectedPath(url.path)
        }
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func captureDirectoryIdentity(_ url: URL) throws -> WorkspaceRootIdentity {
        try withDirectoryStatus(url) { status in
            WorkspaceRootIdentity(device: numericCast(status.st_dev), inode: numericCast(status.st_ino))
        }
    }

    static func ensureAuthorizedRoot(_ url: URL, identity: WorkspaceRootIdentity?) throws {
        if let identity {
            let current = try captureDirectoryIdentity(url)
            guard current == identity else {
                throw WorkspaceFileError.rejectedPath(url.path)
            }
            return
        }
        if isSymbolicLink(url) {
            throw WorkspaceFileError.rejectedPath(url.path)
        }
    }

    static func rejectSymlinkedPath(_ path: WorkspacePath, root: URL, identity: WorkspaceRootIdentity? = nil) throws {
        try ensureAuthorizedRoot(root, identity: identity)
        guard path.relativePath != "." else { return }
        var current = root.standardizedFileURL
        for segment in path.relativePath.split(separator: "/") {
            current = current.appendingPathComponent(String(segment), isDirectory: false)
            if isSymbolicLink(current) {
                throw WorkspaceFileError.rejectedPath(current.path)
            }
        }
    }

    private static func withDirectoryStatus(_ url: URL, _ body: (stat) throws -> WorkspaceRootIdentity) throws -> WorkspaceRootIdentity {
        try url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { throw WorkspaceFileError.rootUnavailable }
            var status = stat()
            guard lstat(pointer, &status) == 0 else {
                throw WorkspaceFileError.rejectedPath(url.path)
            }
            let type = status.st_mode & S_IFMT
            guard type == S_IFDIR else {
                throw WorkspaceFileError.rejectedPath(url.path)
            }
            return try body(status)
        }
    }
}
