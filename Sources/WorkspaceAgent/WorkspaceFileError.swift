public enum WorkspaceFileError: Error, Equatable, Sendable {
    case rootUnavailable
    case rejectedPath(String)
    case notFound(String)
    case notUnicode(String)
    case missingEvidence(String)
    case staleEvidence(String)
    case alreadyExists(String)
    case parentMissing(String)
}
