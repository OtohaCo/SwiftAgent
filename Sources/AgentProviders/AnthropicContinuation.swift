import AgentModels
import Foundation

enum AnthropicContinuation {
    static let format = "anthropic.content.v1"

    static func make(blocks: [JSONValue], model: ModelID, requestPrefix: JSONValue? = nil) throws -> ModelProviderContinuation {
        _ = try visibleContent(blocks)
        var payload: [String: JSONValue] = ["content": .array(blocks)]
        if containsThinking(blocks), let requestPrefix {
            payload["prefixDigest"] = .string(try prefixDigest(requestPrefix))
        }
        return .init(model: model, format: format, payload: try ProviderJSON.encode(JSONValue.object(payload)))
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

    static func containsThinking(_ blocks: [JSONValue]) -> Bool {
        blocks.contains { value in
            guard case .object(let block) = value else { return false }
            return block["type"] == .string("thinking") || block["type"] == .string("redacted_thinking")
        }
    }

    /// A local witness of the encoded prefix, never verification of the vendor signature.
    static func validatePrefix(content: [ModelContent], blocks: [JSONValue], prefix: JSONValue) throws {
        guard containsThinking(blocks) else { return }
        let state = content.compactMap { part -> ModelProviderContinuation? in
            if case .providerContinuation(let value) = part { value } else { nil }
        }.first
        guard let state, let payload = try? JSONDecoder().decode(JSONValue.self, from: state.payload),
              case .object(let object) = payload, case .string(let digest) = object["prefixDigest"],
              digest == (try prefixDigest(prefix)) else {
            throw ModelProviderError(kind: .invalidRequest,
                message: "Anthropic signed thinking requires its unchanged system, tools and preceding messages, with an RC6 prefix witness. Use fixed declarations and an append-only request view; do not retry the Run.")
        }
    }

    static func prefix(system: JSONValue?, tools: JSONValue?, messages: [JSONValue]) -> JSONValue {
        func blocksWithoutCache(_ value: JSONValue) -> JSONValue {
            guard case .array(let blocks) = value else { return value }
            return .array(blocks.map { value in
                guard case .object(var block) = value else { return value }
                block.removeValue(forKey: "cache_control")
                if let content = block["content"] { block["content"] = blocksWithoutCache(content) }
                return .object(block)
            })
        }
        let strippedMessages = messages.map { value -> JSONValue in
            guard case .object(var message) = value else { return value }
            if let content = message["content"] { message["content"] = blocksWithoutCache(content) }
            return .object(message)
        }
        return .object(["system": system.map(blocksWithoutCache) ?? .null,
                        "tools": tools.map(blocksWithoutCache) ?? .null,
                        "messages": .array(strippedMessages)])
    }

    private static func prefixDigest(_ prefix: JSONValue) throws -> String {
        ModelImageDigest.sha256Hex(try ProviderJSON.encode(prefix))
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
