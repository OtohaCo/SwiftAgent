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
            let existed = FileManager.default.fileExists(atPath: path.url.path)
            if existed {
                guard let expectedHash else { throw WorkspaceFileError.missingEvidence(path.relativePath) }
                let current = try snapshot(path)
                guard current.hash == expectedHash else { throw WorkspaceFileError.staleEvidence(path.relativePath) }
            } else {
                guard expectedHash == nil else { throw WorkspaceFileError.notFound(path.relativePath) }
                try requireParent(of: path)
            }
            try Data(content.utf8).write(to: path.url, options: .atomic)
            mutationCount += 1
            try await postMutationFault?()
            let hash = WorkspaceContentHash.hex(content)
            return WorkspaceFileRevision(path: path, hash: hash, created: !existed)
        }
    }

    func move(from sourceRaw: String, to destinationRaw: String, expectedHash: String) async throws -> WorkspaceFileRevision {
        let source = try WorkspacePath.parse(sourceRaw, root: root)
        let destination = try WorkspacePath.parse(destinationRaw, root: root)
        return try await withMutationLease {
            let current = try snapshot(source)
            guard current.hash == expectedHash else { throw WorkspaceFileError.staleEvidence(source.relativePath) }
            if FileManager.default.fileExists(atPath: destination.url.path) {
                throw WorkspaceFileError.alreadyExists(destination.relativePath)
            }
            try requireParent(of: destination)
            try FileManager.default.moveItem(at: source.url, to: destination.url)
            mutationCount += 1
            try await postMutationFault?()
            return WorkspaceFileRevision(path: destination, hash: current.hash, created: false)
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
        try WorkspacePath.validate(path.url, root: root)
        guard FileManager.default.fileExists(atPath: path.url.path) else {
            throw WorkspaceFileError.notFound(path.relativePath)
        }
        let data = try Data(contentsOf: path.url)
        return FileSnapshot(hash: WorkspaceContentHash.hex(data), content: String(data: data, encoding: .utf8))
    }

    private func requireParent(of path: WorkspacePath) throws {
        let parent = path.url.deletingLastPathComponent()
        try WorkspacePath.validate(parent, root: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceFileError.parentMissing(path.parentRelativePath)
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
