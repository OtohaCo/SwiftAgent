import AgentModels
import Foundation

enum DeepSeekResponsesRequestEncoder {
    static func encode(
        _ request: ModelRequest,
        maximumOutputTokens: Int,
        reasoningEffort: DeepSeekReasoningEffort
    ) throws -> JSONValue {
        guard request.model.provider == "deepseek",
              !request.model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid DeepSeek model identifier.")
        }
        var input: [JSONValue] = []
        for modelMessage in request.messages {
            switch modelMessage {
            case .system(let text):
                input.append(message(role: "system", text: text))
            case .developer:
                throw ModelProviderError(
                    kind: .unsupportedCapability,
                    message: "DeepSeek treats developer messages as user messages; trusted developer semantics are unsupported."
                )
            case .user(let content):
                input.append(message(role: "user", text: try text(content)))
            case .assistant(let content, let calls):
                if let restored = try DeepSeekResponsesContinuation.restore(
                    content: content, calls: calls, model: request.model
                ) {
                    input.append(contentsOf: restored.items)
                } else {
                    if reasoningEffort != .none && !request.tools.isEmpty {
                        throw ModelProviderError(
                            kind: .invalidRequest,
                            message: "DeepSeek thinking with tools requires the original plaintext reasoning continuation."
                        )
                    }
                    let value = try text(content)
                    if !value.isEmpty { input.append(message(role: "assistant", text: value)) }
                    input.append(contentsOf: try calls.map(functionCall))
                }
            case .tool(let result):
                var output = try text(result.content)
                if result.isError {
                    output = String(decoding: try JSONEncoder().encode(JSONValue.object([
                        "is_error": .bool(true), "content": .string(output),
                    ])), as: UTF8.self)
                }
                guard !result.callID.rawValue.isEmpty else {
                    throw ModelProviderError(kind: .invalidRequest, message: "Invalid tool result history.")
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
            "max_output_tokens": .number(Decimal(maximumOutputTokens)),
            "reasoning": .object(["effort": .string(reasoningEffort.rawValue)]),
        ]
        if !request.tools.isEmpty {
            var names = Set<String>()
            body["tools"] = .array(try request.tools.map { tool in
                guard isValidToolName(tool.name), names.insert(tool.name).inserted else {
                    throw ModelProviderError(kind: .invalidRequest, message: "Invalid DeepSeek function tool identity.")
                }
                return .object([
                    "type": .string("function"), "name": .string(tool.name),
                    "description": .string(tool.description), "parameters": tool.inputSchema,
                ])
            })
        }
        if let schema = request.structuredOutput {
            body["text"] = .object(["format": .object([
                "type": .string("json_schema"), "name": .string(schema.name), "schema": schema.schema,
            ])])
        }
        return .object(body)
    }

    private static func message(role: String, text: String) -> JSONValue {
        .object(["type": .string("message"), "role": .string(role), "content": .string(text)])
    }

    private static func functionCall(_ call: ToolCall) throws -> JSONValue {
        guard call.completeness == .complete, !call.id.rawValue.isEmpty, isValidToolName(call.name),
              (try? JSONValue.decodeToolArguments(call.argumentsJSON)) != nil else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid tool history.")
        }
        return .object([
            "type": .string("function_call"), "call_id": .string(call.id.rawValue),
            "name": .string(call.name), "arguments": .string(call.argumentsJSON),
        ])
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

    private static func isValidToolName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 128 else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }
}
