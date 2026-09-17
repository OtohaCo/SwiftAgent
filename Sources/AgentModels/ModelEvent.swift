public struct ResponseInfo: Hashable, Sendable, Codable {
    public let id: String
    public let model: ModelID

    public init(id: String, model: ModelID) {
        self.id = id
        self.model = model
    }
}

public struct ModelResponse: Hashable, Sendable, Codable {
    public let info: ResponseInfo
    public let content: [ModelContent]
    public let toolCalls: [ToolCall]
    public let usage: ModelUsage
    public let stopReason: StopReason

    public init(
        info: ResponseInfo,
        content: [ModelContent] = [],
        toolCalls: [ToolCall] = [],
        usage: ModelUsage = .init(),
        stopReason: StopReason
    ) {
        self.info = info
        self.content = content
        self.toolCalls = toolCalls
        self.usage = usage
        self.stopReason = stopReason
    }
}

public enum ModelEvent: Hashable, Sendable, Codable {
    case responseStarted(ResponseInfo)
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallStarted(ToolCallID, name: String)
    case toolCallArgumentsDelta(ToolCallID, String)
    case toolCallCompleted(ToolCall)
    /// Cumulative counts; nil leaves the corresponding previously reported count unchanged.
    case usage(ModelUsage)
    case responseCompleted(ModelResponse)
}
