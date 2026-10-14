import AgentCatalog
import AgentModels
import AgentProviders
import Foundation
import Testing

/// Compiles against public modules, including the exact stored initializer signatures.
struct ProviderInitializerCompatibilityTests {
    @Test func prePrivateNetworkInitializersKeepExactFunctionTypesAndDefaults() throws {
        let catalog: (String, URL?, String, String?, any ProviderHTTPTransport) throws -> OpenAIModelCatalogProvider =
            OpenAIModelCatalogProvider.init(apiKey:endpoint:serviceInstanceID:authorizationScopeID:transport:)
        let configuration: (URL, String, LocalResponsesAuthentication, Int, ModelCapabilities, String?, OpenAIResponsesPromptCaching?) -> LocalResponsesProvider.Configuration =
            LocalResponsesProvider.Configuration.init(baseURL:model:authentication:maximumOutputTokens:capabilities:promptCacheKey:promptCaching:)
        // Unqualified references must also resolve from their original function types.
        let inferredCatalog: (String, URL?, String, String?, any ProviderHTTPTransport) throws -> OpenAIModelCatalogProvider =
            OpenAIModelCatalogProvider.init
        let inferredConfiguration: (URL, String, LocalResponsesAuthentication, Int, ModelCapabilities, String?, OpenAIResponsesPromptCaching?) -> LocalResponsesProvider.Configuration =
            LocalResponsesProvider.Configuration.init
        let privateCatalog: (String, URL?, String, String?, any ProviderHTTPTransport, Bool) throws -> OpenAIModelCatalogProvider =
            OpenAIModelCatalogProvider.init(apiKey:endpoint:serviceInstanceID:authorizationScopeID:transport:allowsPrivateNetworkHTTP:)
        let privateConfiguration: (URL, String, LocalResponsesAuthentication, Int, ModelCapabilities, String?, OpenAIResponsesPromptCaching?, Bool) -> LocalResponsesProvider.Configuration =
            LocalResponsesProvider.Configuration.init(baseURL:model:authentication:maximumOutputTokens:capabilities:promptCacheKey:promptCaching:allowsBearerOverPrivateNetworkHTTP:)

        let transport = URLSessionProviderHTTPTransport()
        _ = try inferredCatalog("fixture-key", nil, "fixture", nil, transport)
        let address = URL(string: "http://192.168.1.10:1234/v1")!
        #expect(throws: ModelCatalogError.self) {
            _ = try catalog("fixture-key", address.appendingPathComponent("models"), "fixture", nil, transport)
        }
        let old = configuration(address, "fixture-model", .bearer("fixture-key"), 4_096, [], nil, nil)
        #expect(old.allowsBearerOverPrivateNetworkHTTP == false)
        #expect(throws: ModelProviderError.self) { _ = try LocalResponsesProvider(configuration: old) }
        let inferred = inferredConfiguration(address, "fixture-model", .none, 4_096, [], nil, nil)
        #expect(inferred.allowsBearerOverPrivateNetworkHTTP == false)
        _ = try privateCatalog("fixture-key", address.appendingPathComponent("models"), "fixture", nil, transport, true)
        let optedIn = privateConfiguration(address, "fixture-model", .bearer("fixture-key"), 4_096, [], nil, nil, true)
        #expect(optedIn.allowsBearerOverPrivateNetworkHTTP == true)
        _ = try LocalResponsesProvider(configuration: optedIn)
    }
}
