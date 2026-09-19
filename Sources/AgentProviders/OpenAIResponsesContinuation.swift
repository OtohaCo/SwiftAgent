import AgentModels
import Foundation

enum OpenAIResponsesContinuation {
    static let format = "openai.responses.v2"
    static let legacyFormat = "openai.responses.v1"

    struct Restored {
        let items: [JSONValue]
    }

    private struct Validated {
        let items: [JSONValue]
        let shouldStore: Bool
    }

    private enum ContentKind: Equatable {
        case text
        case reasoning
    }

    static func make(
        items: [JSONValue],
        content: [ModelContent],
        calls: [ToolCall],
        model: ModelID
    ) throws -> ModelProviderContinuation? {
        let validated = try validateCurrent(
            items: items,
            content: content,
            calls: calls,
            allowOmittedVisibleReasoning: false
        )
        guard validated.shouldStore else { return nil }
        let payload = JSONValue.object([
            "items": .array(validated.items),
            "visible_reasoning": .array(visibleReasoning(content).map(JSONValue.string)),
        ])
        return .init(model: model, format: format, payload: try JSONEncoder().encode(payload))
    }

    static func restore(
        content: [ModelContent],
        calls: [ToolCall],
        model: ModelID
    ) throws -> Restored? {
        let matching = content.compactMap { part -> ModelProviderContinuation? in
            guard case .providerContinuation(let state) = part,
                  state.model.provider.utf8.elementsEqual(model.provider.utf8),
                  state.model.name.utf8.elementsEqual(model.name.utf8) else { return nil }
            return state
        }
        guard !matching.isEmpty else { return nil }

        do {
            guard matching.count == 1, let state = matching.first,
                  state.format == format || state.format == legacyFormat,
                  let payload = try? JSONDecoder().decode(JSONValue.self, from: state.payload),
                  case .object(let object) = payload,
                  case .array(let items) = object["items"],
                  case .array(let encodedReasoning) = object["visible_reasoning"] else {
                throw ProviderJSON.invalid()
            }
            let expectedReasoning = try encodedReasoning.map(ProviderJSON.string)
            guard expectedReasoning == visibleReasoning(content) else { throw ProviderJSON.invalid() }

            let validated = state.format == legacyFormat
                ? try migrateLegacy(items: items, content: content, calls: calls)
                : try validateCurrent(
                    items: items,
                    content: content,
                    calls: calls,
                    allowOmittedVisibleReasoning: true
                )
            return .init(items: validated.items)
        } catch {
            throw ModelProviderError(
                kind: .invalidRequest,
                message: "Provider continuation does not match the canonical message."
            )
        }
    }

