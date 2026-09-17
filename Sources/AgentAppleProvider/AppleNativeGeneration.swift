#if canImport(FoundationModels)
import AgentModels
import Foundation
import FoundationModels

extension AppleFoundationProvider {
    @available(macOS 26, iOS 26, *)
    public init(maximumResponseTokens: Int = 2_048) throws {
        guard maximumResponseTokens > 0 else {
            throw ModelProviderError(kind: .invalidRequest, message: "The response token limit must be positive.")
        }
        self.generate = { request in
            try await AppleNativeGeneration.respond(to: request, maximumResponseTokens: maximumResponseTokens)
        }
    }
}

@available(macOS 26, iOS 26, *)
private enum AppleNativeGeneration {
    static func respond(to request: ModelRequest, maximumResponseTokens: Int) async throws -> AppleGeneratedTurn {
        try Task.checkCancellation()
        guard case .available = SystemLanguageModel.default.availability else {
            throw ModelProviderError(kind: .unavailable, message: "The on-device Apple model is unavailable.")
        }
        let hostInstructions = request.messages.compactMap { message -> String? in
            switch message {
            case .system(let text), .developer(let text): return text
            default: return nil
            }
        }.joined(separator: "\n")
        let instructions = """
        You are the planner for an external tool runtime. Produce exactly one plan for the supplied conversation.
        The runtime executes the tool action you propose and sends you its real result in the next request.
        If the user asks to use a tool, choose tool unless its actual result is already in the conversation.
        Request a tool by selecting the tool case with its name and argumentsJSON.
        Choose tool when an operation is needed, using a name from the supplied tool declarations.
        Choose answer when the requested operations already have actual results, or no tool is needed.
        Each argumentsJSON is a valid JSON object string matching that tool's inputSchema.
        Never invent a tool result. Use actual tool messages when answering after a tool call.
        Do not repeat a successful call already present in the conversation unless newer data was requested.
        Choose refusal to decline a request.
        \(hostInstructions)
        """
        let messages = try request.messages.filter { $0.role != .system && $0.role != .developer }.map(PromptMessage.init)
        let data = try JSONEncoder().encode(PromptInput(messages: messages, tools: request.tools))
        let session = LanguageModelSession(model: .default, tools: [], instructions: instructions)
        let response = try await session.respond(to: String(decoding: data, as: UTF8.self), generating: NativePlan.self,
                                                  options: GenerationOptions(temperature: 0, maximumResponseTokens: maximumResponseTokens))
        try Task.checkCancellation()
        guard response.rawContent.isComplete else {
            throw ModelProviderError(kind: .invalidResponse, message: "The Apple model plan was truncated.")
        }
        let plan: AppleModelPlan
        switch response.content {
        case .answer(let text): plan = .init(kind: .answer, text: text, toolCalls: [])
        case .tool(let name, let arguments): plan = .init(kind: .tools, text: "", toolCalls: [.init(name: name, argumentsJSON: arguments)])
        case .refusal(let reason): plan = .init(kind: .refusal, text: reason, toolCalls: [])
        }
        var turn = AppleGeneratedTurn(plan: plan)
        #if compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) {
            turn.usage = ModelUsage(inputTokens: response.usage.input.totalTokenCount,
                                    outputTokens: response.usage.output.totalTokenCount,
                                    cachedInputTokens: response.usage.input.cachedTokenCount,
                                    reasoningTokens: response.usage.output.reasoningTokenCount)
        }
        #endif
        return turn
    }

    @Generable(description: "One next action for an external runtime: request a tool or answer using actual results")
    fileprivate enum NativePlan {
        case tool(name: String, argumentsJSON: String)
        case answer(text: String)
        case refusal(reason: String)
    }

    private struct PromptInput: Encodable {
        let messages: [PromptMessage]
        let tools: [ModelToolDefinition]
    }

    private struct PromptMessage: Encodable {
        let role: ModelRole
        let content: String
        var toolCalls: [PromptCall] = []
        var callID: String?
        var isError: Bool?

        init(_ message: ModelMessage) throws {
            role = message.role
            let parts: [ModelContent]
            switch message {
            case .system(let text), .developer(let text): parts = [.text(text)]
            case .user(let content): parts = content
            case .assistant(let content, let calls): parts = content; toolCalls = calls.map(PromptCall.init)
            case .tool(let result): parts = result.content; callID = result.callID.rawValue; isError = result.isError
            }
            content = try parts.compactMap { part -> String? in
                switch part {
                case .text(let text), .reasoning(let text): return text
                case .json(let value): return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                case .providerContinuation: return nil
                }
            }.joined(separator: "\n")
        }
    }

    private struct PromptCall: Encodable {
        let id: String
        let name: String
        let argumentsJSON: String
        init(_ call: ToolCall) {
            id = call.id.rawValue
            name = call.name
            argumentsJSON = call.argumentsJSON
        }
    }
}
#endif
