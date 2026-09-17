import AgentModels
import Testing
@testable import AgentAppleProvider

struct AppleFoundationProviderTests {
    @Test func unsupportedRequestsNeverReachNativeGeneration() async throws {
        let probe = GenerationProbe()
        let provider = AppleFoundationProvider { _ in
            await probe.record()
            return .init(kind: .answer, text: "Unexpected", toolCalls: [])
        }
        let requests = [
            ModelRequest(model: .init(provider: "other", name: "on-device"), messages: []),
            .init(model: .init(provider: "apple-foundation", name: "unknown"), messages: []),
            .init(model: AppleFoundationProvider.modelID, messages: [],
                  structuredOutput: .init(name: "result", schema: .object(["type": .string("object")]))),
        ]
        for request in requests {
            await #expect(throws: ModelProviderError.self) { try await collect(provider, request) }
        }
        #expect(await probe.count == 0)
    }

    @Test func contradictoryUnknownAndMalformedProposalsFailBeforePublishingCompletedCalls() async throws {
        let request = ModelRequest(model: AppleFoundationProvider.modelID, messages: [], tools: [
            .init(name: "search", description: "Search", inputSchema: .object(["type": .string("object")])),
        ])
        let plans: [AppleModelPlan] = [
            .init(kind: .answer, text: "Done", toolCalls: [.init(name: "search", argumentsJSON: "{}")]),
            .init(kind: .refusal, text: "No", toolCalls: [.init(name: "search", argumentsJSON: "{}")]),
            .init(kind: .tools, text: "", toolCalls: []),
            .init(kind: .tools, text: "", toolCalls: [.init(name: "missing", argumentsJSON: "{}")]),
            .init(kind: .tools, text: "", toolCalls: [.init(name: "search", argumentsJSON: "{")]),
            .init(kind: .tools, text: "", toolCalls: [.init(name: "search", argumentsJSON: "{\"x\":1,\"x\":2}")]),
        ]
        for plan in plans {
            let provider = AppleFoundationProvider { _ in plan }
            var events: [ModelEvent] = []
            do {
                for try await event in provider.stream(request: request) { events.append(event) }
                Issue.record("Invalid plan must fail")
            } catch { #expect((error as? ModelProviderError)?.kind == .invalidResponse) }
            #expect(!events.contains { if case .toolCallCompleted = $0 { true } else { false } })
        }
    }

    @Test func toolPlansBecomeCompleteCallsAndRefusalsStayRefusals() async throws {
        let raw = "{\"query\":\"cafe\u{301}\"}"
        let provider = AppleFoundationProvider { _ in .init(kind: .tools, text: "", toolCalls: [
            .init(name: "search", argumentsJSON: raw), .init(name: "search", argumentsJSON: "{}"),
        ]) }
        let request = ModelRequest(model: AppleFoundationProvider.modelID, messages: [], tools: [
            .init(name: "search", description: "Search resources", inputSchema: .object(["type": .string("object")])),
        ])
        let response = try await collect(provider, request)
        #expect(response.stopReason == .toolCalls)
        #expect(response.toolCalls.map(\.name) == ["search", "search"])
        #expect(Set(response.toolCalls.map(\.id)).count == 2)
        #expect(response.toolCalls.allSatisfy { $0.completeness == .complete })
        #expect(response.toolCalls.first?.argumentsJSON.utf8.elementsEqual(raw.utf8) == true)
        #expect(provider.descriptor.capabilities.contains(.tools))
        let refusal = AppleFoundationProvider { _ in .init(kind: .refusal, text: "Unavailable for this request", toolCalls: []) }
        #expect(try await collect(refusal, request).stopReason == .refusal)
    }

    @Test func typedAnswerUsesNormalizedEventsWithoutInventingUsage() async throws {
        let provider = AppleFoundationProvider { _ in .init(kind: .answer, text: "Five", toolCalls: []) }
        let request = ModelRequest(model: AppleFoundationProvider.modelID, messages: [.user([.text("Compute")])])
        var events: [ModelEvent] = []
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: request) {
            events.append(event)
            try accumulator.append(event)
        }
        let response = try accumulator.finish()
        #expect(response.content == [.text("Five")])
        #expect(response.stopReason == .endTurn)
        #expect(response.usage == .init())
        #expect(events.count == 3)
        #expect(!provider.descriptor.capabilities.contains(.streaming))
    }

    private func collect(_ provider: AppleFoundationProvider, _ request: ModelRequest) async throws -> ModelResponse {
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: request) { try accumulator.append(event) }
        return try accumulator.finish()
    }
}

private actor GenerationProbe {
    private(set) var count = 0
    func record() { count += 1 }
}
