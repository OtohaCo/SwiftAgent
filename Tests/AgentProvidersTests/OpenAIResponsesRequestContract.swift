import AgentModels
import Foundation

// Test-only validator for the Responses request input union used by the adapter.
// Field requirements are transcribed from OpenAI Python commit
// eeebc535572dfe034e2c82958df4d0c22f94301e and OpenAPI commit
// ddface9bd361f5fe37943291d23ee2ca72cbcc2b.
enum OpenAIResponsesRequestContract {
    struct Violation: Error, CustomStringConvertible {
        let description: String
    }

    static func validate(_ body: JSONValue) throws {
        let root = try object(body, "request")
        _ = try string(root["model"], "request.model")
        _ = try bool(root["stream"], "request.stream")
        _ = try bool(root["store"], "request.store")
        _ = try nonNegativeInteger(root["max_output_tokens"], "request.max_output_tokens")

        guard case .array(let input) = root["input"], !input.isEmpty else {
            throw violation("request.input must be a non-empty array")
        }
        for (index, value) in input.enumerated() {
            try validateInput(value, path: "input[\(index)]")
        }

        if let value = root["tools"], value != .null {
            guard case .array(let tools) = value, !tools.isEmpty else {
                throw violation("request.tools must be a non-empty array")
            }
            for (index, tool) in tools.enumerated() {
                try validateTool(tool, path: "tools[\(index)]")
            }
        }
        if let value = root["text"], value != .null {
            try validateTextFormat(value)
        }
        if let value = root["reasoning"], value != .null {
            let reasoning = try object(value, "request.reasoning")
            if let effort = reasoning["effort"], effort != .null {
                _ = try string(effort, "request.reasoning.effort")
            }
            if let summary = reasoning["summary"], summary != .null {
                _ = try string(summary, "request.reasoning.summary")
            }
        }
    }

    private static func validateInput(_ value: JSONValue, path: String) throws {
        let item = try object(value, path)
        let type = try string(item["type"], "\(path).type")
        switch type {
        case "message":
            let role = try string(item["role"], "\(path).role")
            if role == "assistant", item["id"] != nil || item["status"] != nil {
                try validateNativeOutputMessage(item, path: path)
            } else {
                try validateEasyMessage(item, role: role, path: path)
            }
        case "function_call":
            _ = try string(item["call_id"], "\(path).call_id")
            _ = try string(item["name"], "\(path).name")
            _ = try string(item["arguments"], "\(path).arguments")
            try validateOptionalString(item["id"], "\(path).id")
            try validateOptionalString(item["status"], "\(path).status")
        case "function_call_output":
            _ = try string(item["call_id"], "\(path).call_id")
            _ = try string(item["output"], "\(path).output")
        default:
            if type == "reasoning" {
                try validateReasoningInput(item, path: path)
            } else {
                throw violation("\(path) uses an unsupported input item type '\(type)'")
            }
        }
    }

    private static func validateEasyMessage(
        _ item: [String: JSONValue],
        role: String,
        path: String
    ) throws {
        guard ["user", "assistant", "system", "developer"].contains(role) else {
            throw violation("\(path).role is invalid")
        }
        _ = try string(item["content"], "\(path).content")
        if let phase = item["phase"], phase != .null {
            let value = try string(phase, "\(path).phase")
            guard value == "commentary" || value == "final_answer" else {
                throw violation("\(path).phase is invalid")
            }
            guard role == "assistant" else { throw violation("\(path).phase requires assistant role") }
        }
    }

