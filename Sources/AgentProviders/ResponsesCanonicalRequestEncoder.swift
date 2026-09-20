import AgentModels
import Foundation

enum ResponsesCanonicalRequestEncoder {
    typealias AssistantNativeItems = (
        _ content: [ModelContent],
        _ calls: [ToolCall]
    ) throws -> [JSONValue]?

    static func encodeMessages(
        _ messages: [ModelMessage],
        assistantNativeItems: AssistantNativeItems? = nil
    ) throws -> [JSONValue] {
        var input: [JSONValue] = []
        for message in messages {
            switch message {
            case .system(let text):
                input.append(inputMessage(role: "system", text: text))
            case .developer(let text):
                input.append(inputMessage(role: "developer", text: text))
            case .user(let content):
                input.append(inputMessage(role: "user", text: try visibleText(content)))
            case .assistant(let content, let calls):
                if let native = try assistantNativeItems?(content, calls) {
                    input.append(contentsOf: native)
                    continue
                }
                let text = try visibleText(content)
                if !text.isEmpty {
                    input.append(inputMessage(role: "assistant", text: text))
                }
                input.append(contentsOf: try functionCalls(calls))
            case .tool(let result):
                var output = try visibleText(result.content)
                if result.isError {
                    let envelope = JSONValue.object([
                        "is_error": .bool(true),
                        "content": .string(output),
                    ])
                    output = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
                }
                input.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(result.callID.rawValue),
                    "output": .string(output),
                ]))
            }
        }
        guard !input.isEmpty else {
            throw ModelProviderError(
                kind: .invalidRequest,
                message: "Conversation messages are required."
            )
        }
        return input
    }

    static func encodeTools(_ tools: [ModelToolDefinition]) -> JSONValue? {
        guard !tools.isEmpty else { return nil }
        return .array(tools.map {
            .object([
                "type": .string("function"),
                "name": .string($0.name),
                "description": .string($0.description),
                "parameters": $0.inputSchema,
                "strict": .bool(false),
            ])
        })
    }

    static func encodeStructuredOutput(_ schema: StructuredOutputSchema?) -> JSONValue? {
        guard let schema else { return nil }
        var format: [String: JSONValue] = [
            "type": .string("json_schema"),
            "name": .string(schema.name),
            "schema": schema.schema,
            "strict": .bool(schema.strict),
        ]
        if let description = schema.description {
            format["description"] = .string(description)
        }
        return .object(["format": .object(format)])
    }

    private static func inputMessage(role: String, text: String) -> JSONValue {
        .object([
            "type": .string("message"),
            "role": .string(role),
            "content": .string(text),
        ])
    }

    private static func functionCalls(_ calls: [ToolCall]) throws -> [JSONValue] {
        try calls.map { call in
            guard call.completeness == .complete,
                  (try? JSONValue.decodeToolArguments(call.argumentsJSON)) != nil,
                  !call.id.rawValue.isEmpty,
                  !call.name.isEmpty else {
                throw ModelProviderError(kind: .invalidRequest, message: "Invalid tool history.")
            }
            return .object([
                "type": .string("function_call"),
                "call_id": .string(call.id.rawValue),
                "name": .string(call.name),
                "arguments": .string(call.argumentsJSON),
            ])
        }
    }

    private static func visibleText(_ content: [ModelContent]) throws -> String {
        try content.compactMap { part -> String? in
            switch part {
            case .text(let value): return value
            case .json(let value):
                return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            case .reasoning, .providerContinuation:
                return nil
            }
        }.joined(separator: "\n")
    }
}
