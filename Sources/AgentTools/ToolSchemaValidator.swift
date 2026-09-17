import AgentModels
import Foundation

/// A supported subset of JSON Schema. Unsupported constraints must fail registration.
public struct ToolSchemaValidator: Sendable {
    private let schema: JSONValue

    public init(schema: ToolSchema) throws {
        do { _ = try JSONEncoder().encode(schema.json) }
        catch { throw ToolSchemaValidationError(kind: .invalidSchema, path: "", keyword: "JSON") }
        try Self.checkSchema(schema.json, path: "")
        self.schema = schema.json
    }

    public func validate(_ value: JSONValue) throws {
        do { _ = try JSONEncoder().encode(value) }
        catch { throw Self.violation("", "JSON") }
        try Self.validate(value, schema: schema, path: "")
    }

    private static let types: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]
    private static let keywords: Set<String> = [
        "type", "enum", "const", "properties", "required", "additionalProperties", "items",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
        "minItems", "maxItems", "minLength", "maxLength",
        "title", "description", "$comment", "default", "examples",
    ]

    private static func checkSchema(_ schema: JSONValue, path: String) throws {
        if case .bool = schema { return }
        guard let rules = schema.objectValue else {
            throw ToolSchemaValidationError(kind: .invalidSchema, path: path, keyword: "schema")
        }
        for key in rules.keys.sorted() {
            let location = childPath(path, key)
            guard keywords.contains(key) else {
                throw ToolSchemaValidationError(kind: .unsupportedKeyword, path: location, keyword: key)
            }
            guard let value = rules[key] else { continue }
            switch key {
            case "type":
                let names = value.stringValue.map { [$0] } ?? value.arrayValue?.compactMap(\.stringValue) ?? []
                try require(!names.isEmpty && Set(names).count == names.count && Set(names).isSubset(of: types)
                            && (value.stringValue != nil || names.count == value.arrayValue?.count), location, key)
            case "enum":
                guard let values = value.arrayValue else { try require(false, location, key); continue }
                let unique = values.enumerated().allSatisfy { index, value in
                    !values.prefix(index).contains(where: { jsonEqual($0, value) })
                }
                try require(!values.isEmpty && unique, location, key)
            case "required":
                guard let values = value.arrayValue else { try require(false, location, key); continue }
                let names = values.compactMap(\.stringValue)
                try require(names.count == values.count && Set(names.map { Array($0.utf8) }).count == names.count, location, key)
            case "properties":
                guard let properties = value.objectValue else { try require(false, location, key); continue }
                for name in properties.keys.sorted() {
                    if let nested = properties[name] { try checkSchema(nested, path: childPath(location, name)) }
                }
            case "items", "additionalProperties": try checkSchema(value, path: location)
            case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum":
                try require(value.numberValue != nil, location, key)
            case "minItems", "maxItems", "minLength", "maxLength":
                guard let number = value.numberValue else { try require(false, location, key); continue }
                try require(number >= 0 && isInteger(number), location, key)
            case "title", "description", "$comment": try require(value.stringValue != nil, location, key)
            case "examples": try require(value.arrayValue != nil, location, key)
            default: break
            }
        }
    }

    private static func require(_ condition: Bool, _ path: String, _ keyword: String) throws {
        if !condition { throw ToolSchemaValidationError(kind: .invalidSchema, path: path, keyword: keyword) }
    }

    private static func validate(_ value: JSONValue, schema: JSONValue, path: String) throws {
        if case .bool(let allowed) = schema {
            guard allowed else { throw violation(path, "false") }
            return
        }
        guard let rules = schema.objectValue else { throw violation(path, "schema") }
        if let type = rules["type"] {
            let types = type.stringValue.map { [$0] } ?? type.arrayValue?.compactMap(\.stringValue) ?? []
            guard types.contains(where: { matches(value, type: $0) }) else { throw violation(path, "type") }
        }
        if let options = rules["enum"]?.arrayValue, !options.contains(where: { jsonEqual($0, value) }) { throw violation(path, "enum") }
        if let constant = rules["const"], !jsonEqual(constant, value) { throw violation(path, "const") }
        if case .number(let number) = value {
            let bounds: [(String, Bool)] = [
                ("minimum", rules["minimum"]?.numberValue.map { number >= $0 } ?? true),
                ("maximum", rules["maximum"]?.numberValue.map { number <= $0 } ?? true),
                ("exclusiveMinimum", rules["exclusiveMinimum"]?.numberValue.map { number > $0 } ?? true),
                ("exclusiveMaximum", rules["exclusiveMaximum"]?.numberValue.map { number < $0 } ?? true),
            ]
            if let failed = bounds.first(where: { !$0.1 }) { throw violation(path, failed.0) }
        }
        if case .string(let text) = value {
            try checkCount(text.unicodeScalars.count, rules: rules, suffix: "Length", path: path)
        }
        if case .object(let object) = value {
            for key in rules["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where exactValue(object, key) == nil {
                throw violation(childPath(path, key), "required")
            }
            let properties = rules["properties"]?.objectValue ?? [:]
            for key in object.keys.sorted() {
                guard let nested = object[key] else { continue }
                let child = exactValue(properties, key) ?? rules["additionalProperties"] ?? .bool(true)
                try validate(nested, schema: child, path: childPath(path, key))
            }
        }
        if case .array(let array) = value {
            try checkCount(array.count, rules: rules, suffix: "Items", path: path)
            if let items = rules["items"] {
                for (index, item) in array.enumerated() {
                    try validate(item, schema: items, path: childPath(path, String(index)))
                }
            }
        }
    }

    private static func checkCount(_ count: Int, rules: [String: JSONValue], suffix: String, path: String) throws {
        if let minimum = rules["min" + suffix]?.numberValue, Decimal(count) < minimum { throw violation(path, "min" + suffix) }
        if let maximum = rules["max" + suffix]?.numberValue, Decimal(count) > maximum { throw violation(path, "max" + suffix) }
    }

    static func exactValue(_ object: [String: JSONValue], _ key: String) -> JSONValue? {
        object.first(where: { $0.key.utf8.elementsEqual(key.utf8) })?.value
    }

    static func jsonEqual(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a.utf8.elementsEqual(b.utf8)
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { jsonEqual($0, $1) }
        case (.object(let a), .object(let b)):
            return a.count == b.count && a.allSatisfy { key, value in
                guard let other = exactValue(b, key) else { return false }
                return jsonEqual(value, other)
            }
        default: return false
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (value, type) {
        case (.null, "null"), (.bool, "boolean"), (.string, "string"),
             (.object, "object"), (.array, "array"), (.number, "number"): return true
        case (.number(let number), "integer"): return isInteger(number)
        default: return false
        }
    }

    private static func isInteger(_ value: Decimal) -> Bool {
        var number = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &number, 0, .plain)
        return !value.isNaN && rounded == value
    }

    private static func childPath(_ parent: String, _ key: String) -> String {
        parent + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    private static func violation(_ path: String, _ keyword: String) -> ToolSchemaValidationError {
        ToolSchemaValidationError(kind: .violation, path: path, keyword: keyword)
    }
}

public struct ToolSchemaValidationError: Error, Equatable, Sendable {
    public enum Kind: Sendable { case invalidSchema, unsupportedKeyword, violation }
    public let kind: Kind
    /// JSON Pointer into the schema (registration errors) or value (validation errors).
    public let path: String
    public let keyword: String
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var numberValue: Decimal? { if case .number(let value) = self { value } else { nil } }
}
