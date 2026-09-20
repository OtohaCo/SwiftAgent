import AgentCatalog
import AgentModels
import Foundation
import Testing

struct ModelCatalogContractTests {
    @Test func openModelIdentityAndUnknownCapabilitiesRemainDistinct() throws {
        let scope = try ModelServiceScope(
            provider: "fixture",
            serviceInstanceID: "staging-west",
            endpointScope: "https://models.example.test/v1",
            apiDialect: "responses",
            apiVersion: "v1",
            authorizationScopeID: "project-a"
        )
        let entry = ModelCatalogEntry(
            model: .init(provider: "fixture", name: "future-model-2030"),
            deploymentID: "future-model-2030",
            serviceScope: scope,
            displayName: "Future Model",
            capabilities: .unknown,
            reasoningControls: [],
            maximumInputTokens: nil,
            maximumOutputTokens: nil,
            sources: [.init(kind: .upstreamAPI, fetchedAt: Date(timeIntervalSince1970: 10))]
        )

        #expect(entry.model.name == "future-model-2030")
        #expect(entry.capabilities.tools == .unknown)
        #expect(entry.capabilities.reasoning == .unknown)
        #expect(entry.capabilities.configurableReasoning == .unknown)
        #expect(entry.reasoningControls.isEmpty)
        #expect(entry.maximumInputTokens == nil)
    }

    @Test func reasoningAbilityAndIndependentControlsAreNotCollapsedIntoOneLevel() throws {
        let controls = [
            ModelReasoningControlDescriptor(
                parameter: "output_config.effort",
                kind: .effort,
                support: .supported,
                allowedValues: ["low", "high", "future-value"],
                valuesAreExhaustive: false,
                executability: .executable
            ),
            ModelReasoningControlDescriptor(
                parameter: "thinking.type",
                kind: .thinkingMode,
                support: .supported,
                allowedValues: ["adaptive", "enabled"],
                valuesAreExhaustive: true,
                executability: .executable
            ),
            ModelReasoningControlDescriptor(
                parameter: "thinking.budget_tokens",
                kind: .tokenBudget,
                support: .supported,
                integerRange: .init(minimum: 1_024, maximum: 32_000),
                executability: .executable
            ),
        ]

        #expect(controls.map(\.kind) == [.effort, .thinkingMode, .tokenBudget])
        #expect(controls[0].allowedValues?.contains("future-value") == true)
        #expect(controls[0].valuesAreExhaustive == false)
        #expect(controls[2].integerRange == .init(minimum: 1_024, maximum: 32_000))
    }

    @Test func hostManifestIsVersionedAndScopedWithoutMakingUnknownCapabilitiesSupported() async throws {
        let scope = try ModelServiceScope(
            provider: "custom",
            serviceInstanceID: "self-hosted-a",
            endpointScope: "https://models.example.test/v1",
            apiDialect: "custom-responses",
            apiVersion: "2026-09"
        )
        let entry = ModelCatalogEntry(
            model: .init(provider: "custom", name: "future-model"),
            deploymentID: "future-model",
            serviceScope: scope,
            sources: [.init(kind: .hostOverride, revision: "manifest-7")]
        )
        let manifest = try ModelCatalogManifest(
            scope: scope,
            revision: "manifest-7",
            models: [entry],
            generatedAt: Date(timeIntervalSince1970: 100)
        )
        let provider = StaticModelCatalogProvider(manifest: manifest)

        let page = try await provider.listModels(.init())

        #expect(provider.manifestRevision == "manifest-7")
        #expect(page.models.map(\.model.name) == ["future-model"])
        #expect(page.models[0].capabilities == .unknown)
    }
}
