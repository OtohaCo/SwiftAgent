import AgentModels
import Foundation

enum DeepSeekResponsesContinuation {
    static let format = "deepseek.responses.v1"

    struct Restored { let items: [JSONValue] }
    private enum ContentKind: Equatable { case text, reasoning }

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
        func append(_ value: String, as kind: ContentKind, to sequence: inout [(ContentKind, String)]) {
            guard !value.isEmpty else { return }
            if let last = sequence.last, last.0 == kind {
                sequence[sequence.count - 1].1 += value
            } else {
                sequence.append((kind, value))
            }
        }

        var nativeContent: [(ContentKind, String)] = []
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
                    append(text, as: .reasoning, to: &nativeContent)
                }
            case "message":
                guard try ProviderJSON.string(object["role"]) == "assistant" else { throw ProviderJSON.invalid() }
                if case .string(let text) = object["content"] {
                    append(text, as: .text, to: &nativeContent)
                } else {
                    guard case .array(let parts) = object["content"] else { throw ProviderJSON.invalid() }
                    for value in parts {
                        let part = try ProviderJSON.object(value)
                        guard try ProviderJSON.string(part["type"]) == "output_text" else {
                            throw ProviderJSON.invalid()
                        }
                        append(try ProviderJSON.string(part["text"]), as: .text, to: &nativeContent)
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
        var canonicalContent: [(ContentKind, String)] = []
        for part in content {
            switch part {
            case .text(let value): append(value, as: .text, to: &canonicalContent)
            case .json(let value):
                append(String(decoding: try JSONEncoder().encode(value), as: UTF8.self),
                       as: .text, to: &canonicalContent)
            case .reasoning(let value): append(value, as: .reasoning, to: &canonicalContent)
            case .providerContinuation: break
            }
        }
        guard orderedContentMatches(native: nativeContent, canonical: canonicalContent),
              functionItems.count == calls.count else { throw ProviderJSON.invalid() }
        for (item, call) in zip(functionItems, calls) {
            guard call.completeness == .complete,
                  try ProviderJSON.string(item["call_id"]) == call.id.rawValue,
                  try ProviderJSON.string(item["name"]) == call.name,
                  try ProviderJSON.string(item["arguments"]) == call.argumentsJSON else {
                throw ProviderJSON.invalid()
            }
        }
        let visibleReasoning = nativeContent.reduce(into: "") { result, part in
            if part.0 == .reasoning { result += part.1 }
        }
        return (hasReasoning, visibleReasoning)
    }

    private static func orderedContentMatches(
        native: [(ContentKind, String)],
        canonical: [(ContentKind, String)]
    ) -> Bool {
        for kind in [ContentKind.text, .reasoning] {
            guard native.lazy.filter({ $0.0 == kind }).map(\.1).joined()
                    == canonical.lazy.filter({ $0.0 == kind }).map(\.1).joined() else {
                return false
            }
        }

        var nativeIndex = 0
        for (kind, _) in canonical where nativeIndex < native.count {
            if native[nativeIndex].0 == kind { nativeIndex += 1 }
        }
        return nativeIndex == native.count
    }
}
