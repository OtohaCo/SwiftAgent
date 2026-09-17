import AgentModels
import Foundation

public struct EvidenceReference: Hashable, Sendable, Codable {
    public let namespace: String
    public let id: String

    public init(namespace: String, id: String) {
        self.namespace = namespace
        self.id = id
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.namespace.utf8.elementsEqual(rhs.namespace.utf8) && lhs.id.utf8.elementsEqual(rhs.id.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(namespace.utf8))
        hasher.combine(Array(id.utf8))
    }

    var isValid: Bool {
        !namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct Evidence: Hashable, Sendable, Codable {
    public let namespace: String
    public let id: String
    public let issuedAt: Date
    public let expiresAt: Date?
    public let metadata: [String: JSONValue]
    public var reference: EvidenceReference { .init(namespace: namespace, id: id) }

    public init(namespace: String, id: String, issuedAt: Date, expiresAt: Date? = nil, metadata: [String: JSONValue] = [:]) {
        self.namespace = namespace
        self.id = id
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.metadata = metadata
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.reference == rhs.reference && lhs.issuedAt == rhs.issuedAt && lhs.expiresAt == rhs.expiresAt
            && ToolSchemaValidator.jsonEqual(.object(lhs.metadata), .object(rhs.metadata))
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(reference)
        hasher.combine(issuedAt)
        hasher.combine(expiresAt)
        hasher.combine(metadata)
    }
}

public enum EvidenceScope: String, Hashable, Sendable, Codable { case sameRun, sameSession }

public struct EvidenceRequirement: Hashable, Sendable {
    public let reference: EvidenceReference
    public let scope: EvidenceScope
    public let metadata: [String: JSONValue]

    public init(reference: EvidenceReference, scope: EvidenceScope = .sameRun, metadata: [String: JSONValue] = [:]) {
        self.reference = reference
        self.scope = scope
        self.metadata = metadata
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.reference == rhs.reference && lhs.scope == rhs.scope
            && ToolSchemaValidator.jsonEqual(.object(lhs.metadata), .object(rhs.metadata))
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(reference)
        hasher.combine(scope)
        hasher.combine(metadata)
    }
}
