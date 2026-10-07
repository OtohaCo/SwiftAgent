public struct ModelCapabilities: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let streaming = Self(rawValue: 1 << 0)
    public static let multiTurn = Self(rawValue: 1 << 1)
    public static let tools = Self(rawValue: 1 << 2)
    public static let structuredOutput = Self(rawValue: 1 << 3)
    public static let reasoning = Self(rawValue: 1 << 4)
    /// The adapter can send `ModelContent.image` in user messages and tool results. Whether the bound
    /// model accepts images is the Host's knowledge, declared by the Run's image policy.
    public static let imageInput = Self(rawValue: 1 << 5)
}

/// Reported cache writes by retention category. Nil means unreported, including
/// within a partial breakdown. These counts subdivide aggregate cache writes;
/// they are never added to the aggregate or total input a second time.
public struct CacheWriteTTLUsage: Hashable, Sendable, Codable {
    public let fiveMinuteTokens: Int?
    public let oneHourTokens: Int?

    public init(fiveMinuteTokens: Int? = nil, oneHourTokens: Int? = nil) {
        self.fiveMinuteTokens = fiveMinuteTokens
        self.oneHourTokens = oneHourTokens
    }
}

/// Reported counts for a model response. Nil means unreported, not zero.
/// Cache counts are input subsets and reasoning is an output subset; do not sum them.
/// Providers normalize their native accounting into these categories.
public struct ModelUsage: Hashable, Sendable, Codable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedInputTokens: Int?
    /// Aggregate reported cache writes, already included in inputTokens. This does
    /// not identify a tariff or TTL; unreported writes remain nil, not zero.
    public let cacheWriteInputTokens: Int?
    public let reasoningTokens: Int?
    public let cacheWriteTTL: CacheWriteTTLUsage?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheWriteInputTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.init(inputTokens: inputTokens, outputTokens: outputTokens,
                  cachedInputTokens: cachedInputTokens, cacheWriteInputTokens: cacheWriteInputTokens,
                  reasoningTokens: reasoningTokens, cacheWriteTTL: nil)
    }

    /// Detail overload preserves the original initializer's function signature.
    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheWriteInputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        cacheWriteTTL: CacheWriteTTLUsage?
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheWriteTTL = cacheWriteTTL
    }
}

/// Why a model turn stopped. Only the agent loop can decide whether a run is done.
public enum StopReason: Hashable, Sendable, Codable {
    case endTurn
    case toolCalls
    case maxOutputTokens
    case stopSequence
    case refusal
    case cancelled
    case unknown(String)
}
