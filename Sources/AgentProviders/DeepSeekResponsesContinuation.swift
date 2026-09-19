import AgentModels
import Foundation

enum DeepSeekResponsesContinuation {
    static let format = "deepseek.responses.v1"

    struct Restored { let items: [JSONValue] }
    private enum ContentKind: String, Equatable { case text, reasoning }
    private enum ContentBinding {
        // Final native items retain totals but not cross-item streaming order.
        case observed
        case stored([(ContentKind, String)])
        case legacy
    }

    static func make(
        items: [JSONValue], content: [ModelContent], calls: [ToolCall], model: ModelID
    ) throws -> ModelProviderContinuation? {
        let items = try replayableItems(items)
        let validated = try validate(
            items: items, content: content, calls: calls, contentBinding: .observed
        )
        guard validated.hasReasoning else { return nil }
        return .init(model: model, format: format, payload: try JSONEncoder().encode(JSONValue.object([
            "items": .array(items),
            "visible_content_order": encodeVisibleContent(try visibleContent(content)),
        ])))
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
                  case .object(let object) = payload, case .array(let storedItems) = object["items"] else {
                throw ProviderJSON.invalid()
            }
            let items = try replayableItems(storedItems)
            let binding: ContentBinding
            if let encodedContent = object["visible_content_order"] {
                binding = .stored(try decodeVisibleContent(encodedContent))
            } else {
                binding = .legacy
            }
            let validated = try validate(
                items: items, content: content, calls: calls, contentBinding: binding
            )
            guard validated.hasReasoning else { throw ProviderJSON.invalid() }
            return .init(items: items)
        } catch {
            throw ModelProviderError(kind: .invalidRequest,
                                     message: "DeepSeek continuation does not match the canonical message.")
        }
    }

    private static func validate(
        items: [JSONValue], content: [ModelContent], calls: [ToolCall], contentBinding: ContentBinding
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
                guard case .array(let parts) = object["content"], !parts.isEmpty else {
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
        let canonicalContent = try visibleContent(content)
        guard contentTotalsMatch(native: nativeContent, canonical: canonicalContent),
              contentOrderMatches(native: nativeContent, canonical: canonicalContent, binding: contentBinding),
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

    private static func replayableItems(_ items: [JSONValue]) throws -> [JSONValue] {
        try items.map { value in
            var object = try ProviderJSON.object(value)
            if try ProviderJSON.string(object["type"]) == "reasoning" {
                // DeepSeek may return output-only compatibility metadata that its
                // Responses input does not accept. Plaintext reasoning remains
                // fully bound to canonical content and is the replay authority.
                object.removeValue(forKey: "summary")
                object.removeValue(forKey: "encrypted_content")
            }
            return .object(object)
        }
    }

    private static func visibleContent(_ content: [ModelContent]) throws -> [(ContentKind, String)] {
        var result: [(ContentKind, String)] = []
        func append(_ value: String, as kind: ContentKind) {
            guard !value.isEmpty else { return }
            if let last = result.last, last.0 == kind { result[result.count - 1].1 += value }
            else { result.append((kind, value)) }
        }
        for part in content {
            switch part {
            case .text(let value): append(value, as: .text)
            case .json(let value):
                append(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), as: .text)
            case .reasoning(let value): append(value, as: .reasoning)
            case .providerContinuation: break
            }
        }
        return result
    }

    private static func contentTotalsMatch(
        native: [(ContentKind, String)],
        canonical: [(ContentKind, String)]
    ) -> Bool {
        for kind in [ContentKind.text, .reasoning] {
            guard contentValue(native, kind: kind) == contentValue(canonical, kind: kind) else {
                return false
            }
        }
        return true
    }

    private static func contentValue(_ content: [(ContentKind, String)], kind: ContentKind) -> String {
        content.reduce(into: "") { result, part in
            if part.0 == kind { result += part.1 }
        }
    }

    private static func contentOrderMatches(
        native: [(ContentKind, String)],
        canonical: [(ContentKind, String)],
        binding: ContentBinding
    ) -> Bool {
        switch binding {
        case .observed:
            return true
        case .stored(let stored):
            return exactContentMatch(stored, canonical)
        case .legacy:
            var nativeIndex = 0
            for (kind, _) in canonical where nativeIndex < native.count {
                if native[nativeIndex].0 == kind { nativeIndex += 1 }
            }
            return nativeIndex == native.count
        }
    }

    private static func exactContentMatch(
        _ lhs: [(ContentKind, String)],
        _ rhs: [(ContentKind, String)]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.0 == right.0 && left.1 == right.1
        }
    }

    private static func encodeVisibleContent(_ content: [(ContentKind, String)]) -> JSONValue {
        .array(content.map { part in
            .object(["kind": .string(part.0.rawValue), "value": .string(part.1)])
        })
    }

    private static func decodeVisibleContent(_ value: JSONValue) throws -> [(ContentKind, String)] {
        guard case .array(let values) = value else { throw ProviderJSON.invalid() }
        var result: [(ContentKind, String)] = []
        for value in values {
            let object = try ProviderJSON.object(value)
            guard let kind = ContentKind(rawValue: try ProviderJSON.string(object["kind"])) else {
                throw ProviderJSON.invalid()
            }
            let text = try ProviderJSON.string(object["value"])
            guard !text.isEmpty, result.last?.0 != kind else { throw ProviderJSON.invalid() }
            result.append((kind, text))
        }
        return result
    }
}