    private static func validateCurrent(
        items: [JSONValue],
        content: [ModelContent],
        calls: [ToolCall],
        allowOmittedVisibleReasoning: Bool
    ) throws -> Validated {
        func append(_ value: String, as kind: ContentKind, to sequence: inout [(ContentKind, String)]) {
            guard !value.isEmpty else { return }
            if let last = sequence.last, last.0 == kind {
                sequence[sequence.count - 1].1 += value
            } else {
                sequence.append((kind, value))
            }
        }

        var functionItems: [JSONValue] = []
        var messageCount = 0
        var shouldStore = false
        var nativeContent: [(ContentKind, String)] = []
        var replayItems: [JSONValue] = []

        for item in items {
            let object = try ProviderJSON.object(item)
            switch try ProviderJSON.string(object["type"]) {
            case "reasoning":
                let reasoning = try validateReasoning(object)
                append(reasoning.visibleText, as: .reasoning, to: &nativeContent)
                if reasoning.hasEncryptedContent {
                    shouldStore = true
                    replayItems.append(item)
                }
            case "message":
                if case .string(let text) = object["content"], object["id"] == nil, object["status"] == nil {
                    guard try ProviderJSON.string(object["role"]) == "assistant" else { throw ProviderJSON.invalid() }
                    append(text, as: .text, to: &nativeContent)
                    replayItems.append(item)
                    continue
                }
                let message = try validateMessage(object)
                messageCount += 1
                if messageCount > 1 || message.parts.count > 1 || message.requiresNativeReplay {
                    shouldStore = true
                }
                append(message.visibleText, as: .text, to: &nativeContent)
                replayItems.append(item)
            case "function_call":
                try validateFunctionItem(object)
                functionItems.append(item)
                shouldStore = true
                replayItems.append(item)
            default:
                throw ProviderJSON.invalid()
            }
        }

        let canonicalContent = try visibleContent(content)
        guard orderedContentMatches(
                  native: nativeContent,
                  canonical: canonicalContent,
                  allowOmittedVisibleReasoning: allowOmittedVisibleReasoning
              ),
              functionItems.count == calls.count else {
            throw ProviderJSON.invalid()
        }
        for (item, call) in zip(functionItems, calls) {
            let object = try ProviderJSON.object(item)
            guard call.completeness == .complete,
                  try ProviderJSON.string(object["call_id"]).utf8.elementsEqual(call.id.rawValue.utf8),
                  try ProviderJSON.string(object["name"]).utf8.elementsEqual(call.name.utf8),
                  try ProviderJSON.string(object["arguments"]).utf8.elementsEqual(call.argumentsJSON.utf8) else {
                throw ProviderJSON.invalid()
            }
        }
        return .init(items: replayItems, shouldStore: shouldStore)
    }

    private static func migrateLegacy(
        items: [JSONValue],
        content: [ModelContent],
        calls: [ToolCall]
    ) throws -> Validated {
        var migrated: [JSONValue] = []
        for item in items {
            let object = try ProviderJSON.object(item)
            switch try ProviderJSON.string(object["type"]) {
            case "reasoning":
                _ = try validateReasoning(object)
                migrated.append(item)
            case "message":
                let id = try optionalString(object["id"])
                let status = try optionalString(object["status"])
                if id != nil || status != nil {
                    migrated.append(item)
                } else {
                    let text = try legacyMessageText(object)
                    migrated.append(.object([
                        "type": .string("message"),
                        "role": .string("assistant"),
                        "content": .string(text),
                    ]))
                }
            case "function_call":
                try validateFunctionItem(object)
                migrated.append(item)
            default:
                throw ProviderJSON.invalid()
            }
        }
        return try validateCurrent(
            items: migrated,
            content: content,
            calls: calls,
            allowOmittedVisibleReasoning: false
        )
    }

    private struct ReasoningValidation {
        let visibleText: String
        let hasEncryptedContent: Bool
    }

    private static func validateReasoning(_ object: [String: JSONValue]) throws -> ReasoningValidation {
        let id = try ProviderJSON.string(object["id"])
        guard !id.isEmpty, case .array(let summary) = object["summary"] else { throw ProviderJSON.invalid() }
        if let status = object["status"], status != .null,
           try ProviderJSON.string(status) != "completed" {
            throw ProviderJSON.invalid()
        }

        var visible: [String] = []
        for part in summary {
            let part = try ProviderJSON.object(part)
            guard try ProviderJSON.string(part["type"]) == "summary_text" else { throw ProviderJSON.invalid() }
            visible.append(try ProviderJSON.string(part["text"]))
        }
        if let value = object["content"], value != .null {
            guard case .array(let contentParts) = value else { throw ProviderJSON.invalid() }
            for part in contentParts {
                let part = try ProviderJSON.object(part)
                guard try ProviderJSON.string(part["type"]) == "reasoning_text" else { throw ProviderJSON.invalid() }
                visible.append(try ProviderJSON.string(part["text"]))
            }
        }

        let encrypted: String?
        if let value = object["encrypted_content"], value != .null {
            encrypted = try ProviderJSON.string(value)
        } else {
            encrypted = nil
        }
        if let encrypted, encrypted.isEmpty { throw ProviderJSON.invalid() }
        return .init(visibleText: visible.joined(), hasEncryptedContent: encrypted != nil)
    }

