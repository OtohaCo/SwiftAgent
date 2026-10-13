import AgentModels
import Foundation
import Testing
@testable import AgentProviders

struct GeminiContractTests {
    @Test func nativeHTTPUsesModelPathAndHeaderCredentials() async throws {
        let probe = ProviderRequestProbe()
        let provider = try GeminiProvider(credentials: .init(apiKey: { "fixture-key" }),
            transport: FixtureHTTPTransport(probe: probe, bodies: [geminiTextFixture]))
        var replay = ModelEventAccumulator()
        for try await event in provider.stream(request: geminiRequest) { try replay.append(event) }
        #expect(try replay.finish().stopReason == .endTurn)
        let http = try #require(await probe.requests.first)
        #expect(http.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/fixture:streamGenerateContent?alt=sse")
        #expect(http.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-key")
        #expect(!http.url!.absoluteString.contains("fixture-key"))
    }
}
let geminiRequest = ModelRequest(model: .init(provider: "gemini", name: "fixture"), messages: [.user([.text("Hi")])])
let geminiTextFixture = Data(#"data: {"responseId":"r","candidates":[{"index":0,"content":{"role":"model","parts":[{"text":"Hello"}]},"finishReason":"STOP"}]}"#.utf8) + Data("\n\n".utf8)
