import AgentModels
import AgentProviders
import Foundation
import Testing

struct NativeRouteOwnerTests {
    @Test func compactAndWitnessUseValidatedMutationOwnerWithoutOpaqueHistory() async throws {
        let a = NativeOwnerFixture(name: "a", failGeneration: true), b = NativeOwnerFixture(name: "b", failGeneration: false)
        let route = try ModelProviderRoute(id: "owner-fixture", candidates: [.init(id: "a", provider: a), .init(id: "b", provider: b)], policy: .init(maxAttempts: 2))
        let request = ModelRequest(model: .init(provider: "owner-fixture", name: "model"), messages: [.user([.text("source")])], sessionID: UUID(), runID: UUID())
        var first = ModelEventAccumulator()
        for try await event in route.stream(request: request) { try first.append(event) }
        #expect(try first.finish().content.isEmpty) // No opaque state from the selected candidate.
        await route.markMutationBoundary(sessionID: request.sessionID!, runID: request.runID!)
        #expect(try route.nativeContextRequestDigest(request: request, compactionMode: .openAIStandalone) == "b")
        for try await _ in route.compact(request: .init(request: request, mode: .openAIStandalone, operationID: UUID(), invocationID: UUID())) {}
        #expect(await a.compactCount == 0)
        #expect(await b.compactCount == 1)
        await route.clearMutationBoundary(sessionID: request.sessionID!, runID: request.runID!)
        #expect(try route.nativeContextRequestDigest(request: request, compactionMode: .openAIStandalone) == "a")
    }
}

private actor NativeOwnerFixture: ModelProviderNativeContextWitness {
    nonisolated let name: String
    nonisolated let failGeneration: Bool
    nonisolated var descriptor: ModelProviderDescriptor { .init(id: "owner-fixture", capabilities: [.tools, .multiTurn]) }
    nonisolated var compactionModes: Set<ModelCompactionMode> { [.openAIStandalone] }
    private(set) var compactCount = 0
    init(name: String, failGeneration: Bool) { self.name = name; self.failGeneration = failGeneration }
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            if self.failGeneration { throw ModelProviderError(kind: .unavailable, message: "fixture unavailable") }
            let info = ResponseInfo(id: self.name, model: request.model)
            let call = ToolCall(id: .init(rawValue: "call"), name: "tool", argumentsJSON: "{}", completeness: .complete)
            try emit(.responseStarted(info)); try emit(.toolCallStarted(call.id, name: call.name))
            try emit(.toolCallArgumentsDelta(call.id, "{}")); try emit(.toolCallCompleted(call))
            try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
        }
    }
    nonisolated func nativeContextRequestDigest(request: ModelRequest, compactionMode: ModelCompactionMode?) throws -> String { name }
    nonisolated func validateCompaction(request: ModelCompactionRequest) throws {}
    nonisolated func compact(request: ModelCompactionRequest) -> AsyncThrowingStream<ModelCompactionEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.recordCompact()
                continuation.yield(.completed(.init(info: .init(id: name, model: request.request.model), continuation: nil, usage: .init())))
                continuation.finish()
            }
        }
    }
    private func recordCompact() { compactCount += 1 }
}
