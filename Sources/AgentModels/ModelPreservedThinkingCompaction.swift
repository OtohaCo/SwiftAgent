import Foundation

/// A local witness of the exact encoded request, not vendor signature validation.
public struct ModelPreservedThinkingRequestWitness: Hashable, Sendable, Codable {
    public let prefixDigest: String
    public let rootToolsDigest: String
    public let qualificationScope: String
    public init(prefixDigest: String, rootToolsDigest: String, qualificationScope: String) throws {
        guard validThinkingDigest(prefixDigest), validThinkingDigest(rootToolsDigest), validThinkingDigest(qualificationScope) else { throw invalidThinkingProof() }
        self.prefixDigest = prefixDigest; self.rootToolsDigest = rootToolsDigest
        self.qualificationScope = qualificationScope
    }
    private enum CodingKeys: String, CodingKey { case prefixDigest, rootToolsDigest, qualificationScope }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(prefixDigest: c.decode(String.self, forKey: .prefixDigest),
            rootToolsDigest: c.decode(String.self, forKey: .rootToolsDigest),
            qualificationScope: c.decode(String.self, forKey: .qualificationScope))
    }

}

/// Core attaches this only to a complete accepted assistant continuation. The
/// immutable request source and wire witness let a managed operation reproduce
/// a real request boundary instead of accepting arbitrary history slicing.
public struct ModelProviderRequestBoundary: Hashable, Sendable, Codable {
    public let id: UUID
    public let source: ModelNativeContextSource
    public let invocationID: UUID
    public let origin: ModelProviderContinuationOrigin
    public let rootConfigurationDigest: String
    public let tools: [ModelToolDefinition]
    public let conversationControls: ModelConversationControlView?
    public let witness: ModelPreservedThinkingRequestWitness
    public init(id: UUID, source: ModelNativeContextSource, invocationID: UUID,
                origin: ModelProviderContinuationOrigin, rootConfigurationDigest: String,
                tools: [ModelToolDefinition], conversationControls: ModelConversationControlView?,
                witness: ModelPreservedThinkingRequestWitness) throws {
        guard source.canonicalMessageCount > 0, validSourceDigest(rootConfigurationDigest),
              validSourceDigest(source.canonicalDigest), validThinkingDigest(source.requestDigest),
              !source.projectionID.isEmpty, !source.projectionVersion.isEmpty,
              [origin.providerID, origin.serviceInstanceID, origin.endpointScope, origin.apiDialect, origin.configurationRevision].allSatisfy({ !$0.isEmpty }),
              tools.count <= 10_000, Set(tools.map(\.name)).count == tools.count else { throw invalidThinkingProof() }
        self.id = id; self.source = source; self.invocationID = invocationID; self.origin = origin
        self.rootConfigurationDigest = rootConfigurationDigest; self.tools = tools
        self.conversationControls = conversationControls; self.witness = witness
    }
    private enum CodingKeys: String, CodingKey { case id, source, invocationID, origin, rootConfigurationDigest, tools, conversationControls, witness }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id),
            source: c.decode(ModelNativeContextSource.self, forKey: .source),
            invocationID: c.decode(UUID.self, forKey: .invocationID),
            origin: c.decode(ModelProviderContinuationOrigin.self, forKey: .origin),
            rootConfigurationDigest: c.decode(String.self, forKey: .rootConfigurationDigest),
            tools: c.decode([ModelToolDefinition].self, forKey: .tools),
            conversationControls: c.decodeIfPresent(ModelConversationControlView.self, forKey: .conversationControls),
            witness: c.decode(ModelPreservedThinkingRequestWitness.self, forKey: .witness))
    }

}

/// An allowed local prefix replacement. Original continuation payloads and their
/// witnesses are never rewritten; both digests must match the verified transform.
public struct ModelThinkingPrefixReplacement: Hashable, Sendable, Codable {
    public let originalDigest: String
    public let replacementDigest: String
    public let continuationPayloadDigest: String
    public init(originalDigest: String, replacementDigest: String, continuationPayloadDigest: String) throws {
        guard validThinkingDigest(originalDigest), validThinkingDigest(replacementDigest), validThinkingDigest(continuationPayloadDigest) else { throw invalidThinkingProof() }
        self.originalDigest = originalDigest; self.replacementDigest = replacementDigest
        self.continuationPayloadDigest = continuationPayloadDigest
    }
    private enum CodingKeys: String, CodingKey { case originalDigest, replacementDigest, continuationPayloadDigest }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(originalDigest: c.decode(String.self, forKey: .originalDigest),
            replacementDigest: c.decode(String.self, forKey: .replacementDigest),
            continuationPayloadDigest: c.decode(String.self, forKey: .continuationPayloadDigest))
    }

}

/// The proof of one managed, service-written replacement, carried by the same
/// native checkpoint transaction. Later appends do not extend the protected tail.
public struct ModelPreservedThinkingLineage: Hashable, Sendable, Codable {
    public let boundary: ModelProviderRequestBoundary
    public let parentCheckpointID: UUID?
    public let tailMessageCount: Int
    public let tailDigest: String
    public let replacements: [ModelThinkingPrefixReplacement]
    public init(boundary: ModelProviderRequestBoundary, parentCheckpointID: UUID?, tailMessageCount: Int,
                tailDigest: String, replacements: [ModelThinkingPrefixReplacement]) throws {
        guard tailMessageCount > 0, validSourceDigest(tailDigest), replacements.count <= 10_000,
              boundary.source.previousCheckpointID == parentCheckpointID else { throw invalidThinkingProof() }
        self.boundary = boundary; self.parentCheckpointID = parentCheckpointID
        self.tailMessageCount = tailMessageCount; self.tailDigest = tailDigest; self.replacements = replacements
    }
    private enum CodingKeys: String, CodingKey { case boundary, parentCheckpointID, tailMessageCount, tailDigest, replacements }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(boundary: c.decode(ModelProviderRequestBoundary.self, forKey: .boundary),
            parentCheckpointID: c.decodeIfPresent(UUID.self, forKey: .parentCheckpointID),
            tailMessageCount: c.decode(Int.self, forKey: .tailMessageCount),
            tailDigest: c.decode(String.self, forKey: .tailDigest),
            replacements: c.decode([ModelThinkingPrefixReplacement].self, forKey: .replacements))
    }

}

/// Narrow opt-in capability for qualified preserved-thinking replacements. It
/// does not extend other adapters or turn metadata into deployment qualification.
public protocol ModelProviderPreservedThinkingCompaction: ModelProviderNativeContextWitness {
    var supportsPreservedThinkingCompaction: Bool { get }
    func preservedThinkingRequestWitness(request: ModelRequest) throws -> ModelPreservedThinkingRequestWitness
    /// Strict local prefix proof validation even when a server mismatch fallback is configured.
    /// This does not dispatch, count tokens, or validate the vendor signature.
    func validatePreservedThinkingTail(request: ModelRequest) throws
    func preservedThinkingReplacements(request: ModelRequest, replacement: ModelNativeContextCheckpoint,
                                       keptMessages: [ModelMessage]) throws -> [ModelThinkingPrefixReplacement]
}

private func validThinkingDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
private func invalidThinkingProof() -> ModelProviderError {
    .init(kind: .invalidRequest, message: "Invalid preserved-thinking request or replacement proof.")
}

private func validSourceDigest(_ value: String) -> Bool {
    value.utf8.count == 16 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
