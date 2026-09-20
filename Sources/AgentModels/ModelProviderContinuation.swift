import Foundation

/// Non-secret execution scope attached by AgentCore to provider-owned state.
/// It prevents opaque payloads from crossing model, endpoint, dialect, or
/// configuration boundaries without an explicit semantic handoff.
public struct ModelProviderContinuationOrigin: Hashable, Sendable, Codable {
    public let providerID: String
    public let serviceInstanceID: String
    public let endpointScope: String
    public let apiDialect: String
    public let apiVersion: String?
    public let configurationRevision: String

    public init(
        providerID: String,
        serviceInstanceID: String,
        endpointScope: String,
        apiDialect: String,
        apiVersion: String? = nil,
        configurationRevision: String
    ) {
        self.providerID = providerID
        self.serviceInstanceID = serviceInstanceID
        self.endpointScope = endpointScope
        self.apiDialect = apiDialect
        self.apiVersion = apiVersion
        self.configurationRevision = configurationRevision
    }
}

/// Opaque continuation state interpreted only by its owning provider, never by the agent loop.
public struct ModelProviderContinuation: Hashable, Sendable, Codable {
    public let model: ModelID
    public let format: String
    public let payload: Data
    /// Missing only on journal data written before scoped continuations existed.
    public let origin: ModelProviderContinuationOrigin?

    /// Compatibility initializer for payloads created before continuation
    /// deployment scope was introduced.
    public init(model: ModelID, format: String, payload: Data) {
        self.init(model: model, format: format, payload: payload, origin: nil)
    }

    public init(
        model: ModelID,
        format: String,
        payload: Data,
        origin: ModelProviderContinuationOrigin?
    ) {
        self.model = model
        self.format = format
        self.payload = payload
        self.origin = origin
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model.provider.utf8.elementsEqual(rhs.model.provider.utf8)
            && lhs.model.name.utf8.elementsEqual(rhs.model.name.utf8)
            && lhs.format.utf8.elementsEqual(rhs.format.utf8)
            && lhs.payload == rhs.payload
            && lhs.origin == rhs.origin
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(model.provider.utf8))
        hasher.combine(Array(model.name.utf8))
        hasher.combine(Array(format.utf8))
        hasher.combine(payload)
        hasher.combine(origin)
    }
}
