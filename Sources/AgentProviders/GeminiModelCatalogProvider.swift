import AgentCatalog
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Paginated native models.list. Visibility does not qualify thinking, files, cache or execution.
public struct GeminiModelCatalogProvider: ModelCatalogProvider, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let scope: ModelServiceScope
    private let configuration: GeminiConfiguration
    private let credentials: GeminiCredentials
    private let client: ProviderCatalogHTTPClient
    public var description: String { "GeminiModelCatalogProvider" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["scope": scope]) }
    public init(credentials: GeminiCredentials, baseURL: URL = GeminiProvider.defaultBaseURL,
                serviceInstanceID: String, authorizationScopeID: String,
                transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) throws {
        do {
            configuration = try .init(baseURL: baseURL, streaming: false, thinking: nil, profile: .preserve,
                maximumOutputTokens: nil, maximumRequestBytes: 100_000_000, maximumResponseBytes: 2_000_000,
                authorizationScopeID: authorizationScopeID, caching: .implicit)
            scope = try .init(provider: "gemini", serviceInstanceID: serviceInstanceID, endpointScope: configuration.endpointScope,
                apiDialect: "gemini-generate-content-models", apiVersion: "v1beta", authorizationScopeID: authorizationScopeID)
        } catch { throw ModelCatalogError(kind: .invalidConfiguration) }
        self.credentials = credentials; client = .init(transport: transport)
    }
    public func listModels(_ request: ModelCatalogRequest) async throws -> ModelCatalogPage {
        guard request.pageSize.map({ (1...1000).contains($0) }) ?? true else { throw ModelCatalogError(kind: .invalidConfiguration) }
        var components = URLComponents(url: configuration.baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let size = request.pageSize { items.append(.init(name: "pageSize", value: String(size))) }
        if let cursor = request.cursor {
            guard cursor.utf8.count <= 16_384, let data = Data(base64Encoded: cursor),
                  let decoded = try? JSONDecoder().decode(GeminiCatalogCursor.self, from: data),
                  try ProviderJSON.encode(decoded.scope) == ProviderJSON.encode(scope), decoded.pageSize == request.pageSize, Self.token(decoded.token) else { throw ModelCatalogError(kind: .scopeMismatch) }
            items.append(.init(name: "pageToken", value: decoded.token))
        }
        components.queryItems = items.isEmpty ? nil : items
        var http = URLRequest(url: components.url!); http.httpMethod = "GET"
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        do { try await credentials.authorize(&http) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ModelCatalogError(kind: .authentication) }
        let data = try await client.get(http)
        let root: [String: JSONValue]
        do { root = try ProviderJSON.object(JSONDecoder().decode(JSONValue.self, from: data)) }
        catch { throw ModelCatalogError(kind: .invalidResponse) }
        guard case .array(let models) = root["models"] ?? .array([]) else { throw ModelCatalogError(kind: .invalidResponse) }
        var entries: [ModelCatalogEntry] = [], seen: Set<[UInt8]> = []
        do {
            for value in models {
                let record = try ProviderJSON.object(value)
                guard case .array(let methods) = record["supportedGenerationMethods"], methods.allSatisfy({ if case .string = $0 { return true }; return false }) else { throw ProviderJSON.invalid() }
                guard methods.contains(.string("generateContent")) else { continue }
                let name = try ProviderJSON.string(record["name"])
                guard name.hasPrefix("models/"), GeminiBoundary.slug(String(name.dropFirst(7))), seen.insert(Array(name.utf8)).inserted else { throw ProviderJSON.invalid() }
                let input = try ProviderJSON.count(record["inputTokenLimit"]), output = try ProviderJSON.count(record["outputTokenLimit"])
                let label = try record["displayName"].map(ProviderJSON.string)
                entries.append(.init(model: .init(provider: "gemini", name: String(name.dropFirst(7))), deploymentID: name,
                    serviceScope: scope, displayName: label, capabilities: .unknown, maximumInputTokens: input, maximumOutputTokens: output,
                    metadataComplete: false, sources: [.init(kind: .upstreamAPI, reference: "GET models.list")]))
            }
            let next = try root["nextPageToken"].map(ProviderJSON.string)
            if let next, !Self.token(next) { throw ProviderJSON.invalid() }
            let cursor = try next.map { try ProviderJSON.encode(GeminiCatalogCursor(scope: scope, pageSize: request.pageSize, token: $0)).base64EncodedString() }
            return .init(models: entries, nextCursor: cursor)
        } catch { throw ModelCatalogError(kind: .invalidResponse) }
    }
    private static func token(_ token: String) -> Bool { !token.isEmpty && token.utf8.count <= 8192 && !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
}
private struct GeminiCatalogCursor: Codable { let scope: ModelServiceScope; let pageSize: Int?; let token: String }
