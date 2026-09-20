import AgentCatalog
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DeepSeekModelCatalogProvider: ModelCatalogProvider {
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
        guard let endpoint = endpoint ?? URL(string: "https://api.deepseek.com/models") else {
            throw ModelCatalogError(kind: .invalidConfiguration)
        }
        try validateCatalogEndpoint(endpoint)
        self.scope = try .init(
            provider: "deepseek",
            serviceInstanceID: serviceInstanceID,
            endpointScope: catalogEndpointScope(endpoint),
            apiDialect: "deepseek-models",
            apiVersion: "v1",
            authorizationScopeID: authorizationScopeID
        )
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.client = .init(transport: transport)
    }

    public func listModels(_ request: ModelCatalogRequest) async throws -> ModelCatalogPage {
        guard request.cursor == nil else { throw ModelCatalogError(kind: .invalidConfiguration) }
        var http = URLRequest(url: endpoint)
        http.httpMethod = "GET"
        http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await client.get(http)
        let response: DeepSeekModelList
        do { response = try JSONDecoder().decode(DeepSeekModelList.self, from: data) }
        catch { throw ModelCatalogError(kind: .invalidResponse) }
        return .init(models: response.data.map { record in
            .init(
                model: .init(provider: scope.provider, name: record.id),
                deploymentID: record.id,
                serviceScope: scope,
                capabilities: .unknown,
                metadataComplete: false,
                sources: [.init(kind: .upstreamAPI, reference: "GET /models")]
            )
        })
    }
}

private struct DeepSeekModelList: Decodable { let data: [DeepSeekModelRecord] }
private struct DeepSeekModelRecord: Decodable { let id: String }
