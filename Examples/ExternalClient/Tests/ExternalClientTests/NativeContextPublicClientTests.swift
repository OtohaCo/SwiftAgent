import AgentCatalog
import AgentCore
import AgentModels
import AgentProviders
import Foundation
import NativeContextFixtureSupport
import Testing

struct NativeContextPublicClientTests {
    @Test func legacyFactoriesKeepExactNonthrowingFunctionSignatures() throws {
        let catalog: (ModelID, String, ModelServiceScope, String?, [String], ModelID?, ModelCatalogCapabilities,
                      [ModelReasoningControlDescriptor], Int?, Int?, Bool, [ModelCatalogSource], [ModelCatalogConflict]) -> ModelCatalogEntry = ModelCatalogEntry.init
        let scope = try ModelServiceScope(provider: "fixture", serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")
        let entry = catalog(.init(provider: "fixture", name: "model"), "fixture", scope, nil, [], nil, .unknown, [], nil, nil, false, [], [])
        #expect(entry.promptPricing == nil && entry.compaction == nil)
        let continuation: (ModelID, String, Data) -> ModelProviderContinuation = ModelProviderContinuation.init
        #expect(continuation(entry.model, "fixture", Data()).requestBoundary == nil)
        let response: (ResponseInfo, [ModelContent], [ToolCall], ModelUsage, StopReason) -> ModelResponse = ModelResponse.init
        let usage: (Int?, Int?, Int?, Int?, Int?) -> ModelUsage = ModelUsage.init
        #expect(response(.init(id: "fixture", model: entry.model), [], [], usage(1, 2, 0, 0, 0), .endTurn).usage.iterationUsage == nil)
        let compact: (ModelCompactionMode, AgentModelBinding?, ContinuousClock.Instant?) async throws -> AgentCompactionOperation = try Agent(model: entry.model, provider: LegacyProvider()).makeSession().compact
        _ = compact
    }

    @Test func nativeHostFlowUsesOnlyPublicSDKAndRealHTTPFixtures() async throws {
        #expect(try await NativeContextHostExample.run().contains("no live calls"))
    }
}

private struct LegacyProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.streaming, .multiTurn])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
