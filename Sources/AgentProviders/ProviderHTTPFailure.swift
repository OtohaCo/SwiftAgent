import AgentModels
import Foundation

enum ProviderHTTPFailure {
    static func streamEndedEarly() -> ModelProviderError {
        .init(kind: .transport, message: "Provider stream ended before completion.",
              diagnostic: .init(stage: .streamLifecycle, reason: .streamEndedEarly))
    }

    /// Statuses on which a supported provider reports a context overflow in the
    /// body: 400 (OpenAI, Anthropic, llama.cpp server) and 500 (LM Studio).
    static let contextOverflowStatuses: Set<Int> = [400, 500]
    /// Error bodies are read only up to this size; a longer body is classified by status.
    static let maximumErrorBodyBytes = 64 * 1_024

    static func classify(_ status: Int, headers: [String: String], now: Date = Date()) -> ModelProviderError {
        let kind: ModelProviderError.Kind
        switch status {
        case 401: kind = .authentication
        case 403: kind = .permissionDenied
        case 408: kind = .transport
        case 429: kind = .rateLimited
        case 500...599: kind = .unavailable
        case 400...499: kind = .invalidRequest
        default: kind = .invalidResponse
        }
        let retry = headers.first { $0.key.lowercased() == "retry-after" }.flatMap { ProviderRetryAfter.parse($0.value, now: now) }
        return .init(kind: kind, message: "Provider HTTP request failed (\(status)).",
                     retryAfter: retry, diagnostic: .init(stage: .server, reason: .httpFailure))
    }

    /// Classifies a non-200 response using its bounded error body; the
    /// body is never copied into the error. Cancellation is rethrown; a body
    /// that is too long, malformed or interrupted leaves the status classification.
    static func classify(
        _ status: Int,
        headers: [String: String],
        remainingBody events: inout AsyncThrowingStream<ProviderHTTPEvent, Error>.Iterator,
        signals: ProviderContextOverflow.Signals,
        now: Date = Date()
    ) async throws -> ModelProviderError {
        let failure = classify(status, headers: headers, now: now)
        guard (400...599).contains(status) else { return failure }
        var body = Data()
        do {
            while let event = try await events.next() {
                try Task.checkCancellation()
                guard case .data(let chunk) = event else { return failure }
                guard chunk.count <= maximumErrorBodyBytes - body.count else { return failure }
                body.append(chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return failure
        }
        try Task.checkCancellation()
        return classify(status, headers: headers, body: body, signals: signals, now: now)
    }

    static func classify(_ status: Int, headers: [String: String], body: Data,
                         signals: ProviderContextOverflow.Signals, now: Date = Date()) -> ModelProviderError {
        let failure = classify(status, headers: headers, now: now)
        guard body.count <= maximumErrorBodyBytes else { return failure }
        if let object = try? ProviderJSON.decode(String(decoding: body, as: UTF8.self)),
           case .object(let error)? = object["error"] {
            let codes = [error["code"], error["type"], error["status"]]
            let kind: ModelProviderError.Kind?
            if status == 429 && codes.contains(.string("insufficient_quota")) { kind = .quotaExhausted }
            else if [400, 404].contains(status) && codes.contains(.string("model_not_found")) { kind = .modelNotFound }
            else if [429, 503, 529].contains(status) && codes.contains(.string("overloaded_error")) { kind = .overloaded }
            else { kind = nil }
            if let kind {
                return .init(kind: kind, message: "Provider HTTP request failed (\(status)).",
                    retryAfter: failure.retryAfter, diagnostic: failure.diagnostic)
            }
        }
        guard contextOverflowStatuses.contains(status),
              ProviderContextOverflow.isOverflow(httpBody: body, signals: signals) else { return failure }
        return .init(kind: .contextWindowExceeded,
                     message: "Provider HTTP request failed (\(status)): the request exceeds the model's context window.")
    }
}
