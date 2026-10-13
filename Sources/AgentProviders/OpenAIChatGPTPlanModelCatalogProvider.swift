import AgentCatalog
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Current selected-account catalog for the explicit ChatGPT-plan route. Server ordering is preserved.
/// The Host must partition catalog caches by authorizationScopeID and invalidate on account changes.
public struct OpenAIChatGPTPlanModelCatalogProvider: ModelCatalogProvider,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let scope: ModelServiceScope
    private let credentials: OpenAIChatGPTPlanCredentials
    private let client: ProviderCatalogHTTPClient
    private static let endpoint = URL(string: "https://api.openai.com/v1/models")!
    public var description: String { "OpenAIChatGPTPlanModelCatalogProvider" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["scope": scope]) }

    public init(credentials: OpenAIChatGPTPlanCredentials, serviceInstanceID: String,
                authorizationScopeID: String,
                transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) throws {
        scope = try .init(provider: "openai", serviceInstanceID: serviceInstanceID,
            endpointScope: Self.endpoint.absoluteString, apiDialect: "openai-chatgpt-plan-models", apiVersion: "v1",
            authorizationScopeID: authorizationScopeID)
        self.credentials = credentials; client = .init(transport: transport)
    }

    public func listModels(_ request: ModelCatalogRequest) async throws -> ModelCatalogPage {
        guard request.cursor == nil, request.pageSize == nil else { throw ModelCatalogError(kind: .invalidConfiguration) }
        let token: String
        do { token = try await credentials.token() }
        catch is CancellationError { throw CancellationError() }
        catch { throw ModelCatalogError(kind: .authentication) }
        var http = URLRequest(url: Self.endpoint); http.httpMethod = "GET"
        http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        try Task.checkCancellation()
        let data = try await client.get(http)
        let list: PlanModelList
        do { list = try JSONDecoder().decode(PlanModelList.self, from: data) }
        catch { throw ModelCatalogError(kind: .invalidResponse) }
        var entries: [ModelCatalogEntry] = [], seen: Set<[UInt8]> = []
        for record in list.models where record.visibility == "list" {
            guard let slug = record.slug, let label = record.displayName,
                  !slug.isEmpty, slug == slug.trimmingCharacters(in: .whitespacesAndNewlines),
                  !slug.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(Array(slug.utf8)).inserted else { throw ModelCatalogError(kind: .invalidResponse) }
            entries.append(.init(model: .init(provider: "openai", name: slug), deploymentID: slug,
                serviceScope: scope, displayName: label, capabilities: .unknown, metadataComplete: false,
                sources: [.init(kind: .upstreamAPI, reference: "GET /v1/models (ChatGPT plan)")]))
        }
        return .init(models: entries)
    }
}

private struct PlanModelList: Decodable { let models: [PlanModelRecord] }
private struct PlanModelRecord: Decodable {
    let slug: String?
    let displayName: String?
    let visibility: String?
    enum CodingKeys: String, CodingKey { case slug, visibility; case displayName = "display_name" }
}
