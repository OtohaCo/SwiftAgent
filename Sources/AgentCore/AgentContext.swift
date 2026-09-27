import Foundation
import AgentModels

/// Distinguishes a single oversized input from accumulated conversation that
/// must go through the context policy.
public enum AgentContextError: Error, Equatable, Sendable {
    case inputTooLarge(bytes: Int, limit: Int)
    case historyTooLarge(bytes: Int, limit: Int)
}

/// Bounds the model-facing active history. A single oversized input and an
/// accumulated history over the limit fail explicitly. Request projectors can
/// shorten a model view without erasing formal conversation messages.
public struct AgentContextPolicy: Sendable {
    public var maxInputUTF8Bytes: Int
    public var maxModelContextUTF8Bytes: Int
    public static let `default` = AgentContextPolicy(
        maxInputUTF8Bytes: 8 * 1024 * 1024,
        maxModelContextUTF8Bytes: 12 * 1024 * 1024
    )

    public init(
        maxInputUTF8Bytes: Int = AgentContextPolicy.default.maxInputUTF8Bytes,
        maxModelContextUTF8Bytes: Int = AgentContextPolicy.default.maxModelContextUTF8Bytes
    ) {
        self.maxInputUTF8Bytes = maxInputUTF8Bytes
        self.maxModelContextUTF8Bytes = maxModelContextUTF8Bytes
    }

    func checkInput(_ text: String) throws {
        let bytes = text.utf8.count
        guard bytes <= maxInputUTF8Bytes else {
            throw AgentContextError.inputTooLarge(bytes: bytes, limit: maxInputUTF8Bytes)
        }
    }
}

enum AgentContextWindow {
    static func applyingCurrentInstructions(_ history: [ModelMessage], instructions: String) -> [ModelMessage] {
        let conversation = history.filter { message in
            switch message {
            case .system, .developer: false
            default: true
            }
        }
        var restored: [ModelMessage] = []
        if !instructions.isEmpty {
            restored.append(.system(instructions))
        }
        restored.append(contentsOf: conversation)
        return restored
    }

    static func encodedByteCount(_ messages: [ModelMessage]) throws -> Int {
        try JSONEncoder().encode(messages).count
    }
}
