import AgentModels
import Foundation

enum AnthropicRequestEncoder {
    private struct Message {
        let role: String
        var content: [JSONValue]
        var json: JSONValue { .object(["role": .string(role), "content": .array(content)]) }
    }
    static func encode(
        _ request: ModelRequest,
        maximumOutputTokens: Int,
        thinking: AnthropicThinking,
        effort: AnthropicEffort? = nil
    ) throws -> JSONValue {
        guard request.model.provider == "anthropic", !request.model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid Anthropic model identifier.")
        }
        var system: [String] = []
        var messages: [Message] = []
        for message in request.messages {
            switch message {
            case .system(let text), .developer(let text):
                guard messages.isEmpty else {
                    throw ModelProviderError(kind: .unsupportedCapability, message: "This adapter requires instructions before conversation messages.")
                }
                system.append(text)
            case .user(let content):
                try append(role: "user", content: textBlocks(content), to: &messages)
            case .assistant(let content, let calls):
                if let restored = try AnthropicContinuation.restore(content: content, calls: calls, model: request.model) {
                    try append(role: "assistant", content: restored, to: &messages)
                    continue
                }
                var blocks = try textBlocks(content)
                for call in calls {
                    guard call.completeness == .complete,
                          let arguments = try? JSONValue.decodeToolArguments(call.argumentsJSON) else {
                        throw ModelProviderError(kind: .invalidRequest, message: "Invalid tool history.")
                    }
                    blocks.append(.object(["type": .string("tool_use"), "id": .string(call.id.rawValue),
                                            "name": .string(call.name), "input": arguments]))
                }
                try append(role: "assistant", content: blocks, to: &messages)
            case .tool(let result):
                let text = try result.content.compactMap { part -> String? in
                    switch part {
                    case .text(let value): return value
                    case .json(let value): return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                    case .reasoning, .providerContinuation: return nil
                    }
                }.joined(separator: "\n")
                try append(role: "user", content: [.object([
                    "type": .string("tool_result"), "tool_use_id": .string(result.callID.rawValue),
                    "content": .string(text), "is_error": .bool(result.isError),
                ])], to: &messages)
            }
        }
        guard !messages.isEmpty else { throw ModelProviderError(kind: .invalidRequest, message: "Conversation messages are required.") }
        var body: [String: JSONValue] = ["model": .string(request.model.name), "max_tokens": .number(Decimal(maximumOutputTokens)),
                                        "stream": .bool(true), "messages": .array(messages.map(\.json))]
        if !system.isEmpty { body["system"] = .string(system.joined(separator: "\n")) }
        switch thinking {
        case .disabled: body["thinking"] = .object(["type": .string("disabled")])
        case .adaptive: body["thinking"] = .object(["type": .string("adaptive")])
        case .enabled(let budget): body["thinking"] = .object(["type": .string("enabled"), "budget_tokens": .number(Decimal(budget))])
        }
        var outputConfiguration: [String: JSONValue] = [:]
        if let effort { outputConfiguration["effort"] = .string(effort.rawValue) }
        if let schema = request.structuredOutput {
            outputConfiguration["format"] = .object(["type": .string("json_schema"), "schema": schema.schema])
        }
        if !outputConfiguration.isEmpty { body["output_config"] = .object(outputConfiguration) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                .object(["name": .string($0.name), "description": .string($0.description), "input_schema": $0.inputSchema])
            })
        }
        return .object(body)
    }

    private static func append(role: String, content: [JSONValue], to messages: inout [Message]) throws {
        if role == "assistant", content.isEmpty { return }
        guard !content.isEmpty else { throw ModelProviderError(kind: .invalidRequest, message: "Message content is required.") }
        if messages.last?.role == role { messages[messages.count - 1].content.append(contentsOf: content) }
        else { messages.append(.init(role: role, content: content)) }
    }

    private static func textBlocks(_ content: [ModelContent]) throws -> [JSONValue] {
        try content.compactMap { part in
            let text: String
            switch part {
            case .text(let value): text = value
            case .json(let value): text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            case .reasoning, .providerContinuation: return nil
            }
            return .object(["type": .string("text"), "text": .string(text)])
        }
    }
}
