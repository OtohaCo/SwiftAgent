import AgentCatalog
import AgentModels
import Foundation

/// A fixture mapper for the documented Otoha sub2api priceTiers field shape.
/// Values are already currency units per million tokens, with group multipliers
/// applied by the source service. No SDK/Host product thresholds are inferred.
public enum Sub2APIPriceTierFixture {
    public static func decode(_ data: Data, currency: String, source: ModelCatalogSource) throws -> ModelPromptPricing {
        let wire = try JSONDecoder().decode(Wire.self, from: quoteExactRateNumbers(data))
        return try .init(currency: currency, tiers: wire.priceTiers.map {
            .init(aboveInputTokens: $0.aboveInputTokens, inclusive: $0.inclusive,
                  rates: try .init(inputPerMillion: $0.input, outputPerMillion: $0.output, cachedInputPerMillion: $0.cachedInput))
        }, sources: [source])
    }
    /// Preserve numeric price lexemes before Foundation can round Decimal values.
    /// The full rewritten document is still decoded and validated by JSONDecoder.
    private static func quoteExactRateNumbers(_ data: Data) throws -> Data {
        guard data.count <= 4_194_304 else { throw HostIterationPricingError.invalidPriceJSON }
        let bytes = Array(data)
        var output: [UInt8] = [], index = 0, pendingKey: String?
        let rateKeys: Set<String> = ["input", "output", "cachedInput"]
        func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 {
                let start = index; index += 1
                var closed = false
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { index += 1; closed = true; break }
                    index += 1
                }
                guard closed, index <= bytes.count else { throw HostIterationPricingError.invalidPriceJSON }
                let token = Data(bytes[start..<index])
                var next = index
                while next < bytes.count, whitespace(bytes[next]) { next += 1 }
                pendingKey = next < bytes.count && bytes[next] == 58 ? try JSONDecoder().decode(String.self, from: token) : nil
                output.append(contentsOf: token)
            } else if byte == 45 || (48...57).contains(byte) {
                let start = index
                while index < bytes.count, (48...57).contains(bytes[index]) || [43, 45, 46, 69, 101].contains(bytes[index]) { index += 1 }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                guard token.range(of: #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else {
                    throw HostIterationPricingError.invalidPriceJSON
                }
                if let key = pendingKey, rateKeys.contains(key) {
                    output.append(34); output.append(contentsOf: bytes[start..<index]); output.append(34)
                } else { output.append(contentsOf: bytes[start..<index]) }
                pendingKey = nil
            } else {
                output.append(byte); index += 1
                if !whitespace(byte), byte != 58 { pendingKey = nil }
            }
        }
        return Data(output)
    }
    private struct Wire: Decodable { let priceTiers: [Tier] }
    private struct Tier: Decodable {
        let aboveInputTokens: Int
        let inclusive: Bool
        let input: Decimal?
        let output: Decimal?
        let cachedInput: Decimal?
        enum CodingKeys: String, CodingKey { case aboveInputTokens, inclusive, input, output, cachedInput }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func rate(_ key: CodingKeys) throws -> Decimal? {
                guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
                if let text = try? c.decode(String.self, forKey: key) {
                    // Reuse the SDK's exact decimal validation, including no truncation.
                    let mapped = try JSONEncoder().encode(["inputPerMillion": text])
                    return try JSONDecoder().decode(ModelPromptPriceRates.self, from: mapped).inputPerMillion
                }
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Rates must retain their exact numeric text.")
            }
            aboveInputTokens = try c.decode(Int.self, forKey: .aboveInputTokens)
            inclusive = try c.decode(Bool.self, forKey: .inclusive)
            input = try rate(.input); output = try rate(.output); cachedInput = try rate(.cachedInput)
        }
    }
}

/// The Host freezes one catalog revision and its verified write tariff before
/// observing an invocation. Identical model names in different services stay apart.
public struct HostSamplingTariff: Sendable {
    public let model: ModelID
    public let scope: ModelServiceScope
    public let promptPricing: ModelPromptPricing
    public let writeTariff: HostPricingQuote
    public init(model: ModelID, scope: ModelServiceScope, promptPricing: ModelPromptPricing, writeTariff: HostPricingQuote) {
        self.model = model; self.scope = scope; self.promptPricing = promptPricing; self.writeTariff = writeTariff
    }
}

