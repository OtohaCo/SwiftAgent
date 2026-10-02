import AgentModels
import Foundation

enum ProviderHTTPFailure {
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
                     retryAfter: retry)
    }

    /// Classifies a non-200 response. For a status that can carry a context
    /// overflow, reads the rest of the bounded body from `events` first; the
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
        guard contextOverflowStatuses.contains(status) else { return failure }
        var body = Data()
        do {
            while let event = try await events.next() {
                try Task.checkCancellation()
                guard case .data(let chunk) = event else { return failure }
                body.append(chunk)
                guard body.count <= maximumErrorBodyBytes else { return failure }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failure
        }
        try Task.checkCancellation()
        guard ProviderContextOverflow.isOverflow(httpBody: body, signals: signals) else { return failure }
        return .init(kind: .contextWindowExceeded,
                     message: "Provider HTTP request failed (\(status)): the request exceeds the model's context window.")
    }
}
