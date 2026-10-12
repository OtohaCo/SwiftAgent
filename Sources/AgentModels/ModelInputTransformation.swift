import Foundation

/// Stable content correspondence, independent of a vendor's encoded array positions.
/// Digests identify exact input material; they do not certify summary semantics or signatures.
public struct ModelInputSourceIdentity: Hashable, Sendable, Codable {
    public let messageDigest: String
    public let contentDigest: String
    public let nativeCheckpointID: UUID?
    public init(messageDigest: String, contentDigest: String, nativeCheckpointID: UUID? = nil) {
        self.messageDigest = messageDigest; self.contentDigest = contentDigest; self.nativeCheckpointID = nativeCheckpointID
    }
}

/// A provider-reported transformation, never assistant answer content. Open strings
/// preserve future kinds/reasons. An unmapped path remains observable without inventing an identity.
public struct ModelInputTransformation: Hashable, Sendable, Codable {
    public let kind: String
    public let reason: String?
    public let path: String
    public let source: ModelInputSourceIdentity?
    public var thinkingWasDropped: Bool { kind == "thinking_dropped" }
    public init(kind: String, reason: String?, path: String, source: ModelInputSourceIdentity?) {
        self.kind = kind; self.reason = reason; self.path = path; self.source = source
    }
}

/// Optional native progress. Progress alone cannot publish a context checkpoint.
public struct ModelCompactionProgress: Hashable, Sendable, Codable {
    public let responseID: String?
    public let phase: String
    public init(responseID: String?, phase: String) { self.responseID = responseID; self.phase = phase }
}
