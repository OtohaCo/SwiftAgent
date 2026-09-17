import AgentModels
import AgentTools
import Foundation
import Testing

struct ToolSchemaTests {
    @Test func buildersProduceNativeSchemaWithoutJSONStringAssembly() throws {
        let schema = ToolSchema.object(properties: [
            "a": .integer, "b": .integer, "tags": .array(items: .string),
        ], required: ["b", "a"])
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "a": .object(["type": .string("integer")]),
                "b": .object(["type": .string("integer")]),
                "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            ]),
            "required": .array([.string("a"), .string("b")]),
            "additionalProperties": .bool(false),
        ])
        #expect(schema.json == expected)
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(schema.json)) == expected)
    }

    @Test func explicitSchemaBridgePreservesConstraints() {
        let json: JSONValue = .object(["type": .string("number"), "minimum": .number(0)])
        #expect(ToolSchema(json: json).json == json)
        #expect(ToolSchema.enumeration([.string("open"), .string("closed")]).json == .object([
            "enum": .array([.string("open"), .string("closed")]),
        ]))
    }

    @Test func scalarBuildersKeepNumberBooleanAndNullDistinct() {
        for (schema, name) in [(ToolSchema.number, "number"), (.boolean, "boolean"), (.null, "null")] {
            #expect(schema.json == .object(["type": .string(name)]))
        }
    }
}
