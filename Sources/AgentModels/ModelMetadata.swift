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
}

/// Reported counts for a model response. Nil means unreported, not zero.
/// Cache counts are input subsets and reasoning is an output subset; do not sum them.
/// Providers normalize their native accounting into these categories.
public struct ModelUsage: Hashable, Sendable, Codable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedInputTokens: Int?
    public let cacheWriteInputTokens: Int?
    public let reasoningTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheWriteInputTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.reasoningTokens = reasoningTokens
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
