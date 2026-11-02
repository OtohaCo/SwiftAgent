import Foundation

/// One physical model request: which model and route candidate served it, what the service reported of
/// its tokens, how it ended and how long it took. Bounded: it never carries the request, response text,
/// tool calls or a provider's message, and its few strings are capped at `maximumTextBytes`.
///
/// A `ModelProviderRoute` created with `reportsAttempts: true` reports each request it sends to a
/// candidate as `ModelEvent.requestAttempt`. A Run with `AgentConfiguration.reportsModelRequests`
/// carries exactly one record for each model request it made: the provider's own reports, forwarded,
/// and one the runtime makes for a request the provider did not report. Native compaction requests are
/// reported by `AgentEvent.compaction` instead.
///
/// For usage accounting, a record maps onto `UsageRecordIdentity` as `model`, `providerResponseID` =
/// `responseID` and `routeSource` = `candidate`. A completed record repeats the usage of the stream's
/// `responseCompleted`; failed and cancelled records are spend that no response carries.
public struct ModelRequestAttempt: Hashable, Sendable, Codable {
    public enum Outcome: Hashable, Sendable, Codable {
        /// The response completed with this stop reason.
        case completed(StopReason)
        case failed(Failure)
        /// Stopped before it ended: by the user, the deadline, or the runtime refusing what had arrived.
        /// The service may or may not have received or billed it.
        case cancelled
    }

    /// Fixed categories only; no provider text.
    public enum Failure: Hashable, Sendable, Codable {
        /// The provider's classified failure.
        case provider(ModelProviderError.Kind, ModelProviderError.Diagnostic?)
        /// The events broke the model event contract.
        case invalidStream
        /// An error of a type the model contract does not define.
        case unclassified

        public init(classifying error: any Error) {
            switch error {
            case let failure as ModelProviderError: self = .provider(failure.kind, failure.diagnostic)
            case is ModelStreamError: self = .invalidStream
            default: self = .unclassified
            }
        }
    }

    public static let maximumTextBytes = 512

    /// 1-based position among the physical requests made for one `stream(request:)` call.
    public let ordinal: Int
    public let model: ModelID
    /// The route candidate that served it. Nil outside a route, for a request the runtime recorded itself
    /// (such as a route's request stopped in flight), or when longer than `maximumTextBytes`.
    public let candidate: String?
    /// Nil when no response started, or when the ID is longer than `maximumTextBytes`.
    public let responseID: String?
    /// As reported, also by a request that failed or was stopped. Nil fields are unreported, not zero.
    public let usage: ModelUsage
    /// An unknown stop reason is kept up to `maximumTextBytes`.
    public let outcome: Outcome
    /// From sending the request to its end. A wait before a retry belongs to no request.
    public let duration: Duration

    public init(ordinal: Int, model: ModelID, candidate: String?, responseID: String?, usage: ModelUsage,
                outcome: Outcome, duration: Duration) {
        self.ordinal = ordinal
        self.model = model
        self.candidate = candidate.flatMap { $0.utf8.count <= Self.maximumTextBytes ? $0 : nil }
        self.responseID = responseID.flatMap { $0.utf8.count <= Self.maximumTextBytes ? $0 : nil }
        self.usage = usage
        if case .completed(.unknown(let reason)) = outcome {
            self.outcome = .completed(.unknown(Self.prefix(of: reason)))
        } else {
            self.outcome = outcome
        }
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey { case ordinal, model, candidate, responseID, usage, outcome, duration }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(ordinal: try c.decode(Int.self, forKey: .ordinal), model: try c.decode(ModelID.self, forKey: .model),
                  candidate: try c.decodeIfPresent(String.self, forKey: .candidate),
                  responseID: try c.decodeIfPresent(String.self, forKey: .responseID),
                  usage: try c.decode(ModelUsage.self, forKey: .usage), outcome: try c.decode(Outcome.self, forKey: .outcome),
                  duration: try c.decode(Duration.self, forKey: .duration))
    }

    /// The longest whole-character prefix within `maximumTextBytes` UTF-8 bytes.
    private static func prefix(of text: String) -> String {
        guard text.utf8.count > maximumTextBytes else { return text }
        var kept = "", bytes = 0
        for character in text {
            bytes += character.utf8.count
            guard bytes <= maximumTextBytes else { break }
            kept.append(character)
        }
        return kept
    }
}
