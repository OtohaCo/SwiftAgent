public enum ModelRole: String, Hashable, Sendable, Codable {
    case system, developer, user, assistant, tool
}

public enum ModelContent: Hashable, Sendable, Codable {
    case text(String)
    case reasoning(String)
    case json(JSONValue)
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
