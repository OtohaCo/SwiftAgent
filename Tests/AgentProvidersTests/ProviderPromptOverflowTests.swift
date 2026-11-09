import AgentModels
import Foundation
import Testing
@testable import AgentProviders

struct ProviderPromptOverflowTests {
    @Test func providerUsesConfiguredEventLimit() async throws {
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }), maximumSSEEventBytes: 32,
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [geminiTextFixture]))
        do {
            for try await _ in provider.stream(request: geminiRequest) {}
            Issue.record("Expected frame limit")
        } catch let error as ModelProviderError {
            #expect(error.diagnostic?.reason == .eventTooLarge)
        }
    }

    @Test(arguments: ["gemini", "deepseek"])
    func boundedHTTPBodyClassifiesOnlyPromptOverflow(provider: String) async throws {
        let message = provider == "gemini"
            ? "The input token count (200) exceeds the maximum number of tokens allowed (100)."
            : "This model's maximum context length is 100 tokens. However, you requested 200 tokens."
        let overflow = Data(#"{"error":{"message":"\#(message)","type":"invalid_request_error","status":"INVALID_ARGUMENT"}}"#.utf8)
        for (body, expected) in [(overflow, ModelProviderError.Kind.contextWindowExceeded),
                                 (Data(#"{"error":{"message":"invalid temperature"}}"#.utf8), .invalidRequest),
                                 (overflow + Data(repeating: 32, count: 65_536), .invalidRequest)] {
            let transport = FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body], chunkBytes: 17, status: 400)
            let adapter: any ModelProvider = try provider == "gemini"
                ? GeminiProvider(credentials: .init(apiKey: { "key" }), transport: transport)
                : DeepSeekResponsesProvider(apiKey: "key", transport: transport)
            let request = ModelRequest(model: .init(provider: provider, name: "fixture"), messages: [.user([.text("Hi")])])
            do {
                for try await _ in adapter.stream(request: request) {}
                Issue.record("Expected failure")
            } catch let error as ModelProviderError {
                #expect(error.kind == expected)
                #expect(!error.message.contains(message))
            }
        }
    }
}
