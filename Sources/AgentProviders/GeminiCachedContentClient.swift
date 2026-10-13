import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Host-invoked cache lifecycle outside a Run. No automatic creation, deletion, replay or fallback.
/// Returned bindings witness exact local contents, instructions, tools, endpoint, model and account scope.
public struct GeminiCachedContentClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let credentials: GeminiCredentials
    private let transport: any ProviderHTTPTransport
    private let configuration: GeminiConfiguration
    public var description: String { "GeminiCachedContentClient" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    public init(credentials: GeminiCredentials, baseURL: URL = GeminiProvider.defaultBaseURL,
                authorizationScopeID: String, maximumRequestBytes: Int = 100_000_000,
                transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) throws {
        self.credentials = credentials; self.transport = transport
        configuration = try .init(baseURL: baseURL, streaming: false, thinking: nil, profile: .preserve,
            maximumOutputTokens: nil, maximumRequestBytes: maximumRequestBytes, maximumResponseBytes: 2_000_000,
            authorizationScopeID: authorizationScopeID, caching: .implicit)
    }
    /// Prefix must be closed with complete tool-result pairing. Core budgets still count its full tokens.
    public func create(prefix: ModelRequest, ttl: Duration = .seconds(3600)) async throws -> GeminiCachedContentBinding {
        try Task.checkCancellation()
        let components = ttl.components
        guard components.attoseconds == 0, (1...604_800).contains(components.seconds) else { throw GeminiBoundary.invalidRequest() }
        let context = try GeminiRequestEncoder.context(prefix, configuration: configuration)
        var fields: [String: JSONValue] = ["model": .string("models/" + prefix.model.name), "contents": .array(context.contents), "ttl": .string("\(components.seconds)s")]
        if let system = context.system { fields["systemInstruction"] = system }
        if let tools = context.tools { fields["tools"] = tools }
        let body = try ProviderJSON.encode(JSONValue.object(fields))
        guard body.count <= configuration.maximumRequestBytes else { throw GeminiBoundary.invalidRequest() }
        let source = try ProviderJSON.encode(prefix.messages)
        let witness = try GeminiCachedContentBinding.witness(context: context, prefixCount: context.contents.count)
        let data = try await dispatch(method: "POST", resource: "cachedContents", body: body)
        let result: [String: JSONValue]
        do { result = try ProviderJSON.object(JSONDecoder().decode(JSONValue.self, from: data)) }
        catch { throw ProviderJSON.invalid() }
        let name = try ProviderJSON.string(result["name"]), expiry = try ProviderJSON.string(result["expireTime"])
        guard Self.resource(name), result["model"] == .string("models/" + prefix.model.name),
              let date = Self.date(expiry), date > Date() else { throw ProviderJSON.invalid() }
        return .init(resourceName: name, expiresAt: date, model: prefix.model, endpoint: configuration.endpointScope,
            authorizationScopeID: configuration.authorizationScopeID, sourceMessages: source, contextWitness: witness,
            prefixCount: context.contents.count, prefixMessageCount: prefix.messages.count)
    }
    /// Only bindings from this endpoint/account may be deleted; deletion does not alter history.
    public func delete(_ binding: GeminiCachedContentBinding) async throws {
        guard GeminiBoundary.exact(binding.endpoint, configuration.endpointScope),
              GeminiBoundary.exact(binding.authorizationScopeID, configuration.authorizationScopeID), Self.resource(binding.resourceName) else { throw GeminiBoundary.unsupported() }
        _ = try await dispatch(method: "DELETE", resource: binding.resourceName, body: nil)
    }
    private func dispatch(method: String, resource: String, body: Data?) async throws -> Data {
        let url = configuration.baseURL.appendingPathComponent(resource)
        var http = URLRequest(url: url); http.httpMethod = method; http.httpBody = body
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await credentials.authorize(&http); try Task.checkCancellation()
        var data = Data(), header = false
        for try await event in transport.stream(http) {
            try Task.checkCancellation()
            switch event {
            case .response(let status, let headers):
                guard !header else { throw ProviderJSON.invalid() }; header = true
                guard (200...299).contains(status) else { throw ProviderHTTPFailure.classify(status, headers: headers) }
            case .data(let chunk):
                guard header, chunk.count <= configuration.maximumResponseBytes - data.count else { throw ProviderJSON.invalid() }; data.append(chunk)
            }
        }
        guard header else { throw ProviderJSON.invalid() }; try Task.checkCancellation(); return data
    }
    static func resource(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == "cachedContents" && GeminiBoundary.slug(String(parts[1]))
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }; formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
    }
}
