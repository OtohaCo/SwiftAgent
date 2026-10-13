import AgentCatalog
import AgentModels
import AgentProviders
import Foundation
import Testing

struct ChatGPTPlanContractTests {
    @Test func planBodyUsesDeveloperInstructionsNamespacedToolsAndNoOutputLimit() async throws {
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(apiKey: "fixture-token",
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
        let request = ModelRequest(model: .init(provider: "openai", name: "fixture"),
            messages: [.system("Keep the constraint"), .developer("Keep ordering"), .user([.text("Hi")])],
            tools: [.init(name: "calculator", description: "Add", inputSchema: .object(["type": .string("object")]))])
        for try await _ in provider.stream(request: request) {}
        let http = try #require(await probe.requests.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(http.httpBody))
        #expect(body["store"] == .bool(false))
        #expect(body["stream"] == .bool(true))
        #expect(body["max_output_tokens"] == nil)
        guard case .array(let input) = body["input"], case .array(let tools) = body["tools"] else {
            Issue.record("Expected input/tools arrays"); return
        }
        #expect(input[0]["role"] == .string("developer"))
        #expect(input[0]["content"] == .string("Keep the constraint"))
        #expect(tools[0]["type"] == .string("namespace"))
        #expect(tools[0]["name"] == .string("swiftagent"))
    }

    @Test func planStreamFailuresHaveHostUsableKinds() async throws {
        for (code, kind) in [("subscription_sharing_usage_limit_exceeded", ModelProviderError.Kind.rateLimited),
                             ("subscription_sharing_usage_unavailable", .unavailable)] {
            let body = providerNamedSSE([("response.failed",
                "{\"type\":\"response.failed\",\"response\":{\"id\":\"failed\",\"model\":\"fixture\",\"status\":\"failed\",\"error\":{\"code\":\"\(code)\",\"message\":\"private secret\"}}}")])
            let provider = try OpenAIResponsesProvider(apiKey: "fixture-token",
                transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body]))
            do {
                for try await _ in provider.stream(request: .init(model: .init(provider: "openai", name: "fixture"), messages: [.user([.text("Hi")])])) {}
                Issue.record("Failed stream must throw")
            } catch let error as ModelProviderError {
                #expect(error.kind == kind)
                #expect(!error.message.contains("private secret"))
            }
        }
    }

    @Test func planCatalogFiltersVisibilityInServerOrder() async throws {
        let body = Data(#"{"models":[{"slug":"second","display_name":"Second","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hide"},{"slug":"first","display_name":"First","visibility":"list"}]}"#.utf8)
        let provider = try OpenAIModelCatalogProvider(apiKey: "fixture-token", serviceInstanceID: "account-fixture",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body]))
        let page = try await provider.listModels(.init())
        #expect(page.models.map(\.model.name) == ["second", "first"])
        #expect(page.models.map(\.displayName) == ["Second", "First"])
    }
}
