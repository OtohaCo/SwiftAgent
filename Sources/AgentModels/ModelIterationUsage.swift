import Foundation

/// One service sampling inside an HTTP invocation. Input includes cache subsets;
/// it is not the current context window size. A missing model cannot certify a tariff.
public struct ModelUsageIteration: Hashable, Sendable, Codable {
    public let ordinal: Int
    public let kind: String
    public let model: ModelID?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedInputTokens: Int?
    public let cacheWriteInputTokens: Int?
    public let reasoningTokens: Int?
    public let cacheWriteTTL: CacheWriteTTLUsage?
    public init(ordinal: Int, kind: String, model: ModelID? = nil,
                inputTokens: Int? = nil, outputTokens: Int? = nil,
                cachedInputTokens: Int? = nil, cacheWriteInputTokens: Int? = nil,
                reasoningTokens: Int? = nil, cacheWriteTTL: CacheWriteTTLUsage? = nil) throws {
        guard ordinal >= 0, !kind.isEmpty,
              [inputTokens, outputTokens, cachedInputTokens, cacheWriteInputTokens, reasoningTokens,
               cacheWriteTTL?.fiveMinuteTokens, cacheWriteTTL?.oneHourTokens].allSatisfy({ $0.map { $0 >= 0 } ?? true }),
              [(inputTokens, cachedInputTokens), (inputTokens, cacheWriteInputTokens), (outputTokens, reasoningTokens)].allSatisfy({ total, subset in
                  guard let total, let subset else { return true }; return subset <= total
              }) else { throw ModelStreamError.invalidUsage }
        func checkDisjoint(_ first: Int?, _ second: Int?, total: Int?) throws {
            let sum = (first ?? 0).addingReportingOverflow(second ?? 0)
            guard !sum.overflow, total.map({ sum.partialValue <= $0 }) ?? true else { throw ModelStreamError.invalidUsage }
        }
        try checkDisjoint(cachedInputTokens, cacheWriteInputTokens, total: inputTokens)
        try checkDisjoint(cacheWriteTTL?.fiveMinuteTokens, cacheWriteTTL?.oneHourTokens, total: cacheWriteInputTokens)
        self.ordinal = ordinal; self.kind = kind; self.model = model
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens; self.cacheWriteInputTokens = cacheWriteInputTokens
        self.reasoningTokens = reasoningTokens; self.cacheWriteTTL = cacheWriteTTL
    }
    private enum CodingKeys: String, CodingKey { case ordinal, kind, model, inputTokens, outputTokens, cachedInputTokens, cacheWriteInputTokens, reasoningTokens, cacheWriteTTL }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(ordinal: c.decode(Int.self, forKey: .ordinal), kind: c.decode(String.self, forKey: .kind),
                      model: c.decodeIfPresent(ModelID.self, forKey: .model), inputTokens: c.decodeIfPresent(Int.self, forKey: .inputTokens),
                      outputTokens: c.decodeIfPresent(Int.self, forKey: .outputTokens), cachedInputTokens: c.decodeIfPresent(Int.self, forKey: .cachedInputTokens),
                      cacheWriteInputTokens: c.decodeIfPresent(Int.self, forKey: .cacheWriteInputTokens), reasoningTokens: c.decodeIfPresent(Int.self, forKey: .reasoningTokens),
                      cacheWriteTTL: c.decodeIfPresent(CacheWriteTTLUsage.self, forKey: .cacheWriteTTL))
    }
    public var usage: ModelUsage {
        .init(inputTokens: inputTokens, outputTokens: outputTokens, cachedInputTokens: cachedInputTokens,
              cacheWriteInputTokens: cacheWriteInputTokens, reasoningTokens: reasoningTokens, cacheWriteTTL: cacheWriteTTL)
    }
}

/// Replacement table, not an append-only ledger. Ordinals are local to one invocation.
public struct ModelIterationUsage: Hashable, Sendable, Codable {
    public enum Coverage: String, Hashable, Sendable, Codable { case partial, complete }
    public let iterations: [ModelUsageIteration]
    public let coverage: Coverage
    public init(iterations: [ModelUsageIteration], coverage: Coverage) throws {
        guard zip(iterations, iterations.dropFirst()).allSatisfy({ $0.ordinal < $1.ordinal }) else { throw ModelStreamError.invalidUsage }
        self.iterations = iterations; self.coverage = coverage
    }
    private enum CodingKeys: String, CodingKey { case iterations, coverage }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(iterations: c.decode([ModelUsageIteration].self, forKey: .iterations), coverage: c.decode(Coverage.self, forKey: .coverage))
    }
    /// Only complete, field-covered tables establish a whole-invocation total.
    /// Empty tables clear detail and do not manufacture zero consumption.
    public func aggregate() throws -> ModelUsage {
        func sum(_ field: (ModelUsageIteration) -> Int?) throws -> Int? {
            guard coverage == .complete, !iterations.isEmpty else { return nil }
            var sum = 0
            for iteration in iterations {
                guard let value = field(iteration) else { return nil }
                let next = sum.addingReportingOverflow(value)
                guard !next.overflow else { throw ModelStreamError.invalidUsage }; sum = next.partialValue
            }
            return sum
        }
        return try .init(inputTokens: sum { $0.inputTokens }, outputTokens: sum { $0.outputTokens },
                         cachedInputTokens: sum { $0.cachedInputTokens }, cacheWriteInputTokens: sum { $0.cacheWriteInputTokens },
                         reasoningTokens: sum { $0.reasoningTokens },
                         cacheWriteTTL: iterations.contains { $0.cacheWriteTTL != nil } ? .init(
                            fiveMinuteTokens: sum { $0.cacheWriteTTL?.fiveMinuteTokens }, oneHourTokens: sum { $0.cacheWriteTTL?.oneHourTokens }) : nil,
                         iterationUsage: self)
    }
}
