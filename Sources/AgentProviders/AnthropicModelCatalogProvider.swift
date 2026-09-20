import AgentCatalog
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AnthropicModelCatalogProvider: ModelCatalogDetailProvider {
    public let scope: ModelServiceScope
    private let apiKey: String
    private let endpoint: URL
    private let apiVersion: String
    private let client: ProviderCatalogHTTPClient

    public init(
        apiKey: String,
        endpoint: URL? = nil,
        apiVersion: String = "2023-06-01",
        serviceInstanceID: String,
        authorizationScopeID: String? = nil,
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
    ) throws {
        try validateCatalogCredential(apiKey)
        try validateCatalogCredential(apiVersion)
        guard let endpoint = endpoint ?? URL(string: "https://api.anthropic.com/v1/models") else {
            throw ModelCatalogError(kind: .invalidConfiguration)
        }
        try validateCatalogEndpoint(endpoint)
        self.scope = try .init(
            provider: "anthropic",
            serviceInstanceID: serviceInstanceID,
            endpointScope: catalogEndpointScope(endpoint),
            apiDialect: "anthropic-models",
            apiVersion: apiVersion,
            authorizationScopeID: authorizationScopeID
        )
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.apiVersion = apiVersion
        self.client = .init(transport: transport)
    }

    public func listModels(_ request: ModelCatalogRequest) async throws -> ModelCatalogPage {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ModelCatalogError(kind: .invalidConfiguration)
        }
        var query = components.queryItems ?? []
        if let cursor = request.cursor { query.append(.init(name: "after_id", value: cursor)) }
        if let pageSize = request.pageSize {
            guard pageSize > 0 else { throw ModelCatalogError(kind: .invalidConfiguration) }
            query.append(.init(name: "limit", value: String(pageSize)))
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ModelCatalogError(kind: .invalidConfiguration) }
        let response: AnthropicModelList = try await decode(url: url)
        guard !response.hasMore || response.lastID?.isEmpty == false else {
            throw ModelCatalogError(kind: .invalidResponse)
        }
        return .init(models: response.data.map(entry), nextCursor: response.hasMore ? response.lastID : nil)
    }

    public func modelDetails(deploymentID: String) async throws -> ModelCatalogEntry {
        let response: AnthropicModelRecord = try await decode(
            url: catalogDetailURL(endpoint: endpoint, deploymentID: deploymentID)
        )
        guard response.id == deploymentID else { throw ModelCatalogError(kind: .invalidResponse) }
        return entry(response)
    }

    private func decode<Value: Decodable>(url: URL) async throws -> Value {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await client.get(request)
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw ModelCatalogError(kind: .invalidResponse) }
    }

    private func entry(_ record: AnthropicModelRecord) -> ModelCatalogEntry {
        let effort = reasoningControl(
            record.capabilities?.effort,
            parameter: "output_config.effort",
            kind: .effort,
            knownValues: nil
        )
        let thinking = reasoningControl(
            record.capabilities?.thinking,
            parameter: "thinking.type",
            kind: .thinkingMode,
            knownValues: ["adaptive", "enabled"]
        )
        var controls = [effort, thinking].compactMap { $0 }
        let thinkingValues = record.capabilities?.thinking?.values ?? record.capabilities?.thinking?.types ?? []
        if record.capabilities?.thinking?.supported == true, thinkingValues.contains("enabled") {
            let budgetRange = record.maximumOutputTokens.flatMap { maximum -> ModelIntegerRange? in
                guard maximum > 1_024 else { return nil }
                return .init(minimum: 1_024, maximum: maximum - 1)
            }
            controls.append(.init(
                parameter: "thinking.budget_tokens",
                kind: .tokenBudget,
                support: .supported,
                integerRange: budgetRange,
                requires: ["thinking.type": .string("enabled")],
                executability: budgetRange == nil ? .adapterUpgradeRequired : .executable
            ))
        }
        let configurable: ModelCatalogSupport
        if controls.contains(where: { $0.support == .supported }) { configurable = .supported }
        else if record.capabilities?.effort?.supported == false,
                record.capabilities?.thinking?.supported == false { configurable = .unsupported }
        else { configurable = .unknown }
        let reasoning: ModelCatalogSupport = configurable == .supported ? .supported : .unknown
        return .init(
            model: .init(provider: scope.provider, name: record.id),
            deploymentID: record.id,
            serviceScope: scope,
            displayName: record.displayName,
            capabilities: .init(
                structuredOutput: support(record.capabilities?.structuredOutputs?.supported),
                reasoning: reasoning,
                configurableReasoning: configurable
            ),
            reasoningControls: controls,
            maximumInputTokens: record.maximumInputTokens,
            maximumOutputTokens: record.maximumOutputTokens,
            metadataComplete: false,
            sources: [.init(kind: .upstreamAPI, reference: "GET /v1/models")]
        )
    }

    private func reasoningControl(
        _ capability: AnthropicReasoningCapability?,
        parameter: String,
        kind: ModelReasoningControlKind,
        knownValues: Set<String>?
    ) -> ModelReasoningControlDescriptor? {
        guard let capability else { return nil }
        let values = capability.values ?? capability.types
        let executability: ModelCatalogExecutability
        if capability.supported != true {
            executability = .unknown
        } else if let knownValues, values?.contains(where: { !knownValues.contains($0) }) == true {
            executability = .adapterUpgradeRequired
        } else {
            executability = .executable
        }
        return .init(
            parameter: parameter,
            kind: kind,
            support: support(capability.supported),
            allowedValues: values,
            valuesAreExhaustive: false,
            executability: executability
        )
    }

    private func support(_ value: Bool?) -> ModelCatalogSupport {
        switch value {
        case true: .supported
        case false: .unsupported
        case nil: .unknown
        }
    }
}

private struct AnthropicModelList: Decodable {
    let data: [AnthropicModelRecord]
    let hasMore: Bool
    let lastID: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}

private struct AnthropicModelRecord: Decodable {
    let id: String
    let displayName: String?
    let capabilities: AnthropicCatalogCapabilities?
    let maximumInputTokens: Int?
    let maximumOutputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case id, capabilities
        case displayName = "display_name"
        case maximumInputTokens = "max_input_tokens"
        case maximumOutputTokens = "max_tokens"
    }
}

private struct AnthropicCatalogCapabilities: Decodable {
    let effort: AnthropicReasoningCapability?
    let thinking: AnthropicReasoningCapability?
    let structuredOutputs: AnthropicBooleanCapability?

    private enum CodingKeys: String, CodingKey {
        case effort, thinking
        case structuredOutputs = "structured_outputs"
    }
}

private struct AnthropicReasoningCapability: Decodable {
    let supported: Bool?
    let values: [String]?
    let types: [String]?
}

private struct AnthropicBooleanCapability: Decodable { let supported: Bool? }