    private static func validateNativeOutputMessage(
        _ item: [String: JSONValue],
        path: String
    ) throws {
        guard try string(item["role"], "\(path).role") == "assistant" else {
            throw violation("\(path).role must be assistant")
        }
        guard !(try string(item["id"], "\(path).id")).isEmpty else {
            throw violation("\(path).id must not be empty")
        }
        let status = try string(item["status"], "\(path).status")
        guard ["in_progress", "completed", "incomplete"].contains(status) else {
            throw violation("\(path).status is invalid")
        }
        if let phase = item["phase"], phase != .null {
            let value = try string(phase, "\(path).phase")
            guard value == "commentary" || value == "final_answer" else {
                throw violation("\(path).phase is invalid")
            }
        }
        guard case .array(let parts) = item["content"], !parts.isEmpty else {
            throw violation("\(path).content must be a non-empty array")
        }
        for (index, value) in parts.enumerated() {
            let partPath = "\(path).content[\(index)]"
            let part = try object(value, partPath)
            switch try string(part["type"], "\(partPath).type") {
            case "output_text":
                _ = try string(part["text"], "\(partPath).text")
                guard case .array = part["annotations"] else {
                    throw violation("\(partPath).annotations must be an array")
                }
            case "refusal":
                _ = try string(part["refusal"], "\(partPath).refusal")
            default:
                throw violation("\(partPath) uses an unsupported output message part")
            }
        }
    }

    private static func validateReasoningInput(_ item: [String: JSONValue], path: String) throws {
        guard !(try string(item["id"], "\(path).id")).isEmpty else {
            throw violation("\(path).id must not be empty")
        }
        guard case .array(let summary) = item["summary"] else {
            throw violation("\(path).summary must be an array")
        }
        for (index, value) in summary.enumerated() {
            let part = try object(value, "\(path).summary[\(index)]")
            guard try string(part["type"], "\(path).summary[\(index)].type") == "summary_text" else {
                throw violation("\(path).summary[\(index)] is not summary_text")
            }
            _ = try string(part["text"], "\(path).summary[\(index)].text")
        }
        if let content = item["content"], content != .null {
            guard case .array(let parts) = content else {
                throw violation("\(path).content must be an array")
            }
            for (index, value) in parts.enumerated() {
                let part = try object(value, "\(path).content[\(index)]")
                guard try string(part["type"], "\(path).content[\(index)].type") == "reasoning_text" else {
                    throw violation("\(path).content[\(index)] is not reasoning_text")
                }
                _ = try string(part["text"], "\(path).content[\(index)].text")
            }
        }
        try validateOptionalString(item["encrypted_content"], "\(path).encrypted_content")
    }

    private static func validateTool(_ value: JSONValue, path: String) throws {
        let tool = try object(value, path)
        guard try string(tool["type"], "\(path).type") == "function" else {
            throw violation("\(path) must be a function tool")
        }
        _ = try string(tool["name"], "\(path).name")
        _ = try string(tool["description"], "\(path).description")
        _ = try object(tool["parameters"], "\(path).parameters")
        if let strict = tool["strict"], strict != .null {
            _ = try bool(strict, "\(path).strict")
        }
    }

    private static func validateTextFormat(_ value: JSONValue) throws {
        let text = try object(value, "request.text")
        let format = try object(text["format"], "request.text.format")
        guard try string(format["type"], "request.text.format.type") == "json_schema" else {
            throw violation("request.text.format.type must be json_schema")
        }
        _ = try string(format["name"], "request.text.format.name")
        _ = try object(format["schema"], "request.text.format.schema")
        _ = try bool(format["strict"], "request.text.format.strict")
        try validateOptionalString(format["description"], "request.text.format.description")
    }

    private static func validateOptionalString(_ value: JSONValue?, _ path: String) throws {
        guard let value, value != .null else { return }
        _ = try string(value, path)
    }

    private static func object(_ value: JSONValue?, _ path: String) throws -> [String: JSONValue] {
        guard case .object(let object) = value else { throw violation("\(path) must be an object") }
        return object
    }

    private static func string(_ value: JSONValue?, _ path: String) throws -> String {
        guard case .string(let string) = value else { throw violation("\(path) must be a string") }
        return string
    }

    private static func bool(_ value: JSONValue?, _ path: String) throws -> Bool {
        guard case .bool(let bool) = value else { throw violation("\(path) must be a boolean") }
        return bool
    }

    private static func nonNegativeInteger(_ value: JSONValue?, _ path: String) throws -> Int {
        guard case .number(let number) = value, number >= 0, number <= Decimal(Int.max) else {
            throw violation("\(path) must be a non-negative integer")
        }
        let integer = NSDecimalNumber(decimal: number).intValue
        guard Decimal(integer) == number else { throw violation("\(path) must be an integer") }
        return integer
    }

    private static func violation(_ description: String) -> Violation {
        Violation(description: description)
    }
}
