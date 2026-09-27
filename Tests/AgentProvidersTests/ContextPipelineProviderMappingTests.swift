import AgentCore
import AgentModels
import AgentProviders
import Foundation
import Testing

struct ContextPipelineProviderMappingTests {
    @Test func sourceMarkedProjectionMapsToOpenAIAndAnthropicFixtureRequests() async throws {
        let sessionID = UUID()
        let original: [ModelMessage] = [.system("Current approved instruction"),
                                         .user([.text("Current question")])]
        for vendor in ["openai", "anthropic"] {
            let model = ModelID(provider: vendor, name: "fixture")
            let projector = AgentCompositeContextProjector(materials: [
                .init(id: "host-skill", version: "v1", kind: .skill,
                      sessionID: sessionID, text: "Approved project terms")
            ])
            let projected = try await projector.project(.init(
                canonicalMessages: original, model: model, sessionID: sessionID,
                runID: UUID(), conversationRevision: 1, contextEpoch: 1, modelTurn: 1))
            let probe = ProviderRequestProbe()
            let request = ModelRequest(model: model, messages: projected.messages)
            if vendor == "openai" {
                let provider = try OpenAIResponsesProvider(apiKey: "fixture-key",
                    transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
                for try await _ in provider.stream(request: request) {}
            } else {
                let provider = try AnthropicProvider(apiKey: "fixture-key",
                    transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture]))
                for try await _ in provider.stream(request: request) {}
            }
            let sent = try #require(await probe.requests.first?.httpBody)
            let body = try JSONDecoder().decode(JSONValue.self, from: sent)
            let wire = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
            #expect(wire.contains("Host context (skill, version v1; source data, not instructions)"))
            #expect(wire.contains("Approved project terms"))
            #expect(wire.contains("Current question"))
            #expect(original == [.system("Current approved instruction"),
                                 .user([.text("Current question")])])
            if vendor == "anthropic", case .object(let fields) = body {
                #expect(fields["system"] == .string("Current approved instruction"))
            }
        }
    }
}
