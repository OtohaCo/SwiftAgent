import AgentModels
import AgentTools
import Foundation
import Testing

struct ToolSchemaValidatorTests {
    @Test func validatesNestedObjectsArraysRequiredAndEnums() throws {
        let schema = ToolSchema.object(properties: [
            "items": .array(items: .object(properties: [
                "id": .string, "state": .enumeration([.string("open"), .string("closed")]),
            ], required: ["id", "state"])),
        ], required: ["items"])
        let validator = try ToolSchemaValidator(schema: schema)
        try validator.validate(.object(["items": .array([.object(["id": .string("r1"), "state": .string("open")])])]))
        for input: JSONValue in [
            .object([:]), .object(["items": .null]), .object(["items": .array([]), "extra": .bool(true)]),
            .object(["items": .array([.object(["id": .number(1), "state": .string("open")])])]),
            .object(["items": .array([.object(["id": .string("r1"), "state": .string("unknown")])])]),
        ] {
            #expect(throws: (any Error).self) { try validator.validate(input) }
        }
    }

    @Test func numericBooleanAndNullTypesStayDistinct() throws {
        let integer = try ToolSchemaValidator(schema: .integer)
        try integer.validate(.number(Decimal(string: "9007199254740993")!))
        #expect(throws: (any Error).self) { try integer.validate(.bool(true)) }
        #expect(throws: (any Error).self) { try integer.validate(.number(1.5)) }
        let nullable = try ToolSchemaValidator(schema: .init(json: .object([
            "type": .array([.string("string"), .string("null")]),
        ])))
        try nullable.validate(.null)
        try nullable.validate(.string("value"))
        #expect(throws: (any Error).self) { try nullable.validate(.number(1)) }
    }

    @Test func malformedSchemaIsRejectedBeforeAnyInstanceValidation() {
        let schemas: [JSONValue] = [
            .null, .array([]), .object(["type": .string("invented")]),
            .object(["type": .array([])]), .object(["type": .array([.string("string"), .string("string")])]),
            .object(["required": .array([.number(1)])]), .object(["required": .array([.string("x"), .string("x")])]),
            .object(["properties": .array([])]), .object(["additionalProperties": .string("false")]),
            .object(["items": .number(1)]), .object(["enum": .array([])]),
            .object(["enum": .array([.number(1), .number(1)])]),
            .object(["description": .bool(true)]), .object(["default": .number(.nan)]),
        ]
        for schema in schemas {
            #expect(throws: (any Error).self) { try ToolSchemaValidator(schema: .init(json: schema)) }
        }
    }

    @Test func unsupportedNestedConstraintsFailClosed() {
        let schema = ToolSchema.object(properties: ["query": .init(json: .object([
            "type": .string("string"), "pattern": .string("^safe$"),
        ]))])
        do {
            _ = try ToolSchemaValidator(schema: schema)
            Issue.record("Unsupported pattern was ignored")
        } catch let error as ToolSchemaValidationError {
            #expect(error.kind == .unsupportedKeyword)
            #expect(error.path == "/properties/query/pattern")
            #expect(error.keyword == "pattern")
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func additionalPropertySchemasAndBooleanSchemasWork() throws {
        let validator = try ToolSchemaValidator(schema: .init(json: .object([
            "additionalProperties": .object(["type": .string("integer")]),
        ])))
        try validator.validate(.object(["a": .number(2)]))
        #expect(throws: (any Error).self) { try validator.validate(.object(["a": .bool(true)])) }
        try ToolSchemaValidator(schema: .init(json: .bool(true))).validate(.null)
        #expect(throws: (any Error).self) { try ToolSchemaValidator(schema: .init(json: .bool(false))).validate(.null) }
        #expect(throws: (any Error).self) { try ToolSchemaValidator(schema: .init(json: .bool(true))).validate(.number(.nan)) }
    }

    @Test func numericBoundsRespectInclusiveAndExclusiveEdges() throws {
        let cases: [(String, Decimal, Decimal)] = [
            ("minimum", 2, 1), ("maximum", 2, 3),
            ("exclusiveMinimum", 3, 2), ("exclusiveMaximum", 1, 2),
        ]
        for (keyword, accepted, rejected) in cases {
            let validator = try ToolSchemaValidator(schema: .init(json: .object([
                "type": .string("number"), keyword: .number(2),
            ])))
            try validator.validate(.number(accepted))
            #expect(throws: (any Error).self) { try validator.validate(.number(rejected)) }
            #expect(throws: (any Error).self) { try ToolSchemaValidator(schema: .init(json: .object([keyword: .bool(true)]))) }
        }
    }

    @Test func lengthsCountUnicodeScalarsAndArrayElements() throws {
        let cases: [(String, JSONValue, JSONValue)] = [
            ("minLength", .string("e\u{301}"), .string("e")),
            ("maxLength", .string("ok"), .string("abc")),
            ("minItems", .array([.null, .null]), .array([.null])),
            ("maxItems", .array([.null, .null]), .array([.null, .null, .null])),
        ]
        for (keyword, accepted, rejected) in cases {
            let validator = try ToolSchemaValidator(schema: .init(json: .object([keyword: .number(2)])))
            try validator.validate(accepted)
            #expect(throws: (any Error).self) { try validator.validate(rejected) }
            for limit: JSONValue in [.number(-1), .number(1.5), .string("2")] {
                #expect(throws: (any Error).self) { try ToolSchemaValidator(schema: .init(json: .object([keyword: limit]))) }
            }
        }
    }

    @Test func constAndPointerDiagnosticsPreserveValueKinds() throws {
        let validator = try ToolSchemaValidator(schema: .object(properties: [
            "a/b~c": .init(json: .object(["const": .bool(true)])),
        ], required: ["a/b~c"]))
        try validator.validate(.object(["a/b~c": .bool(true)]))
        do {
            try validator.validate(.object(["a/b~c": .number(1)]))
            Issue.record("Boolean const accepted a number")
        } catch let error as ToolSchemaValidationError {
            #expect(error.path == "/a~1b~0c")
            #expect(error.keyword == "const")
        }
    }

    @Test func schemaStringsUseExactCodePointsRatherThanCanonicalEquivalence() throws {
        let composed = "\u{E9}"
        let decomposed = "e\u{301}"
        for schema in [ToolSchema.enumeration([.string(composed)]), .init(json: .object(["const": .string(composed)]))] {
            let validator = try ToolSchemaValidator(schema: schema)
            try validator.validate(.string(composed))
            #expect(throws: (any Error).self) { try validator.validate(.string(decomposed)) }
        }
        _ = try ToolSchemaValidator(schema: .enumeration([.string(composed), .string(decomposed)]))
        let required = try ToolSchemaValidator(schema: .object(properties: [composed: .integer], required: [composed]))
        #expect(throws: (any Error).self) { try required.validate(.object([decomposed: .number(1)])) }
        let optional = try ToolSchemaValidator(schema: .object(properties: [composed: .integer]))
        #expect(throws: (any Error).self) { try optional.validate(.object([decomposed: .number(1)])) }
        let nested = try ToolSchemaValidator(schema: .init(json: .object(["const": .object([composed: .array([.string(composed)])])])))
        #expect(throws: (any Error).self) { try nested.validate(.object([decomposed: .array([.string(decomposed)])])) }
    }
}
