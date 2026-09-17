import Foundation

public struct ModelID: Hashable, Sendable, Codable {
    /// An open namespace, not an enumeration of supported vendors.
    public let provider: String
    public let name: String

    public init(provider: String, name: String) {
        self.provider = provider
        self.name = name
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.provider.utf8.elementsEqual(rhs.provider.utf8) && lhs.name.utf8.elementsEqual(rhs.name.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(provider.utf8))
        hasher.combine(Array(name.utf8))
    }
}

/// A declaration visible to the model. Execution policy belongs to the tool runtime.
public struct ModelToolDefinition: Hashable, Sendable, Codable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue?

    public init(name: String, description: String, inputSchema: JSONValue, outputSchema: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }
}

/// A requested JSON Schema contract; providers must report unsupported constraints.
public struct StructuredOutputSchema: Hashable, Sendable, Codable {
    public let name: String
    public let description: String?
    public let schema: JSONValue
    public let strict: Bool

    public init(name: String, description: String? = nil, schema: JSONValue, strict: Bool = true) {
        self.name = name
        self.description = description
        self.schema = schema
        self.strict = strict
    }
}

/// One model turn. Run budgets, tool executors and retries belong to the caller.
public struct ModelRequest: Hashable, Sendable, Codable {
    public let model: ModelID
    public let messages: [ModelMessage]
    public let tools: [ModelToolDefinition]
    public let structuredOutput: StructuredOutputSchema?
    /// Optional caller identity used by cross-turn infrastructure such as fallback guards.
    public let sessionID: UUID?
    public let runID: UUID?

    public init(
        model: ModelID,
        messages: [ModelMessage],
        tools: [ModelToolDefinition] = [],
        structuredOutput: StructuredOutputSchema? = nil,
        sessionID: UUID? = nil,
        runID: UUID? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.structuredOutput = structuredOutput
        self.sessionID = sessionID
        self.runID = runID
    }
}
