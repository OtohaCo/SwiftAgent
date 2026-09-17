import AgentModels

/// Explicit JSON Schema declarations. Validation belongs to the tool registry.
public struct ToolSchema: Hashable, Sendable {
    public let json: JSONValue

    public init(json: JSONValue) {
        self.json = json
    }

    public static let string = Self(json: .object(["type": .string("string")]))
    public static let integer = Self(json: .object(["type": .string("integer")]))
    public static let number = Self(json: .object(["type": .string("number")]))
    public static let boolean = Self(json: .object(["type": .string("boolean")]))
    public static let null = Self(json: .object(["type": .string("null")]))

    public static func object(
        properties: [String: ToolSchema],
        required: Set<String> = [],
        additionalProperties: Bool = false
    ) -> Self {
        Self(json: .object([
            "type": .string("object"),
            "properties": .object(properties.mapValues(\.json)),
            "required": .array(required.sorted().map(JSONValue.string)),
            "additionalProperties": .bool(additionalProperties),
        ]))
    }

    public static func array(items: ToolSchema) -> Self {
        Self(json: .object(["type": .string("array"), "items": items.json]))
    }

    public static func enumeration(_ values: [JSONValue]) -> Self {
        Self(json: .object(["enum": .array(values)]))
    }
}
