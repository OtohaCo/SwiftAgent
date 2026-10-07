import AgentModels
import Foundation

enum OpenAIResponsesRequestEncoder {
    static func encode(
        _ request: ModelRequest,
        maximumOutputTokens: Int,
        reasoningEffort: OpenAIReasoningEffort?,
        reasoningSummary: OpenAIReasoningSummary?,
        promptCacheKey: String? = nil,
        promptCaching: OpenAIResponsesPromptCaching? = nil,
        resolvedModelName: String? = nil,
        prewarm: Bool = false
    ) throws -> JSONValue {
        guard request.model.provider == "openai",
              !request.model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid OpenAI model identifier.")
        }
        if prewarm, promptCaching == nil { throw PromptCacheQualification.unsupported("Prewarming requires a qualified modern cache configuration.") }
        try promptCaching?.validate(modelName: resolvedModelName ?? request.model.name, prewarm: prewarm)
        let input = try ResponsesCanonicalRequestEncoder.encodeMessages(request.messages, images: true) { content, calls in
            try OpenAIResponsesContinuation.restore(
                content: content,
                calls: calls,
                model: request.model
            )?.items
        }
        var body: [String: JSONValue] = [
            "model": .string(request.model.name), "input": .array(input), "stream": .bool(true),
            "store": .bool(false), "max_output_tokens": .number(Decimal(maximumOutputTokens)),
        ]
        if let tools = ResponsesCanonicalRequestEncoder.encodeTools(request.tools) { body["tools"] = tools }
        if let structured = ResponsesCanonicalRequestEncoder.encodeStructuredOutput(request.structuredOutput) {
            body["text"] = structured
        }
        body["include"] = .array([.string("reasoning.encrypted_content")])
        if reasoningEffort != nil || reasoningSummary != nil {
            var reasoning: [String: JSONValue] = [:]
            if let reasoningEffort { reasoning["effort"] = .string(reasoningEffort.rawValue) }
            if let reasoningSummary { reasoning["summary"] = .string(reasoningSummary.rawValue) }
            body["reasoning"] = .object(reasoning)
        }
        if let promptCacheKey { body["prompt_cache_key"] = .string(promptCacheKey) }
        try promptCaching?.apply(to: &body, request: request, images: true, assistantNativeItems: { content, calls in
            try OpenAIResponsesContinuation.restore(content: content, calls: calls, model: request.model)?.items
        }, prewarm: prewarm)
        return .object(body)
    }

    /// A key the service can route by: not empty, no surrounding spaces, no control characters.
    static func validPromptCacheKey(_ key: String?) -> Bool {
        guard let key else { return true }
        return !key.isEmpty && key == key.trimmingCharacters(in: .whitespacesAndNewlines)
            && !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
