import AgentModels
import Foundation

public struct ModelCatalogRequest: Hashable, Sendable, Codable {
    public let cursor: String?
    public let pageSize: Int?

    public init(cursor: String? = nil, pageSize: Int? = nil) {
        self.cursor = cursor
        self.pageSize = pageSize
    }
}

public struct ModelCatalogPage: Hashable, Sendable, Codable {
    public let models: [ModelCatalogEntry]
    public let nextCursor: String?
    /// True when the upstream explicitly says this page is incomplete.
    public let isPartial: Bool

    public init(models: [ModelCatalogEntry], nextCursor: String? = nil, isPartial: Bool = false) {
        self.models = models
        self.nextCursor = nextCursor
        self.isPartial = isPartial
    }
}

/// Optional discovery surface. A `ModelProvider` is not required to implement it.
public protocol ModelCatalogProvider: Sendable {
    var scope: ModelServiceScope { get }
    /// Stable upstream or Host manifest revision, when one exists.
    var catalogRevision: String? { get }
    func listModels(_ request: ModelCatalogRequest) async throws -> ModelCatalogPage
}

public extension ModelCatalogProvider {
    var catalogRevision: String? { nil }
}

/// Optional detail lookup when the upstream exposes a model-detail endpoint.
public protocol ModelCatalogDetailProvider: ModelCatalogProvider {
    func modelDetails(deploymentID: String) async throws -> ModelCatalogEntry
}

/// A Host-managed manifest for providers without a discovery endpoint.
public struct ModelCatalogManifest: Hashable, Sendable, Codable {
    public let scope: ModelServiceScope
    public let revision: String
    public let models: [ModelCatalogEntry]
    public let generatedAt: Date?

    public init(
        scope: ModelServiceScope,
        revision: String,
        models: [ModelCatalogEntry],
        generatedAt: Date? = nil
    ) throws {
        guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelCatalogError(kind: .invalidConfiguration)
        }
        guard models.allSatisfy({ $0.serviceScope == scope && $0.model.provider == scope.provider }) else {
            throw ModelCatalogError(kind: .scopeMismatch)
        }
        self.scope = scope
        self.revision = revision
        self.models = models
        self.generatedAt = generatedAt
    }
}

public struct StaticModelCatalogProvider: ModelCatalogProvider {
    public let scope: ModelServiceScope
    private let entries: [ModelCatalogEntry]
    public let manifestRevision: String?
    public var catalogRevision: String? { manifestRevision }

    public init(scope: ModelServiceScope, entries: [ModelCatalogEntry]) throws {
        guard entries.allSatisfy({ $0.serviceScope == scope && $0.model.provider == scope.provider }) else {
            throw ModelCatalogError(kind: .scopeMismatch)
        }
        self.scope = scope
        self.entries = entries
        manifestRevision = nil
    }

    public init(manifest: ModelCatalogManifest) {
        scope = manifest.scope
        entries = manifest.models
        manifestRevision = manifest.revision
    }

    public func listModels(_ request: ModelCatalogRequest) async throws -> ModelCatalogPage {
        guard request.cursor == nil else { return .init(models: []) }
        return .init(models: entries)
    }
}

public struct ModelCatalogError: Error, Equatable, Sendable {
    public struct Kind: RawRepresentable, Hashable, Sendable, Codable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let invalidConfiguration = Self(rawValue: "invalid_configuration")
        public static let authentication = Self(rawValue: "authentication")
        public static let permissionDenied = Self(rawValue: "permission_denied")
        public static let rateLimited = Self(rawValue: "rate_limited")
        public static let unavailable = Self(rawValue: "unavailable")
        public static let transport = Self(rawValue: "transport")
        public static let invalidResponse = Self(rawValue: "invalid_response")
        public static let responseTooLarge = Self(rawValue: "response_too_large")
        public static let repeatedCursor = Self(rawValue: "repeated_cursor")
        public static let pageLimitReached = Self(rawValue: "page_limit_reached")
        public static let incompleteRefresh = Self(rawValue: "incomplete_refresh")
        public static let scopeMismatch = Self(rawValue: "scope_mismatch")
        public static let conflictingDuplicate = Self(rawValue: "conflicting_duplicate")
        public static let supersededRefresh = Self(rawValue: "superseded_refresh")

        public init(from decoder: any Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public let kind: Kind
    public let retryAfter: Duration?
    public let requestID: String?

    public init(kind: Kind, retryAfter: Duration? = nil, requestID: String? = nil) {
        self.kind = kind
        self.retryAfter = retryAfter
        self.requestID = requestID
    }
}
