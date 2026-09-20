import AgentModels
import Foundation

enum OpenAIResponsesRequestEncoder {
    static func encode(
        _ request: ModelRequest,
        maximumOutputTokens: Int,
        reasoningEffort: OpenAIReasoningEffort?,
        reasoningSummary: OpenAIReasoningSummary?
    ) throws -> JSONValue {
        guard request.model.provider == "openai",
              !request.model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid OpenAI model identifier.")
        }
        let input = try ResponsesCanonicalRequestEncoder.encodeMessages(request.messages) { content, calls in
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
        return .object(body)
    }

}
