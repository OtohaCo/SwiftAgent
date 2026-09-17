/// A single model-turn adapter. It must never execute host tools or own an agent loop.
public protocol ModelProvider: Sendable {
    var descriptor: ModelProviderDescriptor { get }

    /// Emit the Model Event Contract and finish, or throw a classified failure.
    /// Consumer cancellation must cancel the underlying request and producer task.
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
}

public struct ModelProviderDescriptor: Hashable, Sendable, Codable {
    /// Open provider namespace matching ModelID.provider, including custom endpoints.
    public let id: String
    /// Capabilities of this configured adapter; not a claim about every vendor model.
    public let capabilities: ModelCapabilities

    public init(id: String, capabilities: ModelCapabilities) {
        self.id = id
        self.capabilities = capabilities
    }
}

/// Adapter-classified failure. Retry hints never authorize replay of external effects.
/// Cancellation is represented by CancellationError, not a provider failure kind.
public struct ModelProviderError: Error, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case authentication
        case permissionDenied
        case invalidRequest
        case unsupportedCapability
        case rateLimited
        case unavailable
        case transport
        case invalidResponse
    }

    public let kind: Kind
    /// Sanitized diagnostic; adapters must exclude credentials and request payloads.
    public let message: String
    public let retryAfter: Duration?

    public init(kind: Kind, message: String, retryAfter: Duration? = nil) {
        self.kind = kind
        self.message = message
        self.retryAfter = retryAfter
    }
}