    private struct MessageValidation {
        let parts: [JSONValue]
        let visibleText: String
        let requiresNativeReplay: Bool
    }

    private static func validateMessage(_ object: [String: JSONValue]) throws -> MessageValidation {
        guard !(try ProviderJSON.string(object["id"])).isEmpty,
              try ProviderJSON.string(object["role"]) == "assistant",
              try ProviderJSON.string(object["status"]) == "completed",
              case .array(let parts) = object["content"] else {
            throw ProviderJSON.invalid()
        }
        if let phase = object["phase"], phase != .null {
            let value = try ProviderJSON.string(phase)
            guard value == "commentary" || value == "final_answer" else { throw ProviderJSON.invalid() }
        }

        var visible: [String] = []
        var requiresNativeReplay = object["phase"] != nil && object["phase"] != .null
        for part in parts {
            let part = try ProviderJSON.object(part)
            switch try ProviderJSON.string(part["type"]) {
            case "output_text":
                let text = try ProviderJSON.string(part["text"])
                guard case .array(let annotations) = part["annotations"] else { throw ProviderJSON.invalid() }
                if !annotations.isEmpty { requiresNativeReplay = true }
                visible.append(text)
            case "refusal":
                visible.append(try ProviderJSON.string(part["refusal"]))
                requiresNativeReplay = true
            default:
                throw ProviderJSON.invalid()
            }
        }
        return .init(parts: parts, visibleText: visible.joined(), requiresNativeReplay: requiresNativeReplay)
    }

    private static func legacyMessageText(_ object: [String: JSONValue]) throws -> String {
        guard try ProviderJSON.string(object["role"]) == "assistant",
              case .array(let parts) = object["content"] else { throw ProviderJSON.invalid() }
        return try parts.map { part -> String in
            let part = try ProviderJSON.object(part)
            guard try ProviderJSON.string(part["type"]) == "output_text" else { throw ProviderJSON.invalid() }
            return try ProviderJSON.string(part["text"])
        }.joined()
    }

    private static func validateFunctionItem(_ object: [String: JSONValue]) throws {
        let callID = try ProviderJSON.string(object["call_id"])
        let name = try ProviderJSON.string(object["name"])
        _ = try ProviderJSON.string(object["arguments"])
        guard !callID.isEmpty, !name.isEmpty else { throw ProviderJSON.invalid() }
        if let id = object["id"], id != .null, (try ProviderJSON.string(id)).isEmpty {
            throw ProviderJSON.invalid()
        }
        if let status = object["status"], status != .null,
           try ProviderJSON.string(status) != "completed" {
            throw ProviderJSON.invalid()
        }
    }

    private static func visibleContent(_ content: [ModelContent]) throws -> [(ContentKind, String)] {
        var sequence: [(ContentKind, String)] = []
        func append(_ value: String, as kind: ContentKind) {
            guard !value.isEmpty else { return }
            if let last = sequence.last, last.0 == kind {
                sequence[sequence.count - 1].1 += value
            } else {
                sequence.append((kind, value))
            }
        }
        for part in content {
            switch part {
            case .text(let value):
                append(value, as: .text)
            case .json(let value):
                append(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), as: .text)
            case .reasoning(let value):
                append(value, as: .reasoning)
            case .providerContinuation:
                break
            }
        }
        return sequence
    }

    private static func orderedContentMatches(
        native: [(ContentKind, String)],
        canonical: [(ContentKind, String)],
        allowOmittedVisibleReasoning: Bool
    ) -> Bool {
        for kind in [ContentKind.text, .reasoning] {
            if kind == .reasoning, allowOmittedVisibleReasoning,
               native.lazy.filter({ $0.0 == kind }).map(\.1).joined().isEmpty {
                continue
            }
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

    private static func visibleReasoning(_ content: [ModelContent]) -> [String] {
        content.compactMap { part in
            if case .reasoning(let value) = part { return value }
            return nil
        }
    }

    private static func optionalString(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        return try ProviderJSON.string(value)
    }
}
