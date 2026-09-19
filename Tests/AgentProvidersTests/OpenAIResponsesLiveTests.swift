import AgentModels
import Foundation
import Testing
import AgentProviders

struct OpenAIResponsesLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFT_AGENT_OPENAI_LIVE"] == "1"))
    func realCloudTextResponseUsesTheResponsesAPI() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["OPENAI_API_KEY"],
              let model = environment["OPENAI_MODEL"] else {
            throw ModelProviderError(kind: .authentication, message: "Opted-in cloud credentials are unavailable.")
        }
        let resolved = environment["OPENAI_RESOLVED_MODEL"]
        let provider = if let resolved, !resolved.isEmpty {
            try OpenAIResponsesProvider(apiKey: key, resolvedModelIDsByAlias: [model: resolved])
        } else {
            try OpenAIResponsesProvider(apiKey: key)
        }
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(
            model: .init(provider: "openai", name: model),
            messages: [.user([.text("Reply with exactly: SwiftAgent live")])]
        )) { try accumulator.append(event) }
        #expect(try accumulator.finish().stopReason == .endTurn)
    }
}
