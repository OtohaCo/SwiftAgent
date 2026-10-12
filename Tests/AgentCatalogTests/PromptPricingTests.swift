import Foundation
import Testing
import AgentModels
@testable import AgentCatalog

@Suite struct PromptPricingTests {
    @Test func wholeSamplingTierBoundaryAndExactDecimalRoundTrip() throws {
        let base = try ModelPromptPriceRates(inputPerMillion: Decimal(string: "0.123456789012345678901"), outputPerMillion: 2, cachedInputPerMillion: 0)
        let premium = try ModelPromptPriceRates(inputPerMillion: 3, outputPerMillion: 5, cachedInputPerMillion: nil)
        for inclusive in [true, false] {
            let pricing = try ModelPromptPricing(currency: "USD", tiers: [
                .init(aboveInputTokens: 0, inclusive: true, rates: base),
                .init(aboveInputTokens: 100, inclusive: inclusive, rates: premium)
            ], sources: [.init(kind: .hostOverride, revision: "fictional-v1")])
            #expect(pricing.tier(forInputTokens: 99)?.rates == base)
            #expect(pricing.tier(forInputTokens: 100)?.rates == (inclusive ? premium : base))
            #expect(pricing.tier(forInputTokens: 101)?.rates == premium)
            #expect(pricing.tier(forInputTokens: -1) == nil)
            #expect(try JSONDecoder().decode(ModelPromptPricing.self, from: JSONEncoder().encode(pricing)) == pricing)
            #expect(premium.cachedInputPerMillion == nil)
            #expect(base.cachedInputPerMillion == 0)
        }
    }
    @Test func malformedConstructedAndDecodedRatesAndTiersReject() throws {
        #expect(throws: (any Error).self) { try ModelPromptPriceRates(inputPerMillion: -1) }
        let rates = try ModelPromptPriceRates(inputPerMillion: 1)
        #expect(throws: (any Error).self) { try ModelPromptPricing(currency: "USD", tiers: [.init(aboveInputTokens: 0, inclusive: false, rates: rates)], sources: []) }
        #expect(throws: (any Error).self) { try ModelPromptPricing(currency: "USD", tiers: [.init(aboveInputTokens: 0, inclusive: true, rates: rates), .init(aboveInputTokens: 0, inclusive: true, rates: rates)], sources: []) }
        let bad = Data(#"{"currency":"USD","tiers":[{"aboveInputTokens":0,"inclusive":true,"rates":{"inputPerMillion":"-0.1"}}],"sources":[]}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ModelPromptPricing.self, from: bad) }
    }
    @Test func precisionOverflowAndInvalidCompactionMetadataReject() throws {
        for amount in ["0.123456789012345678901234567890123456789012345678901", "1e999", "1oops"] {
            let data = Data("{\"inputPerMillion\":\"\(amount)\"}".utf8)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ModelPromptPriceRates.self, from: data) }
        }
        let exponent = try JSONDecoder().decode(ModelPromptPriceRates.self, from: Data(#"{"inputPerMillion":"1.2300e2"}"#.utf8))
        #expect(exponent.inputPerMillion == 123)
        #expect(throws: (any Error).self) { try ModelCompactionDescriptor(mode: .anthropicOnDemand, support: .supported, minimumTriggerInputTokens: 50000, sources: [], executability: .executable) }
        #expect(throws: (any Error).self) { try ModelCompactionDescriptor(mode: .openAIAutomatic, support: .supported, minimumTriggerInputTokens: -1, sources: [], executability: .executable) }
    }

    @Test func catalogOldManifestAndUnknownModeRemainHonest() throws {
        let scope = try ModelServiceScope(provider: "custom", serviceInstanceID: "one", endpointScope: "fixture", apiDialect: "responses")
        let old = ModelCatalogEntry(model: .init(provider: "custom", name: "fictional"), deploymentID: "one", serviceScope: scope, metadataComplete: true, sources: [])
        let decoded = try JSONDecoder().decode(ModelCatalogEntry.self, from: JSONEncoder().encode(old))
        #expect(decoded.promptPricing == nil)
        #expect(decoded.compaction == nil)
        let future = ModelCompactionMode(rawValue: "future_kind")
        let metadata = try ModelCompactionCatalog(support: .supported, modesAreExhaustive: false, modes: [.init(mode: future, support: .supported, sources: [], executability: .adapterUpgradeRequired)])
        #expect(try JSONDecoder().decode(ModelCompactionCatalog.self, from: JSONEncoder().encode(metadata)) == metadata)
    }
}
