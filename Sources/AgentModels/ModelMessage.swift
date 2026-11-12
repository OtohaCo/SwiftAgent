import Foundation
public enum ModelRole: String, Hashable, Sendable, Codable {
    case system, developer, user, assistant, tool
}

public enum ModelContent: Hashable, Sendable, Codable {
    case text(String)
    case reasoning(String)
    case json(JSONValue)
    case providerContinuation(ModelProviderContinuation)
    /// An image in a user message or tool result. Assistant content never carries images.
    case image(ModelImage)
    /// Host-managed file input. Adapters decide eligible roles; currently Gemini accepts user files.
    case file(ModelFileReference)
}

/// Canonical message data. Tool results have their own role and call identity.
public enum ModelMessage: Hashable, Sendable, Codable {
    case system(String)
    case developer(String)
    case user([ModelContent])
    case assistant(content: [ModelContent], toolCalls: [ToolCall])
    case tool(ToolResultMessage)

    public var role: ModelRole {
        switch self {
        case .system: .system
        case .developer: .developer
        case .user: .user
        case .assistant: .assistant
        case .tool: .tool
        }
    }
}

public struct ToolCallID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    /// Identities of calls a Host made outside a model turn (ADR 0011) begin with this. A model's proposal using it is
    /// refused, so such a call in history was never a model's, and no provider produced reasoning or state for it.
    package static let hostCallPrefix = "host-call-"
    package var isHostCall: Bool { rawValue.utf8.starts(with: Self.hostCallPrefix.utf8) }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(rawValue.utf8))
    }
}

public struct ToolCall: Hashable, Sendable, Codable {
    /// Transport completeness only; complete arguments still require schema validation.
    public enum Completeness: String, Hashable, Sendable, Codable {
        case incomplete, complete
    }

    public let id: ToolCallID
    public let name: String
    /// Raw text preserves malformed or truncated arguments without repairing them.
    public let argumentsJSON: String
    public let completeness: Completeness

    /// What conversation history holds in place of complete arguments that are not one JSON object.
    /// The model is told in the call's result that its arguments were invalid; every provider needs a
    /// call's input to be an object, and a provider continuation replays the same replacement.
    package static let replacedInvalidArgumentsJSON = "{}"

    /// Whether every model API accepts `name` for a tool call: letters, digits, "_" and "-", at most 64.
    public static func isPortableName(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count)
            && name.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D }
    }

    /// The name a call goes by in a request to another model: its own when portable, otherwise a stable stand-in made from
    /// it (`tool_` and 32 hexadecimal digits of its SHA-256), the same on every request. Histories keep the original.
    public static func portableName(for name: String) -> String {
        isPortableName(name) ? name : "tool_" + String(ModelImageDigest.sha256Hex(Data(name.utf8)).prefix(32))
    }

    public init(
        id: ToolCallID,
        name: String,
        argumentsJSON: String,
        completeness: Completeness = .incomplete
    ) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.completeness = completeness
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.completeness == rhs.completeness
            && lhs.name.utf8.elementsEqual(rhs.name.utf8)
            && lhs.argumentsJSON.utf8.elementsEqual(rhs.argumentsJSON.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(completeness)
        hasher.combine(Array(name.utf8))
        hasher.combine(Array(argumentsJSON.utf8))
    }
}

/// Model-facing output, not proof of an external effect or a mutation receipt.
public struct ToolResultMessage: Hashable, Sendable, Codable {
    public let callID: ToolCallID
    public let content: [ModelContent]
    public let isError: Bool

    public init(callID: ToolCallID, content: [ModelContent], isError: Bool) {
        self.callID = callID
        self.content = content
        self.isError = isError
    }
}