public struct HostSamplingCost: Sendable {
    public let ordinal: Int
    public let kind: String
    public let model: ModelID?
    public let selectedTier: Int?
    public let value: Decimal?
    public let unknownReason: String?
}

public struct HostInvocationCost: Sendable {
    public let catalogRevision: String
    public let currency: String?
    public let samplings: [HostSamplingCost]
    /// Nil if coverage, identity, rates, cache classification, or currency is unknown.
    public let total: Decimal?
    /// Sum of known rows only. This is explicitly a partial amount, never a total.
    public let knownSubtotal: Decimal
}

public struct HostIterationPricingSnapshot: Sendable {
    public let revision: String
    public let tariffs: [HostSamplingTariff]
    public init(revision: String, tariffs: [HostSamplingTariff]) throws {
        guard !revision.isEmpty, tariffs.enumerated().allSatisfy({ index, tariff in
            tariff.model.provider == tariff.scope.provider && !tariffs.prefix(index).contains {
                $0.model == tariff.model && $0.scope == tariff.scope
            }
        }) else { throw HostIterationPricingError.invalidSnapshot }
        self.revision = revision; self.tariffs = tariffs
    }
    public func estimate(_ usage: ModelUsage, serviceScope: ModelServiceScope) -> HostInvocationCost {
        let table = usage.iterationUsage
        var currency: String?, subtotal = Decimal(0), allKnown = table?.coverage == .complete && table?.iterations.isEmpty == false
        let router = HostModelRouter()
        let rows = (table?.iterations ?? []).map { sampling -> HostSamplingCost in
            func unknown(_ reason: String) -> HostSamplingCost {
                allKnown = false
                return .init(ordinal: sampling.ordinal, kind: sampling.kind, model: sampling.model,
                             selectedTier: nil, value: nil, unknownReason: reason)
            }
            // No fallback to the request model or an aggregate HTTP prompt count.
            guard let model = sampling.model else { return unknown("missing_sampling_model") }
            guard let tariff = tariffs.first(where: { $0.model == model && $0.scope == serviceScope }) else { return unknown("missing_service_scoped_tariff") }
            guard let input = sampling.inputTokens, let output = sampling.outputTokens else { return unknown("missing_sampling_usage") }
            guard let tier = tariff.promptPricing.tier(forInputTokens: input),
                  let inputRate = tier.rates.inputPerMillion, let outputRate = tier.rates.outputPerMillion else { return unknown("missing_tier_rates") }
            let write = tariff.writeTariff
            guard write.currency == tariff.promptPricing.currency, write.model == nil || write.model == model else { return unknown("invalid_write_tariff_scope") }
            if let prior = currency, prior != write.currency { return unknown("mixed_currency") }
            currency = write.currency
            let quote = HostPricingQuote(inputPerMillion: inputRate, cachedInputPerMillion: tier.rates.cachedInputPerMillion,
                cacheWriteInputPerMillion: write.cacheWriteInputPerMillion, cacheWriteScope: write.cacheWriteScope,
                outputPerMillion: outputRate, currency: write.currency, source: write.source, asOf: write.asOf,
                cacheWriteTTLPrices: write.cacheWriteTTLPrices, model: model)
            let estimate = router.costEstimate(usage: .init(inputTokens: input, cachedInputTokens: sampling.cachedInputTokens,
                cacheWriteInputTokens: sampling.cacheWriteInputTokens, outputTokens: output, cacheWriteTTL: sampling.cacheWriteTTL), pricing: quote, model: model)
            if let value = estimate.value {
                var lhs = subtotal, rhs = value, sum = Decimal()
                guard NSDecimalAdd(&sum, &lhs, &rhs, .plain) == .noError else { return unknown("arithmetic_overflow") }
                subtotal = sum
            } else { allKnown = false }
            return .init(ordinal: sampling.ordinal, kind: sampling.kind, model: model, selectedTier: tier.aboveInputTokens,
                         value: estimate.value, unknownReason: estimate.unknownReason?.rawValue)
        }
        return .init(catalogRevision: revision, currency: currency, samplings: rows, total: allKnown ? subtotal : nil, knownSubtotal: subtotal)
    }
}
public enum HostIterationPricingError: Error { case invalidSnapshot, invalidPriceJSON }
