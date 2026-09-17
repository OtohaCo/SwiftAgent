import AgentModels

enum ProviderHTTPFailure {
    static func classify(_ status: Int, headers: [String: String]) -> ModelProviderError {
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
        let retry = headers.first { $0.key.lowercased() == "retry-after" }.flatMap { Int($0.value) }
        return .init(kind: kind, message: "Provider HTTP request failed (\(status)).",
                     retryAfter: retry.flatMap { $0 >= 0 ? .seconds($0) : nil })
    }
}
