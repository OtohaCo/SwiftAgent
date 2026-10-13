import AgentModels

/// Only documented structured codes affect classification; arbitrary service text stays private.
enum GeminiFailure {
    static func stream(_ value: JSONValue) -> ModelProviderError {
        guard case .object(let fields) = value else { return ProviderJSON.invalid() }
        let statuses: [String: Int] = ["INVALID_ARGUMENT": 400, "UNAUTHENTICATED": 401, "PERMISSION_DENIED": 403,
            "NOT_FOUND": 404, "RESOURCE_EXHAUSTED": 429, "INTERNAL": 500, "UNAVAILABLE": 503, "DEADLINE_EXCEEDED": 504]
        let code = try? ProviderJSON.count(fields["code"])
        let status: Int?
        if let code { status = [400, 401, 403, 404, 408, 429, 500, 502, 503, 504].contains(code) ? code : nil }
        else if case .string(let name) = fields["status"] { status = statuses[name] }
        else { status = nil }
        guard let status else { return ProviderJSON.invalid() }
        if let declared = fields["status"] {
            guard case .string(let name) = declared, statuses[name] == status else { return ProviderJSON.invalid() }
        }
        return ProviderHTTPFailure.classify(status, headers: [:])
    }
}
