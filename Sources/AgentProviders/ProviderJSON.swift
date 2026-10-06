import AgentModels
import Foundation

enum ProviderJSON {
    /// History replaces complete arguments that are not one JSON object with
    /// `ToolCall.replacedInvalidArgumentsJSON`. Native function-call items, paired with `calls` in
    /// order, take the same replacement so the continuation still matches. Nothing else is changed:
    /// any other difference still fails continuation validation.
    static func replacingInvalidArguments(in items: [JSONValue], calls: [ToolCall]) -> [JSONValue] {
        var remaining = calls[...]
        return items.map { value in
            guard case .object(var item) = value, item["type"] == .string("function_call"),
                  let call = remaining.popFirst() else { return value }
            guard case .string(let native) = item["arguments"],
                  !native.utf8.elementsEqual(call.argumentsJSON.utf8),
                  call.argumentsJSON == ToolCall.replacedInvalidArgumentsJSON,
                  (try? JSONValue.decodeToolArguments(native)) == nil else { return value }
            item["arguments"] = .string(call.argumentsJSON)
            return .object(item)
        }
    }

    /// Request bodies, and JSON text sent inside them, with object keys in order. Services cache a prompt by its
    /// prefix, so a conversation's earlier turns must be the same bytes in every request; a dictionary's own order
    /// differs from one encoding to the next.
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func text<Value: Encodable>(_ value: Value) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }

    static func object(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard case .object(let object) = value else { throw invalid() }
        return object
    }

    static func decode(_ text: String) throws -> [String: JSONValue] {
        guard let value = try? JSONValue.decodeToolArguments(text) else { throw invalid() }
        return try object(value)
    }

    static func string(_ value: JSONValue?) throws -> String {
        guard case .string(let string) = value else { throw invalid() }
        return string
    }

    static func count(_ value: JSONValue?) throws -> Int? {
        guard let value, value != .null else { return nil }
        guard case .number(let number) = value, number >= 0, number <= Decimal(Int.max) else { throw invalid() }
        let integer = NSDecimalNumber(decimal: number).intValue
        guard Decimal(integer) == number else { throw invalid() }
        return integer
    }

    static func invalid() -> ModelProviderError {
        .init(kind: .invalidResponse, message: "Invalid provider response.",
              diagnostic: .init(stage: .responseDecoding, reason: .invalidShape))
    }
}
