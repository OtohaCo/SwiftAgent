import AgentModels
import Foundation

enum AnthropicContinuation {
    static let format = "anthropic.content.v1"

    static func make(blocks: [JSONValue], model: ModelID) throws -> ModelProviderContinuation {
        _ = try visibleContent(blocks)
        return .init(model: model, format: format,
                     payload: try JSONEncoder().encode(JSONValue.object(["content": .array(blocks)])))
    }

    static func restore(content: [ModelContent], calls: [ToolCall], model: ModelID) throws -> [JSONValue]? {
        let matching = content.compactMap { part -> ModelProviderContinuation? in
            guard case .providerContinuation(let state) = part,
                  state.model.provider.utf8.elementsEqual(model.provider.utf8),
                  state.model.name.utf8.elementsEqual(model.name.utf8) else { return nil }
            return state
        }
        guard !matching.isEmpty else { return nil }
        do {
            guard matching.count == 1, let state = matching.first,
                  state.format.utf8.elementsEqual(format.utf8), let payload = String(data: state.payload, encoding: .utf8),
                  case .array(let blocks) = try ProviderJSON.decode(payload)["content"] else { throw ProviderJSON.invalid() }
            let visible = content.filter { if case .providerContinuation = $0 { false } else { true } }
            guard try equal(visible, visibleContent(blocks)) else { throw ProviderJSON.invalid() }
            let nativeCalls = try blocks.compactMap { value -> [String: JSONValue]? in
                let block = try ProviderJSON.object(value)
                return block["type"] == .string("tool_use") ? block : nil
            }
            guard nativeCalls.count == calls.count else { throw ProviderJSON.invalid() }
            for (native, call) in zip(nativeCalls, calls) {
                guard call.completeness == .complete,
                      try ProviderJSON.string(native["id"]).utf8.elementsEqual(call.id.rawValue.utf8),
                      try ProviderJSON.string(native["name"]).utf8.elementsEqual(call.name.utf8),
                      let input = native["input"], try equal(input, JSONValue.decodeToolArguments(call.argumentsJSON)) else {
                    throw ProviderJSON.invalid()
                }
            }
            return blocks
        } catch {
            throw ModelProviderError(kind: .invalidRequest, message: "Provider continuation does not match the canonical message.")
        }
    }

    private static func visibleContent(_ blocks: [JSONValue]) throws -> [ModelContent] {
        var content: [ModelContent] = []
        for value in blocks {
            let block = try ProviderJSON.object(value)
            let part: ModelContent
            switch try ProviderJSON.string(block["type"]) {
            case "text":
                let text = try ProviderJSON.string(block["text"])
                guard !text.isEmpty else { continue }
                part = .text(text)
            case "thinking":
                guard !(try ProviderJSON.string(block["signature"])).isEmpty else { throw ProviderJSON.invalid() }
                let text = try ProviderJSON.string(block["thinking"])
                guard !text.isEmpty else { continue }
                part = .reasoning(text)
            case "redacted_thinking":
                guard !(try ProviderJSON.string(block["data"])).isEmpty else { throw ProviderJSON.invalid() }
                continue
            case "tool_use":
                _ = try ProviderJSON.object(block["input"])
                continue
            default: throw ProviderJSON.invalid()
            }
            switch (content.last, part) {
            case (.text(let a), .text(let b)): content[content.count - 1] = .text(a + b)
            case (.reasoning(let a), .reasoning(let b)): content[content.count - 1] = .reasoning(a + b)
            default: content.append(part)
            }
        }
        return content
    }

    private static func equal<T: Encodable>(_ lhs: T, _ rhs: T) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(lhs) == encoder.encode(rhs)
    }
}
