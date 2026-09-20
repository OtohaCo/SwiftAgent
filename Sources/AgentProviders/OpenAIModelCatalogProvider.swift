import AgentCatalog
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAIModelCatalogProvider: ModelCatalogDetailProvider {
    public let scope: ModelServiceScope
    private let apiKey: String
    private let endpoint: URL
    private let client: ProviderCatalogHTTPClient

    public init(
        apiKey: String,
        endpoint: URL? = nil,
        serviceInstanceID: String,
        authorizationScopeID: String? = nil,
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
    ) throws {
        try validateCatalogCredential(apiKey)
        guard let endpoint = endpoint ?? URL(string: "https://api.openai.com/v1/models") else {
            throw ModelCatalogError(kind: .invalidConfiguration)
        }
        try validateCatalogEndpoint(endpoint)
        self.scope = try .init(
            provider: "openai",
            serviceInstanceID: serviceInstanceID,
            endpointScope: catalogEndpointScope(endpoint),
            apiDialect: "openai-models",
            apiVersion: "v1",
            authorizationScopeID: authorizationScopeID
        )
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.client = .init(transport: transport)
    }

    public func listModels(_ request: ModelCatalogRequest) async throws -> ModelCatalogPage {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var query: [URLQueryItem] = []
        if let cursor = request.cursor {
            guard !cursor.isEmpty else { throw ModelCatalogError(kind: .invalidConfiguration) }
            query.append(.init(name: "after", value: cursor))
        }
        if let pageSize = request.pageSize {
            guard pageSize > 0 else { throw ModelCatalogError(kind: .invalidConfiguration) }
            query.append(.init(name: "limit", value: String(pageSize)))
        }
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw ModelCatalogError(kind: .invalidConfiguration) }

        let response: OpenAIModelList = try await decode(url: url)
        guard response.hasMore != true || response.lastID?.isEmpty == false else {
            throw ModelCatalogError(kind: .invalidResponse)
        }
        return .init(
            models: response.data.map(entry),
            nextCursor: response.hasMore == true ? response.lastID : nil
        )
    }

    public func modelDetails(deploymentID: String) async throws -> ModelCatalogEntry {
        let response: OpenAIModelRecord = try await decode(url: catalogDetailURL(endpoint: endpoint, deploymentID: deploymentID))
        guard response.id == deploymentID else { throw ModelCatalogError(kind: .invalidResponse) }
        return entry(response)
    }

    private func decode<Value: Decodable>(url: URL) async throws -> Value {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await client.get(request)
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw ModelCatalogError(kind: .invalidResponse) }
    }

    private func entry(_ record: OpenAIModelRecord) -> ModelCatalogEntry {
        .init(
            model: .init(provider: scope.provider, name: record.id),
            deploymentID: record.id,
            serviceScope: scope,
            displayName: nil,
            capabilities: .unknown,
            metadataComplete: false,
            sources: [.init(kind: .upstreamAPI, reference: "GET /v1/models")]
        )
    }
}

private struct OpenAIModelList: Decodable {
    let data: [OpenAIModelRecord]
    let hasMore: Bool?
    let lastID: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}
private struct OpenAIModelRecord: Decodable { let id: String }
