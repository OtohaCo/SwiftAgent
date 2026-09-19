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
        var input: [JSONValue] = []
        for message in request.messages {
            switch message {
            case .system(let text): input.append(inputMessage(role: "system", text: text))
            case .developer(let text): input.append(inputMessage(role: "developer", text: text))
            case .user(let content): input.append(inputMessage(role: "user", text: try text(content)))
            case .assistant(let content, let calls):
                let continuation = try OpenAIResponsesContinuation.restore(content: content, calls: calls, model: request.model)
                if let continuation {
                    input.append(contentsOf: continuation.items)
                    continue
                }
                let text = try text(content)
                if !text.isEmpty { input.append(inputMessage(role: "assistant", text: text)) }
                for call in calls {
                    guard call.completeness == .complete,
                          (try? JSONValue.decodeToolArguments(call.argumentsJSON)) != nil,
                          !call.id.rawValue.isEmpty, !call.name.isEmpty else {
                        throw ModelProviderError(kind: .invalidRequest, message: "Invalid tool history.")
                    }
                    input.append(.object([
                        "type": .string("function_call"), "call_id": .string(call.id.rawValue),
                        "name": .string(call.name), "arguments": .string(call.argumentsJSON),
                    ]))
                }
            case .tool(let result):
                var output = try text(result.content)
                if result.isError {
                    let envelope = JSONValue.object(["is_error": .bool(true), "content": .string(output)])
                    output = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
                }
                input.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(result.callID.rawValue), "output": .string(output),
                ]))
            }
        }
        guard !input.isEmpty else {
            throw ModelProviderError(kind: .invalidRequest, message: "Conversation messages are required.")
        }
        var body: [String: JSONValue] = [
            "model": .string(request.model.name), "input": .array(input), "stream": .bool(true),
            "store": .bool(false), "max_output_tokens": .number(Decimal(maximumOutputTokens)),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                .object(["type": .string("function"), "name": .string($0.name),
                         "description": .string($0.description), "parameters": $0.inputSchema,
                         "strict": .bool(false)])
            })
        }
        if let schema = request.structuredOutput {
            var format: [String: JSONValue] = [
                "type": .string("json_schema"), "name": .string(schema.name),
                "schema": schema.schema, "strict": .bool(schema.strict),
            ]
            if let description = schema.description { format["description"] = .string(description) }
            body["text"] = .object(["format": .object(format)])
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

    private static func inputMessage(role: String, text: String) -> JSONValue {
        .object(["type": .string("message"), "role": .string(role), "content": .string(text)])
    }

    private static func text(_ content: [ModelContent]) throws -> String {
        try content.compactMap { part -> String? in
            switch part {
            case .text(let value): return value
            case .json(let value): return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            case .reasoning, .providerContinuation: return nil
            }
        }.joined(separator: "\n")
    }
}
