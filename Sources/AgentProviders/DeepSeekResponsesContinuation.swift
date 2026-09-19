import AgentModels
import Foundation

enum DeepSeekResponsesContinuation {
    static let format = "deepseek.responses.v1"

    struct Restored { let items: [JSONValue] }

    static func make(
        items: [JSONValue], content: [ModelContent], calls: [ToolCall], model: ModelID
    ) throws -> ModelProviderContinuation? {
        let validated = try validate(items: items, content: content, calls: calls)
        guard validated.hasReasoning else { return nil }
        return .init(model: model, format: format,
                     payload: try JSONEncoder().encode(JSONValue.object(["items": .array(items)])))
    }

    static func restore(
        content: [ModelContent], calls: [ToolCall], model: ModelID
    ) throws -> Restored? {
        let matching = content.compactMap { part -> ModelProviderContinuation? in
            guard case .providerContinuation(let state) = part,
                  state.model.provider == model.provider, state.model.name == model.name else { return nil }
            return state
        }
        guard !matching.isEmpty else { return nil }
        do {
            guard matching.count == 1, let state = matching.first, state.format == format,
                  let payload = try? JSONDecoder().decode(JSONValue.self, from: state.payload),
                  case .object(let object) = payload, case .array(let items) = object["items"] else {
                throw ProviderJSON.invalid()
            }
            let validated = try validate(items: items, content: content, calls: calls)
            guard validated.hasReasoning else { throw ProviderJSON.invalid() }
            return .init(items: items)
        } catch {
            throw ModelProviderError(kind: .invalidRequest,
                                     message: "DeepSeek continuation does not match the canonical message.")
        }
    }

    private static func validate(
        items: [JSONValue], content: [ModelContent], calls: [ToolCall]
    ) throws -> (hasReasoning: Bool, visibleReasoning: String) {
        var nativeText = ""
        var nativeReasoning = ""
        var functionItems: [[String: JSONValue]] = []
        var hasReasoning = false
        for item in items {
            let object = try ProviderJSON.object(item)
            switch try ProviderJSON.string(object["type"]) {
            case "reasoning":
                guard object["summary"] == nil, object["encrypted_content"] == nil,
                      case .array(let parts) = object["content"], !parts.isEmpty else {
                    throw ProviderJSON.invalid()
                }
                hasReasoning = true
                for value in parts {
                    let part = try ProviderJSON.object(value)
                    guard try ProviderJSON.string(part["type"]) == "reasoning_text" else {
                        throw ProviderJSON.invalid()
                    }
                    let text = try ProviderJSON.string(part["text"])
                    guard !text.isEmpty else { throw ProviderJSON.invalid() }
                    nativeReasoning += text
                }
            case "message":
                guard try ProviderJSON.string(object["role"]) == "assistant" else { throw ProviderJSON.invalid() }
                if case .string(let text) = object["content"] {
                    nativeText += text
                } else {
                    guard case .array(let parts) = object["content"] else { throw ProviderJSON.invalid() }
                    for value in parts {
                        let part = try ProviderJSON.object(value)
                        guard try ProviderJSON.string(part["type"]) == "output_text" else {
                            throw ProviderJSON.invalid()
                        }
                        nativeText += try ProviderJSON.string(part["text"])
                    }
                }
            case "function_call":
                _ = try ProviderJSON.string(object["call_id"])
                _ = try ProviderJSON.string(object["name"])
                _ = try ProviderJSON.string(object["arguments"])
                functionItems.append(object)
            default:
                throw ProviderJSON.invalid()
            }
        }
        let canonicalText = try content.compactMap { part -> String? in
            switch part {
            case .text(let value): return value
            case .json(let value): return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            case .reasoning, .providerContinuation: return nil
            }
        }.joined()
        let canonicalReasoning = content.compactMap { part -> String? in
            if case .reasoning(let value) = part { return value }
            return nil
        }.joined()
        guard nativeText == canonicalText, nativeReasoning == canonicalReasoning,
              functionItems.count == calls.count else { throw ProviderJSON.invalid() }
        for (item, call) in zip(functionItems, calls) {
            guard call.completeness == .complete,
                  try ProviderJSON.string(item["call_id"]) == call.id.rawValue,
                  try ProviderJSON.string(item["name"]) == call.name,
                  try ProviderJSON.string(item["arguments"]) == call.argumentsJSON else {
                throw ProviderJSON.invalid()
            }
        }
        return (hasReasoning, nativeReasoning)
    }
}
