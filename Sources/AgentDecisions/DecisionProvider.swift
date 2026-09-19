import Foundation

/// Evaluates typed questions without owning a conversation loop or executing Host tools.
public protocol DecisionProvider: Sendable {
    /// Identity of the configured decision adapter.
    var descriptor: DecisionProviderDescriptor { get }
    /// Evaluate one request or throw a classified failure or `CancellationError`.
    func decide(_ request: DecisionRequest) async throws -> DecisionResponse
}

/// Stable identity for a configured decision adapter.
public struct DecisionProviderDescriptor: Hashable, Sendable, Codable {
    /// Open provider namespace, such as `jev` or a Host-defined adapter ID.
    public let id: String
    public init(id: String) { self.id = id }
}

/// Sanitized, programmatically classified decision-provider failure.
/// Caller cancellation is represented by `CancellationError` instead.
public struct DecisionProviderError: Error, Equatable, Sendable {
    /// Extensible machine-readable failure category.
    public struct Kind: RawRepresentable, Hashable, Sendable, Codable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let invalidConfiguration = Self(rawValue: "invalid_configuration")
        public static let authentication = Self(rawValue: "authentication")
        public static let permissionDenied = Self(rawValue: "permission_denied")
        public static let invalidRequest = Self(rawValue: "invalid_request")
        public static let rateLimited = Self(rawValue: "rate_limited")
        public static let unavailable = Self(rawValue: "unavailable")
        public static let transport = Self(rawValue: "transport")
        public static let invalidResponse = Self(rawValue: "invalid_response")
        public static let deadlineExceeded = Self(rawValue: "deadline_exceeded")

        public init(from decoder: any Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Stable failure category.
    public let kind: Kind
    /// SDK-owned diagnostic that must not contain credentials or payloads.
    public let message: String
    /// Server-provided retry delay metadata. The adapter does not retry automatically.
    public let retryAfter: Duration?
    /// Sanitized provider request identity, when supplied.
    public let requestID: String?

    public init(
        kind: Kind,
        message: String,
        retryAfter: Duration? = nil,
        requestID: String? = nil
    ) {
        self.kind = kind
        self.message = message
        self.retryAfter = retryAfter
        self.requestID = requestID
    }
}
