import Foundation

/// A single model-turn adapter. It must never execute host tools or own an agent loop.
///
/// Event contract: `responseStarted` once, then deltas, then exactly one
/// `responseCompleted` on a clean stream. After a thrown `ModelProviderError`
/// there is no terminal event. Usage snapshots are cumulative; a nil field
/// leaves the previous count unchanged. Cancelling the consumer must cancel
/// the producer and the underlying request.
public protocol ModelProvider: Sendable {
    var descriptor: ModelProviderDescriptor { get }

    /// Emit the Model Event Contract and finish, or throw a classified failure.
    /// Consumer cancellation must cancel the underlying request and producer task.
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
}

/// Optional local request validation used before a Session commits a new user
/// turn. It must not perform network I/O or mutate provider state.
public protocol ModelProviderRequestValidator: Sendable {
    func validate(request: ModelRequest) throws
}

/// Optional host hook for providers whose cancelled transport can outlive the
/// model event consumer. Hosts that must replace a run before starting another
/// one can await this hook without changing the responsive `AgentRun.cancel()`
/// contract.
public protocol ModelProviderRunDrain: Sendable {
    func waitForRunToDrain(sessionID: UUID, runID: UUID) async
}

/// Optional hook for a route that must stop switching providers after an external effect is reached.
public protocol ModelProviderMutationBoundary: Sendable {
    func markMutationBoundary(sessionID: UUID, runID: UUID) async
    func clearMutationBoundary(sessionID: UUID, runID: UUID) async
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
        case fallbackBlocked
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
