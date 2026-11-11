import AgentModels
import AgentProviders
import Foundation
import Testing

struct RouteContinuationMetadataTests {
    @Test func routePreservesRequestBoundaryAndThinkingLineage() async throws {
        let digest = String(repeating: "a", count: 64)
        let model = ModelID(provider: "metadata", name: "fixture")
        let source = ModelNativeContextSource(sessionID: UUID(), canonicalMessageCount: 1, lastMessageID: UUID(),
            canonicalDigest: String(digest.prefix(16)), requestDigest: digest, projectionID: "identity", projectionVersion: "1", previousCheckpointID: nil)
        let boundary = try ModelProviderRequestBoundary(id: UUID(), source: source, invocationID: UUID(),
            origin: .init(providerID: "metadata", serviceInstanceID: "fixture", endpointScope: "fixture", apiDialect: "fixture", configurationRevision: "1"),
            rootConfigurationDigest: String(digest.prefix(16)), tools: [], conversationControls: nil,
            witness: .init(prefixDigest: digest, rootToolsDigest: digest, qualificationScope: digest))
        let lineage = try ModelPreservedThinkingLineage(boundary: boundary, parentCheckpointID: nil, tailMessageCount: 1, tailDigest: String(digest.prefix(16)), replacements: [])
        let state = ModelProviderContinuation(model: model, format: "fixture", payload: Data("opaque".utf8), origin: boundary.origin,
            contextTransition: nil, requestBoundary: boundary)
        let provider = MetadataProvider(state: state, lineage: lineage)
        let route = try ModelProviderRoute(id: "metadata", candidates: [.init(id: "owner", provider: provider)])
        let request = ModelRequest(model: model, messages: [.user([.text("Hello")])])
        var accumulator = ModelEventAccumulator()
        for try await event in route.stream(request: request) { try accumulator.append(event) }
        let response = try accumulator.finish()
        let wrapped = try #require(response.content.compactMap { if case .providerContinuation(let value) = $0 { return value }; return nil }.first)
        #expect(wrapped.requestBoundary == boundary)
        let transition = ModelNativeContextTransition(mode: .anthropicOnDemand, source: source, replayPosition: 0,
            invocationID: UUID(), responseID: "fixture")
        let checkpoint = ModelNativeContextCheckpoint(id: UUID(), generation: 1, continuation: wrapped, transition: transition,
            rootConfigurationDigest: String(digest.prefix(16)), toolBaseline: [], usage: .init(), canonicalTailStart: 0, preservedThinkingLineage: lineage)
        let next = ModelRequest(model: model, messages: request.messages, nativeContext: checkpoint)
        #expect(try route.nativeContextRequestDigest(request: next, compactionMode: nil) == lineage.tailDigest)
    }
}

private struct MetadataProvider: ModelProviderNativeContextWitness {
    let state: ModelProviderContinuation
    let lineage: ModelPreservedThinkingLineage
    var descriptor: ModelProviderDescriptor { .init(id: "metadata", capabilities: [.multiTurn, .streaming]) }
    var compactionModes: Set<ModelCompactionMode> { [.anthropicOnDemand] }
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "fixture", model: request.model)
            try emit(.responseStarted(info))
            try emit(.providerContinuation(state))
            try emit(.responseCompleted(.init(info: info, content: [.providerContinuation(state)], stopReason: .endTurn)))
        }
    }
    func nativeContextRequestDigest(request: ModelRequest, compactionMode: ModelCompactionMode?) throws -> String {
        #expect(request.nativeContext?.continuation == state)
        #expect(request.nativeContext?.preservedThinkingLineage == lineage)
        return lineage.tailDigest
    }
    func validateCompaction(request: ModelCompactionRequest) throws {}
    func compact(request: ModelCompactionRequest) -> AsyncThrowingStream<ModelCompactionEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
