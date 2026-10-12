import Foundation
import AgentModels

/// Rates apply to the whole sampling, in currency units per million tokens.
/// Missing is unknown; zero is an explicitly free category. Decimal is never routed through Double.
public struct ModelPromptPriceRates: Hashable, Sendable, Codable {
    public let inputPerMillion: Decimal?
    public let outputPerMillion: Decimal?
    public let cachedInputPerMillion: Decimal?
    public init(inputPerMillion: Decimal? = nil, outputPerMillion: Decimal? = nil, cachedInputPerMillion: Decimal? = nil) throws {
        guard [inputPerMillion, outputPerMillion, cachedInputPerMillion].allSatisfy({ $0.map { !$0.isNaN && $0 >= 0 } ?? true }) else {
            throw ModelCatalogValidationError(kind: .init(rawValue: "invalid_price"), field: "rates")
        }
        self.inputPerMillion = inputPerMillion; self.outputPerMillion = outputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
    }
    private enum CodingKeys: String, CodingKey { case inputPerMillion, outputPerMillion, cachedInputPerMillion }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys) throws -> Decimal? {
            guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
            if let text = try? c.decode(String.self, forKey: key) {
                guard text.range(of: #"^[+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
                      let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN,
                      Self.normalizedDecimal(text) == Self.normalizedDecimal(NSDecimalNumber(decimal: value).stringValue) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Invalid decimal rate.")
                }
                return value
            }
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Rates require exact decimal strings.")
        }
        try self.init(inputPerMillion: read(.inputPerMillion), outputPerMillion: read(.outputPerMillion), cachedInputPerMillion: read(.cachedInputPerMillion))
    }
    private static func normalizedDecimal(_ text: String) -> String? {
        let parts = text.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count <= 2, let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return nil }
        var mantissa = String(parts[0]); if mantissa.hasPrefix("+") { mantissa.removeFirst() }
        let decimal = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard decimal.count <= 2 else { return nil }
        var digits = decimal.joined(); var power = exponent.subtractingReportingOverflow(decimal.count == 2 ? decimal[1].count : 0)
        guard !power.overflow else { return nil }
        while digits.hasPrefix("0") { digits.removeFirst() }
        if digits.isEmpty { return "0" }
        while digits.hasSuffix("0") {
            digits.removeLast(); power = power.partialValue.addingReportingOverflow(1)
            guard !power.overflow else { return nil }
        }
        return digits + "e" + String(power.partialValue)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(inputPerMillion.map { NSDecimalNumber(decimal: $0).stringValue }, forKey: .inputPerMillion)
        try c.encodeIfPresent(outputPerMillion.map { NSDecimalNumber(decimal: $0).stringValue }, forKey: .outputPerMillion)
        try c.encodeIfPresent(cachedInputPerMillion.map { NSDecimalNumber(decimal: $0).stringValue }, forKey: .cachedInputPerMillion)
    }
}

public struct ModelPromptPriceTier: Hashable, Sendable, Codable {
    public let aboveInputTokens: Int
    public let inclusive: Bool
    public let rates: ModelPromptPriceRates
    public init(aboveInputTokens: Int, inclusive: Bool, rates: ModelPromptPriceRates) {
        self.aboveInputTokens = aboveInputTokens; self.inclusive = inclusive; self.rates = rates
    }
}

/// Immutable quote provenance belongs to the entry's service scope and catalog revision.
public struct ModelPromptPricing: Hashable, Sendable, Codable {
    public let currency: String
    public let tiers: [ModelPromptPriceTier]
    public let sources: [ModelCatalogSource]
    public init(currency: String, tiers: [ModelPromptPriceTier], sources: [ModelCatalogSource]) throws {
        guard !currency.isEmpty, currency == currency.trimmingCharacters(in: .whitespacesAndNewlines),
              !currency.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let first = tiers.first, first.aboveInputTokens == 0, first.inclusive,
              zip(tiers, tiers.dropFirst()).allSatisfy({ $0.aboveInputTokens < $1.aboveInputTokens }) else {
            throw ModelCatalogValidationError(kind: .init(rawValue: "invalid_price_tiers"), field: "promptPricing")
        }
        self.currency = currency; self.tiers = tiers; self.sources = sources
    }
    public func tier(forInputTokens count: Int) -> ModelPromptPriceTier? {
        guard count >= 0 else { return nil }
        return tiers.last { $0.inclusive ? count >= $0.aboveInputTokens : count > $0.aboveInputTokens }
    }
    private enum CodingKeys: String, CodingKey { case currency, tiers, sources }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(currency: c.decode(String.self, forKey: .currency), tiers: c.decode([ModelPromptPriceTier].self, forKey: .tiers), sources: c.decode([ModelCatalogSource].self, forKey: .sources))
    }
}

public struct ModelCompactionDescriptor: Hashable, Sendable, Codable {
    public let mode: ModelCompactionMode
    public let support: ModelCatalogSupport
    public let minimumTriggerInputTokens: Int?
    public let sources: [ModelCatalogSource]
    public let executability: ModelCatalogExecutability
    public init(mode: ModelCompactionMode, support: ModelCatalogSupport, minimumTriggerInputTokens: Int? = nil,
                sources: [ModelCatalogSource], executability: ModelCatalogExecutability) throws {
        guard minimumTriggerInputTokens.map({ $0 >= 0 }) ?? true,
              ![.anthropicOnDemand, .openAIStandalone].contains(mode) || minimumTriggerInputTokens == nil else {
            throw ModelCatalogValidationError(kind: .init(rawValue: "invalid_compaction_trigger"), field: "minimumTriggerInputTokens")
        }
        self.mode = mode; self.support = support; self.minimumTriggerInputTokens = minimumTriggerInputTokens
        self.sources = sources; self.executability = executability
    }
    private enum CodingKeys: String, CodingKey { case mode, support, minimumTriggerInputTokens, sources, executability }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(mode: c.decode(ModelCompactionMode.self, forKey: .mode), support: c.decode(ModelCatalogSupport.self, forKey: .support),
                      minimumTriggerInputTokens: c.decodeIfPresent(Int.self, forKey: .minimumTriggerInputTokens),
                      sources: c.decode([ModelCatalogSource].self, forKey: .sources), executability: c.decode(ModelCatalogExecutability.self, forKey: .executability))
    }
}

/// An absent descriptor is not unsupported unless the service statement is exhaustive.
/// Supported describes service metadata, not a grant of configured adapter capability.
public struct ModelCompactionCatalog: Hashable, Sendable, Codable {
    public let support: ModelCatalogSupport
    public let modesAreExhaustive: Bool
    public let modes: [ModelCompactionDescriptor]
    public init(support: ModelCatalogSupport = .unknown, modesAreExhaustive: Bool = false, modes: [ModelCompactionDescriptor]) {
        self.support = support; self.modesAreExhaustive = modesAreExhaustive; self.modes = modes
    }
}
