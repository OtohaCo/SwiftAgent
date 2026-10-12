import AgentCatalog
import AgentModels
import DynamicModelRoutingSupport
import Foundation
import Testing

struct HostIterationPricingTests {
    private let model = ModelID(provider: "anthropic", name: "fictional-model")
    private func scope(_ id: String = "service-a") throws -> ModelServiceScope {
        try .init(provider: "anthropic", serviceInstanceID: id, endpointScope: "https://\(id).invalid", apiDialect: "anthropic")
    }
    private func prices() throws -> ModelPromptPricing {
        try Sub2APIPriceTierFixture.decode(Data(#"{"priceTiers":[{"aboveInputTokens":0,"inclusive":true,"input":"1","output":"2","cachedInput":"0.1"},{"aboveInputTokens":100,"inclusive":true,"input":"10","output":"20","cachedInput":"1"}]}"#.utf8),
            currency: "USD", source: .init(kind: .hostOverride, reference: "fictional-sub2api-per-million", revision: "fixture-v1"))
    }
    private func quote(_ scope: CacheWritePricingScope = .singleCategory, ttl: CacheWriteTTLPrices? = nil) -> HostPricingQuote {
        .init(inputPerMillion: 99, cachedInputPerMillion: nil, cacheWriteScope: scope, outputPerMillion: 99,
              currency: "USD", source: "fictional-write-tariff-v1", asOf: Date(timeIntervalSince1970: 0), cacheWriteTTLPrices: ttl, model: model)
    }
    @Test func eachSamplingSelectsItsOwnTierAndServiceWithFrozenProvenance() throws {
        let pricing = try prices()
        let a = try scope(), b = try scope("service-b")
        let expensive = try ModelPromptPricing(currency: "USD", tiers: [.init(aboveInputTokens: 0, inclusive: true,
            rates: .init(inputPerMillion: 100, outputPerMillion: 100, cachedInputPerMillion: 100))], sources: [])
        let snapshot = try HostIterationPricingSnapshot(revision: "catalog-v1", tariffs: [
            .init(model: model, scope: a, promptPricing: pricing, writeTariff: quote()),
            .init(model: model, scope: b, promptPricing: expensive, writeTariff: quote())])
        let table = try ModelIterationUsage(iterations: [
            .init(ordinal: 0, kind: "compaction", model: model, inputTokens: 99, outputTokens: 1, cachedInputTokens: 0, cacheWriteInputTokens: 0),
            .init(ordinal: 1, kind: "message", model: model, inputTokens: 101, outputTokens: 1, cachedInputTokens: 0, cacheWriteInputTokens: 0)], coverage: .complete)
        let usage = try table.aggregate(), result = snapshot.estimate(usage, serviceScope: a)
        #expect(result.samplings.map(\.selectedTier) == [0, 100])
        #expect(result.total == Decimal(string: "0.001131"))
        #expect(result.total != Decimal(string: "0.00204")) // Incorrect aggregate 200-token selection.
        #expect(result.catalogRevision == "catalog-v1")
        #expect(pricing.sources.first?.revision == "fixture-v1")
        #expect(snapshot.estimate(usage, serviceScope: b).total == Decimal(string: "0.0202"))
        #expect(snapshot.estimate(usage, serviceScope: try scope("unknown")).total == nil)
        #expect(pricing.tier(forInputTokens: 99)?.aboveInputTokens == 0)
        #expect(pricing.tier(forInputTokens: 100)?.aboveInputTokens == 100)
        #expect(pricing.tier(forInputTokens: 101)?.aboveInputTokens == 100)
    }
    @Test func ttlAndMissingWriteCategoriesReuseExistingHonestHostCalculation() throws {
        let pricing = try prices(), scope = try scope()
        let table = try ModelIterationUsage(iterations: [.init(ordinal: 0, kind: "message", model: model,
            inputTokens: 100, outputTokens: 2, cachedInputTokens: 10, cacheWriteInputTokens: 5,
            cacheWriteTTL: .init(fiveMinuteTokens: 2, oneHourTokens: 3))], coverage: .complete)
        let snapshot = try HostIterationPricingSnapshot(revision: "ttl-v1", tariffs: [.init(model: model, scope: scope,
            promptPricing: pricing, writeTariff: quote(.ttlBreakdown, ttl: .init(fiveMinutePerMillion: 5, oneHourPerMillion: 7)))])
        #expect(snapshot.estimate(try table.aggregate(), serviceScope: scope).total == Decimal(string: "0.000931"))
        let missing = try HostIterationPricingSnapshot(revision: "missing-v1", tariffs: [.init(model: model, scope: scope,
            promptPricing: pricing, writeTariff: quote())])
        let unknown = missing.estimate(try table.aggregate(), serviceScope: scope)
        #expect(unknown.total == nil && unknown.samplings.first?.unknownReason == "missingWritePrice")
        let zero = try ModelIterationUsage(iterations: [.init(ordinal: 0, kind: "message", model: model,
            inputTokens: 99, outputTokens: 1, cachedInputTokens: 0, cacheWriteInputTokens: 0)], coverage: .complete)
        #expect(missing.estimate(try zero.aggregate(), serviceScope: scope).total == Decimal(string: "0.000101"))
        let ordinary = try HostIterationPricingSnapshot(revision: "ordinary-v1", tariffs: [.init(model: model, scope: scope,
            promptPricing: pricing, writeTariff: quote(.noSeparateCharge))])
        let unspecifiedWrites = try ModelIterationUsage(iterations: [.init(ordinal: 0, kind: "message", model: model,
            inputTokens: 99, outputTokens: 1, cachedInputTokens: 0)], coverage: .complete)
        #expect(ordinary.estimate(try unspecifiedWrites.aggregate(), serviceScope: scope).total == Decimal(string: "0.000101"))
    }
    @Test func missingOrDifferentSamplingModelAndPartialCoverageNeverGuessTotal() throws {
        let scope = try scope()
        let snapshot = try HostIterationPricingSnapshot(revision: "v1", tariffs: [.init(model: model, scope: scope, promptPricing: prices(), writeTariff: quote())])
        let table = try ModelIterationUsage(iterations: [
            .init(ordinal: 0, kind: "compaction", model: model, inputTokens: 99, outputTokens: 1, cachedInputTokens: 0, cacheWriteInputTokens: 0),
            .init(ordinal: 1, kind: "advisor", model: nil, inputTokens: 1, outputTokens: 1, cachedInputTokens: 0, cacheWriteInputTokens: 0),
            .init(ordinal: 2, kind: "future", model: .init(provider: "anthropic", name: "other"), inputTokens: 1, outputTokens: 1)], coverage: .complete)
        let value = snapshot.estimate(try table.aggregate(), serviceScope: scope)
        #expect(value.total == nil && value.knownSubtotal == Decimal(string: "0.000101"))
        #expect(value.samplings[1].unknownReason == "missing_sampling_model")
        #expect(value.samplings[2].unknownReason == "missing_service_scoped_tariff")
        let partial = try ModelIterationUsage(iterations: [table.iterations[0]], coverage: .partial)
        #expect(snapshot.estimate(try partial.aggregate(), serviceScope: scope).total == nil)
        #expect(snapshot.estimate(.init(inputTokens: 200, outputTokens: 2), serviceScope: scope).total == nil)
    }
    @Test func mapperUsesExactDecimalAndPreservesUnknownVersusZero() throws {
        let exact = "0.12345678901234567890123456789012345678"
        let source = ModelCatalogSource(kind: .hostOverride, revision: "fictional")
        let stringWire = Data("{\"priceTiers\":[{\"aboveInputTokens\":0,\"inclusive\":true,\"input\":\"\(exact)\",\"output\":\"0\"}]}".utf8)
        let strings = try Sub2APIPriceTierFixture.decode(stringWire, currency: "USD", source: source)
        #expect(strings.tiers[0].rates.inputPerMillion == Decimal(string: exact))
        #expect(strings.tiers[0].rates.outputPerMillion == 0 && strings.tiers[0].rates.cachedInputPerMillion == nil)
        let numericWire = Data("{\"priceTiers\":[{\"aboveInputTokens\":0,\"inclusive\":true,\"input\":\(exact),\"output\":0}]}".utf8)
        #expect(try Sub2APIPriceTierFixture.decode(numericWire, currency: "USD", source: source).tiers == strings.tiers)
        #expect(try JSONDecoder().decode(ModelPromptPricing.self, from: JSONEncoder().encode(strings)) == strings)
        let tooPrecise = Data(#"{"priceTiers":[{"aboveInputTokens":0,"inclusive":true,"input":0.123456789012345678901234567890123456789012345678901,"output":0}]}"#.utf8)
        #expect(throws: (any Error).self) { try Sub2APIPriceTierFixture.decode(tooPrecise, currency: "USD", source: source) }
    }
}
