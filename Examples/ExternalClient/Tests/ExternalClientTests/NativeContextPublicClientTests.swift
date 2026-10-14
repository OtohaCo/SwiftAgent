import AgentCatalog
import AgentCore
import AgentDecisions
import AgentJournalFileStore
import AgentJevProvider
import AgentModels
import AgentProviders
import AgentUsage
import Foundation
import NativeContextFixtureSupport
import Testing

struct NativeContextPublicClientTests {
    @Test func legacyFactoriesKeepExactNonthrowingFunctionSignatures() throws {
        let legacyAnthropic: (String, URL?, Int, AnthropicThinking, any ProviderHTTPTransport) throws -> AnthropicProvider = AnthropicProvider.init
        _ = legacyAnthropic
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
        let oldCreate: (URL, String, JournalMaintenancePolicy, Bool, Bool, Bool, Bool, Bool, Bool) throws -> AgentJournal = AgentIncrementalJournal.create
        let newCreate: (URL, String, JournalMaintenancePolicy, Bool) throws -> AgentJournal = AgentIncrementalJournal.create
        let upgrade: (URL, JournalMaintenancePolicy) throws -> AgentJournal = AgentIncrementalJournal.upgradeForContextHandoff
        let nativeCreate: (URL, String, JournalMaintenancePolicy, Bool, Bool, Bool, Bool, Bool, Bool, Bool) throws -> AgentJournal = AgentIncrementalJournal.create
        let oldQueue: (AgentModelBinding, AgentCapabilityBinding, UInt64?) -> AgentFollowUpConfiguration = AgentFollowUpConfiguration.init
        let controlledQueue: (AgentModelBinding, AgentCapabilityBinding, UInt64?, AgentRunContextControls) -> AgentFollowUpConfiguration = AgentFollowUpConfiguration.init
        _ = (oldCreate, nativeCreate, newCreate, upgrade, oldQueue, controlledQueue)
    }

    @Test func incompleteNativeHandoffUsesOnlyPublicAPI() async throws {
        try await NativeContextHostExample.incompleteOrdinaryHandoff()
    }

    @Test func exactHandoffSignaturesRemainUsable() throws {
        let model = ModelID(provider: "fixture", name: "model")
        let session = try Agent(model: model, provider: LegacyProvider()).makeSession()
        let old: (AgentModelBinding, AgentCapabilityBinding?, Bool, ContinuousClock.Instant?) async throws -> AgentContextHandoffOperation = session.handoffToOrdinary
        let new: (AgentModelBinding, AgentCapabilityBinding?, Bool, Bool, ContinuousClock.Instant?) async throws -> AgentContextHandoffOperation = session.handoffToOrdinary
        let factory: (URL, String, JournalMaintenancePolicy) throws -> AgentJournal = AgentIncrementalJournal.createForIncompleteContextHandoff
        _ = (old, new, factory)
    }

    @Test func thinkingContinuesOnlyInTheNewAuthorityEpoch() async throws {
        try await NativeContextHostExample.thinkingAcrossOrdinaryHandoff()
    }

    @Test func durableOrdinaryHandoffUsesOnlyPublicAPI() async throws {
        try await NativeContextHostExample.ordinaryHandoff()
    }

    @Test(arguments: [false, true])
    func queuedRemindersUsePublicResolverAndRealHTTPEncoding(_ cancel: Bool) async throws {
        try await NativeContextHostExample.queuedReminders(cancelBeforeDispatch: cancel)
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
