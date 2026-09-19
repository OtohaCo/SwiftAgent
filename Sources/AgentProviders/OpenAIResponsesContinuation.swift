import AgentModels
import Foundation

enum OpenAIResponsesContinuation {
    static let format = "openai.responses.v1"

    struct Restored {
        let items: [JSONValue]
    }

    static func make(items: [JSONValue], content: [ModelContent], calls: [ToolCall], model: ModelID) throws -> ModelProviderContinuation? {
        let portable = try validate(items: items, content: content, calls: calls)
        guard portable.hasReasoning, !calls.isEmpty else { return nil }
        let reasoning = visibleReasoning(content)
        let payload = JSONValue.object([
            "items": .array(portable.items),
            "visible_reasoning": .array(reasoning.map(JSONValue.string)),
        ])
        return .init(model: model, format: format, payload: try JSONEncoder().encode(payload))
    }

    static func restore(content: [ModelContent], calls: [ToolCall], model: ModelID) throws -> Restored? {
        let matching = content.compactMap { part -> ModelProviderContinuation? in
            guard case .providerContinuation(let state) = part,
                  state.model.provider.utf8.elementsEqual(model.provider.utf8),
                  state.model.name.utf8.elementsEqual(model.name.utf8) else { return nil }
            return state
        }
        guard !matching.isEmpty else { return nil }
        do {
            guard matching.count == 1, let state = matching.first,
                  state.format.utf8.elementsEqual(format.utf8),
                  let payload = try? JSONDecoder().decode(JSONValue.self, from: state.payload),
                  case .object(let object) = payload,
                  case .array(let items) = object["items"],
                  case .array(let encodedReasoning) = object["visible_reasoning"] else {
                throw ProviderJSON.invalid()
            }
            let expectedReasoning = try encodedReasoning.map(ProviderJSON.string)
            guard expectedReasoning == visibleReasoning(content) else { throw ProviderJSON.invalid() }
            let restored = try validate(items: items, content: content, calls: calls)
            guard restored.hasReasoning, !calls.isEmpty else { throw ProviderJSON.invalid() }
            return .init(items: restored.items)
        } catch {
            throw ModelProviderError(kind: .invalidRequest,
                                     message: "Provider continuation does not match the canonical message.")
        }
    }

    private struct Validated {
        let items: [JSONValue]
        let hasReasoning: Bool
    }

    private static func validate(items: [JSONValue], content: [ModelContent], calls: [ToolCall]) throws -> Validated {
        var normalized: [JSONValue] = []
        var functionItems: [JSONValue] = []
        var messageCount = 0
        var hasReasoning = false
        for item in items {
            let object = try ProviderJSON.object(item)
            switch try ProviderJSON.string(object["type"]) {
            case "reasoning":
                let id = try ProviderJSON.string(object["id"])
                let encrypted = try ProviderJSON.string(object["encrypted_content"])
                guard !id.isEmpty, !encrypted.isEmpty,
                      case .array(let summary) = object["summary"] else {
                    throw ProviderJSON.invalid()
                }
                hasReasoning = true
                normalized.append(.object([
                    "type": .string("reasoning"), "id": .string(id),
                    "summary": .array(summary), "encrypted_content": .string(encrypted),
                ]))
            case "message":
                messageCount += 1
                guard messageCount == 1,
                      !(try ProviderJSON.string(object["id"])).isEmpty,
                      try ProviderJSON.string(object["role"]) == "assistant",
                      case .array(let parts) = object["content"] else { throw ProviderJSON.invalid() }
                let text = try parts.map { part -> String in
                    let part = try ProviderJSON.object(part)
                    guard try ProviderJSON.string(part["type"]) == "output_text" else { throw ProviderJSON.invalid() }
                    return try ProviderJSON.string(part["text"])
                }.joined()
                let expectedText = try visibleText(content)
                guard text.utf8.elementsEqual(expectedText.utf8) else { throw ProviderJSON.invalid() }
                normalized.append(.object([
                    "type": .string("message"), "role": .string("assistant"),
                    "content": .array([.object(["type": .string("output_text"), "text": .string(text)])]),
                ]))
            case "function_call":
                let id = try ProviderJSON.string(object["id"])
                let callID = try ProviderJSON.string(object["call_id"])
                let name = try ProviderJSON.string(object["name"])
                let arguments = try ProviderJSON.string(object["arguments"])
                guard !id.isEmpty, !callID.isEmpty, !name.isEmpty else { throw ProviderJSON.invalid() }
                let normalizedCall = JSONValue.object([
                    "type": .string("function_call"), "id": .string(id), "call_id": .string(callID),
                    "name": .string(name), "arguments": .string(arguments),
                ])
                normalized.append(normalizedCall)
                functionItems.append(normalizedCall)
            default:
                throw ProviderJSON.invalid()
            }
        }
        guard functionItems.count == calls.count else { throw ProviderJSON.invalid() }
        for (item, call) in zip(functionItems, calls) {
            let object = try ProviderJSON.object(item)
            guard call.completeness == .complete,
                  !(try ProviderJSON.string(object["id"])).isEmpty,
                  try ProviderJSON.string(object["call_id"]).utf8.elementsEqual(call.id.rawValue.utf8),
                  try ProviderJSON.string(object["name"]).utf8.elementsEqual(call.name.utf8),
                  try ProviderJSON.string(object["arguments"]).utf8.elementsEqual(call.argumentsJSON.utf8) else {
                throw ProviderJSON.invalid()
            }
        }
        return .init(items: normalized, hasReasoning: hasReasoning)
    }

    private static func visibleReasoning(_ content: [ModelContent]) -> [String] {
        content.compactMap { part in
            if case .reasoning(let value) = part { return value }
            return nil
        }
    }

    private static func visibleText(_ content: [ModelContent]) throws -> String {
        try content.compactMap { part -> String? in
            switch part {
            case .text(let value): return value
            case .json(let value): return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            case .reasoning, .providerContinuation: return nil
            }
        }.joined(separator: "\n")
    }
}
