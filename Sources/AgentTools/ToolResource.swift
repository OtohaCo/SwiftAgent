public enum ToolResource: Hashable, Sendable, Codable {
    case global
    case named(EvidenceReference)

    package static func validate(_ resources: [ToolResource]) throws {
        guard !resources.isEmpty else { throw ToolResourceError.empty }
        var seen = Set<ToolResource>()
        for resource in resources {
            if case .named(let reference) = resource, !reference.isValid {
                throw ToolResourceError.invalidReference(reference)
            }
            guard seen.insert(resource).inserted else { throw ToolResourceError.duplicate }
        }
    }
}

public enum ToolResourceError: Error, Equatable, Sendable {
    case empty
    case invalidReference(EvidenceReference)
    case duplicate
}
