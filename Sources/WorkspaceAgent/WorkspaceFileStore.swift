#if canImport(Darwin)
import Darwin
private let posixWrite = Darwin.write
private let posixUnlink = Darwin.unlink
#elseif canImport(Glibc)
import Glibc
private let posixWrite = Glibc.write
private let posixUnlink = Glibc.unlink
#endif
import Foundation

public struct WorkspaceListedFile: Sendable, Equatable {
    public let path: WorkspacePath
    public let hash: String
}

public struct WorkspaceSearchMatch: Sendable, Equatable {
    public let path: WorkspacePath
    public let kind: Kind

    public enum Kind: String, Sendable { case name, content }
}

public struct WorkspaceFileRevision: Sendable, Equatable {
    public let path: WorkspacePath
    public let hash: String
    public let created: Bool
}

public actor WorkspaceFileStore {
    public nonisolated let root: URL
    package private(set) var mutationCount = 0
    package private(set) var peakConcurrentMutations = 0
    package private(set) var peakConcurrentReads = 0
    private var activeMutations = 0
    private var activeReads = 0
    private var mutationHold: (@Sendable () async -> Void)?
    private var readHold: (@Sendable () async -> Void)?
    private var preMutationFault: (@Sendable () async throws -> Void)?
    private var postMutationFault: (@Sendable () async throws -> Void)?
    private var afterPreconditionHold: (@Sendable () async -> Void)?

    public init(root: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceFileError.rootUnavailable
        }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    package func setMutationHold(_ hold: (@Sendable () async -> Void)?) { mutationHold = hold }
    package func setReadHold(_ hold: (@Sendable () async -> Void)?) { readHold = hold }
    package func setPreMutationFault(_ fault: (@Sendable () async throws -> Void)?) { preMutationFault = fault }
    package func setPostMutationFault(_ fault: (@Sendable () async throws -> Void)?) { postMutationFault = fault }
    package func setAfterPreconditionHold(_ hold: (@Sendable () async -> Void)?) { afterPreconditionHold = hold }

    func location(_ raw: String) throws -> WorkspacePath {
        try WorkspacePath.parse(raw, root: root)
    }

    func list(directory raw: String) async throws -> (directory: WorkspacePath, files: [WorkspaceListedFile], listingHash: String) {
        let directory = try WorkspacePath.parse(raw, root: root)
        return try await withReadLease {
            try WorkspacePath.validate(directory.url, root: root)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw WorkspaceFileError.notFound(directory.relativePath)
            }
            let files = try listedFiles(under: directory)
            let listingHash = WorkspaceContentHash.hex(
                files.map { "\($0.path.relativePath):\($0.hash)" }.joined(separator: "\n")
            )
            return (directory, files, listingHash)
        }
    }

    func read(_ raw: String) async throws -> (file: WorkspaceListedFile, content: String) {
        let path = try WorkspacePath.parse(raw, root: root)
        return try await withReadLease {
            let snapshot = try snapshot(path)
            guard let content = snapshot.content else { throw WorkspaceFileError.notUnicode(path.relativePath) }
            return (WorkspaceListedFile(path: path, hash: snapshot.hash), content)
        }
    }

    func search(query: String, directory raw: String) async throws -> [WorkspaceSearchMatch] {
        let directory = try WorkspacePath.parse(raw, root: root)
        return try await withReadLease {
            try WorkspacePath.validate(directory.url, root: root)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw WorkspaceFileError.notFound(directory.relativePath)
            }
            var matches: [WorkspaceSearchMatch] = []
            for file in try listedFiles(under: directory) {
                if file.path.relativePath.contains(query) {
                    matches.append(.init(path: file.path, kind: .name))
                }
                let data = try Data(contentsOf: file.path.url)
                if let text = String(data: data, encoding: .utf8), text.contains(query) {
                    matches.append(.init(path: file.path, kind: .content))
                }
            }
            return matches
        }
    }

    func write(path raw: String, content: String, expectedHash: String?) async throws -> WorkspaceFileRevision {
        let path = try WorkspacePath.parse(raw, root: root)
        return try await withMutationLease {
            try evaluateWritePreconditions(path: path, expectedHash: expectedHash, afterHold: false)
            await afterPreconditionHold?()
            try evaluateWritePreconditions(path: path, expectedHash: expectedHash, afterHold: true)
            if expectedHash == nil {
                try exclusiveCreate(at: path.url, data: Data(content.utf8), relativePath: path.relativePath)
            } else {
                try Data(content.utf8).write(to: path.url, options: .atomic)
            }
            mutationCount += 1
            try await postMutationFault?()
            let hash = WorkspaceContentHash.hex(content)
            let onDisk = try snapshot(path)
            guard onDisk.hash == hash else {
                throw WorkspaceFileError.staleEvidence(path.relativePath)
            }
            return WorkspaceFileRevision(path: path, hash: hash, created: expectedHash == nil)
        }
    }

    func move(from sourceRaw: String, to destinationRaw: String, expectedHash: String) async throws -> WorkspaceFileRevision {
        let source = try WorkspacePath.parse(sourceRaw, root: root)
        let destination = try WorkspacePath.parse(destinationRaw, root: root)
        return try await withMutationLease {
            try evaluateMovePreconditions(source: source, destination: destination, expectedHash: expectedHash)
            await afterPreconditionHold?()
            try evaluateMovePreconditions(source: source, destination: destination, expectedHash: expectedHash)
            do {
                try FileManager.default.moveItem(at: source.url, to: destination.url)
            } catch {
                if FileManager.default.fileExists(atPath: destination.url.path) {
                    throw WorkspaceFileError.alreadyExists(destination.relativePath)
                }
                throw error
            }
            mutationCount += 1
            try await postMutationFault?()
            let onDisk = try snapshot(destination)
            guard onDisk.hash == expectedHash else {
                throw WorkspaceFileError.staleEvidence(destination.relativePath)
            }
            return WorkspaceFileRevision(path: destination, hash: expectedHash, created: false)
        }
    }

    func currentHash(_ raw: String) throws -> String? {
        let path = try WorkspacePath.parse(raw, root: root)
        guard FileManager.default.fileExists(atPath: path.url.path) else { return nil }
        return try snapshot(path).hash
    }

    private func listedFiles(under directory: WorkspacePath) throws -> [WorkspaceListedFile] {
        let enumerator = FileManager.default.enumerator(
            at: directory.url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var files: [WorkspaceListedFile] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }
            try WorkspacePath.validate(url, root: root)
            let relative = try relativePath(for: url)
            let path = WorkspacePath(relativePath: relative, url: url)
            files.append(.init(path: path, hash: try snapshot(path).hash))
        }
        return files.sorted { $0.path.relativePath.utf8.lexicographicallyPrecedes($1.path.relativePath.utf8) }
    }

    private struct FileSnapshot {
        let hash: String
        let content: String?
    }

    private func snapshot(_ path: WorkspacePath) throws -> FileSnapshot {
        try WorkspacePath.rejectSymlinkedPath(path, root: root)
        try WorkspacePath.validate(path.url, root: root)
        guard FileManager.default.fileExists(atPath: path.url.path) else {
            throw WorkspaceFileError.notFound(path.relativePath)
        }
        let data = try Data(contentsOf: path.url)
        return FileSnapshot(hash: WorkspaceContentHash.hex(data), content: String(data: data, encoding: .utf8))
    }

    private func evaluateWritePreconditions(path: WorkspacePath, expectedHash: String?, afterHold: Bool) throws {
        try WorkspacePath.rejectSymlinkedPath(path, root: root)
        try WorkspacePath.validate(path.url, root: root)
        let existed = FileManager.default.fileExists(atPath: path.url.path)
        if let expectedHash {
            guard existed else { throw WorkspaceFileError.notFound(path.relativePath) }
            let current = try snapshot(path)
            guard current.hash == expectedHash else { throw WorkspaceFileError.staleEvidence(path.relativePath) }
        } else if existed {
            throw afterHold
                ? WorkspaceFileError.alreadyExists(path.relativePath)
                : WorkspaceFileError.missingEvidence(path.relativePath)
        } else {
            try requireParent(of: path)
        }
    }

    private func evaluateMovePreconditions(
        source: WorkspacePath,
        destination: WorkspacePath,
        expectedHash: String
    ) throws {
        try WorkspacePath.rejectSymlinkedPath(source, root: root)
        try WorkspacePath.rejectSymlinkedPath(destination, root: root)
        try WorkspacePath.validate(source.url, root: root)
        try WorkspacePath.validate(destination.url, root: root)
        let current = try snapshot(source)
        guard current.hash == expectedHash else { throw WorkspaceFileError.staleEvidence(source.relativePath) }
        if FileManager.default.fileExists(atPath: destination.url.path) || WorkspacePath.isSymbolicLink(destination.url) {
            throw WorkspaceFileError.alreadyExists(destination.relativePath)
        }
        try requireParent(of: destination)
    }

    private func requireParent(of path: WorkspacePath) throws {
        let parent = path.url.deletingLastPathComponent()
        try WorkspacePath.validate(parent, root: root)
        if path.parentRelativePath != "." {
            try WorkspacePath.rejectSymlinkedPath(
                WorkspacePath(relativePath: path.parentRelativePath, url: parent),
                root: root
            )
        } else if WorkspacePath.isSymbolicLink(root) {
            throw WorkspaceFileError.rejectedPath(root.path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceFileError.parentMissing(path.parentRelativePath)
        }
    }

    private func exclusiveCreate(at url: URL, data: Data, relativePath: String) throws {
        try url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { throw WorkspaceFileError.rejectedPath(relativePath) }
            let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW
            let fd = open(pointer, flags, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            guard fd >= 0 else {
                if errno == EEXIST { throw WorkspaceFileError.alreadyExists(relativePath) }
                throw WorkspaceFileError.rejectedPath(relativePath)
            }
            defer { close(fd) }
            var written = 0
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                while written < buffer.count {
                    let n = posixWrite(fd, base.advanced(by: written), buffer.count - written)
                    if n <= 0 {
                        _ = posixUnlink(pointer)
                        throw WorkspaceFileError.rejectedPath(relativePath)
                    }
                    written += n
                }
            }
            if fsync(fd) != 0 {
                _ = posixUnlink(pointer)
                throw WorkspaceFileError.rejectedPath(relativePath)
            }
        }
    }

    private func relativePath(for url: URL) throws -> String {
        try WorkspacePath.validate(url, root: root)
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == root.path { return "." }
        return String(path.dropFirst(rootPath.count))
    }

    private func withMutationLease<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        activeMutations += 1
        peakConcurrentMutations = max(peakConcurrentMutations, activeMutations)
        defer { activeMutations -= 1 }
        await mutationHold?()
        try await preMutationFault?()
        return try await body()
    }

    private func withReadLease<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        activeReads += 1
        peakConcurrentReads = max(peakConcurrentReads, activeReads)
        defer { activeReads -= 1 }
        await readHold?()
        return try await body()
    }
}
