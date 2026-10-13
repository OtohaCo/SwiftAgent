import AgentModels
import Foundation

enum ChatGPTPlanFailure {
    /// Only known codes can affect classification; vendor text never leaves this boundary.
    static func classify(code: String) -> ModelProviderError? {
        let kind: ModelProviderError.Kind
        let reason: ModelProviderError.Diagnostic.Reason
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            kind = .rateLimited; reason = .subscriptionSharingUsageLimitExceeded
        case "subscription_sharing_usage_unavailable":
            kind = .unavailable; reason = .subscriptionSharingUsageUnavailable
        case "subscription_sharing_user_unavailable":
            kind = .unavailable; reason = .serverFailure
        case "subscription_sharing_invalid_user", "invalid_token", "token_expired":
            kind = .authentication; reason = .serverFailure
        case "subscription_sharing_user_not_eligible", "subscription_sharing_route_not_supported",
             "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            kind = .permissionDenied; reason = .serverFailure
        case "subscription_sharing_unsupported_capability":
            kind = .unsupportedCapability; reason = .serverFailure
        default: return nil
        }
        return .init(kind: kind, message: "ChatGPT-plan request failed (\(reason.rawValue)).",
                     diagnostic: .init(stage: .server, reason: reason))
    }

    static func http(_ status: Int, headers: [String: String],
                     events: inout AsyncThrowingStream<ProviderHTTPEvent, Error>.Iterator) async throws -> ModelProviderError {
        let fallback = ProviderHTTPFailure.classify(status, headers: headers)
        var body = Data()
        do {
            while let event = try await events.next() {
                try Task.checkCancellation()
                guard case .data(let chunk) = event,
                      chunk.count <= ProviderHTTPFailure.maximumErrorBodyBytes - body.count else { return fallback }
                body.append(chunk)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return fallback }
        try Task.checkCancellation()
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .object(let fields) = root, case .object(let error) = fields["error"],
              case .string(let code) = error["code"], let mapped = classify(code: code) else { return fallback }
        return .init(kind: mapped.kind, message: "ChatGPT-plan HTTP request failed (\(status)): \(mapped.message)",
                     retryAfter: fallback.retryAfter, diagnostic: mapped.diagnostic)
    }
}
