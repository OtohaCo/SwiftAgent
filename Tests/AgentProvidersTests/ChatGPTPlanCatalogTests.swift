import AgentCatalog
import AgentModels
import AgentProviders
import Foundation
import Testing

struct ChatGPTPlanCatalogTests {
    @Test func sameAccountSourceRotatesAcrossCatalogAndInference() async throws {
        let tokens = PlanRotatingTokens(), probe = ProviderRequestProbe()
        let credentials = OpenAIChatGPTPlanCredentials(accessToken: { await tokens.next() })
        let catalog = try OpenAIChatGPTPlanModelCatalogProvider(credentials: credentials,
            serviceInstanceID: "plan", authorizationScopeID: "account-A",
            transport: FixtureHTTPTransport(probe: probe, bodies: [Data(#"{"models":[{"slug":"fixture","display_name":"Fixture","visibility":"list"}]}"#.utf8)]))
        let page = try await catalog.listModels(.init())
        #expect(page.models[0].model == planRequest.model)
        #expect(page.models[0].displayName == "Fixture")
        #expect(page.models[0].capabilities == .unknown && !page.models[0].metadataComplete)
        #expect(catalog.scope.apiDialect == "openai-chatgpt-plan-models")
        #expect(catalog.scope.authorizationScopeID == "account-A")
        #expect(await probe.requests[0].url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(await probe.requests[0].httpMethod == "GET")
        let provider = OpenAIChatGPTPlanProvider(credentials: credentials,
            transport: FixtureHTTPTransport(probe: probe, bodies: [Data(), openAITextFixture]))
        for try await _ in provider.stream(request: planRequest) {}
        #expect(await probe.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer fixture-1", "Bearer fixture-2"])
        #expect(!String(reflecting: catalog).contains("fixture-1"))
    }

    @Test func paginationRejectsBeforeCredentialSourceAndTransport() async throws {
        let tokens = PlanRotatingTokens(), probe = ProviderRequestProbe()
        let catalog = try OpenAIChatGPTPlanModelCatalogProvider(credentials: .init(accessToken: { await tokens.next() }),
            serviceInstanceID: "plan", authorizationScopeID: "A", transport: FixtureHTTPTransport(probe: probe, bodies: []))
        for request in [ModelCatalogRequest(cursor: "cursor"), .init(pageSize: 10)] {
            await #expect(throws: ModelCatalogError(kind: .invalidConfiguration)) { try await catalog.listModels(request) }
        }
        #expect(await tokens.count == 0)
        #expect(await probe.requests.isEmpty)
    }

    @Test func malformedMissingVisibleFieldsDuplicateAndOrdinaryShapesRefuse() async throws {
        for body in [#"{"data":[{"id":"fixture"}]}"#,
                     #"{"models":[{"visibility":"list","display_name":"Missing slug"}]}"#,
                     #"{"models":[{"visibility":"list","slug":"x","display_name":""}]}"#,
                     #"{"models":[{"visibility":"list","slug":"x","display_name":"X"},{"visibility":"list","slug":"x","display_name":"Y"}]}"#,
                     "{"] {
            let catalog = try OpenAIChatGPTPlanModelCatalogProvider(credentials: .init(accessToken: { "fixture-token" }),
                serviceInstanceID: "plan", authorizationScopeID: "A", transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(body.utf8)]))
            await #expect(throws: ModelCatalogError(kind: .invalidResponse)) { try await catalog.listModels(.init()) }
        }
        let hidden = try OpenAIChatGPTPlanModelCatalogProvider(credentials: .init(accessToken: { "fixture-token" }),
            serviceInstanceID: "plan", authorizationScopeID: "A", transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(#"{"models":[{"visibility":"hide"}]}"#.utf8)]))
        #expect(try await hidden.listModels(.init()).models.isEmpty)
    }

    @Test func oversizedCatalogAndAuthenticationFailuresAreBounded() async throws {
        for (status, body, kind) in [(200, Data(repeating: 0x20, count: 2 * 1_024 * 1_024 + 1), ModelCatalogError.Kind.responseTooLarge),
                                    (401, Data("fixture-secret".utf8), .authentication),
                                    (403, Data("fixture-secret".utf8), .permissionDenied)] {
            let catalog = try OpenAIChatGPTPlanModelCatalogProvider(credentials: .init(accessToken: { "fixture-secret" }),
                serviceInstanceID: "plan", authorizationScopeID: "A", transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body], status: status))
            do { _ = try await catalog.listModels(.init()); Issue.record("Expected catalog failure") }
            catch let error as ModelCatalogError { #expect(error.kind == kind); #expect(!String(reflecting: error).contains("fixture-secret")) }
        }
    }
}
