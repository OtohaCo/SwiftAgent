import AgentModels
import Foundation

public struct ToolRegistry: Sendable {
    private struct Registration: Sendable {
        let tool: AnyAgentTool
        let input: ToolSchemaValidator
        let output: ToolSchemaValidator
    }
    private let tools: [String: Registration]

    public init(tools: [AnyAgentTool]) throws {
        var registered: [String: Registration] = [:]
        for tool in tools {
            guard registered[tool.definition.name] == nil else {
                throw ToolRegistryError.duplicateName(tool.definition.name)
            }
            do {
                let input = try ToolSchemaValidator(schema: .init(json: tool.definition.inputSchema))
                guard let outputSchema = tool.definition.outputSchema else {
                    throw ToolSchemaValidationError(kind: .invalidSchema, path: "", keyword: "outputSchema")
                }
                let output = try ToolSchemaValidator(schema: .init(json: outputSchema))
                registered[tool.definition.name] = Registration(tool: tool, input: input, output: output)
            } catch let error as ToolSchemaValidationError {
                throw ToolRegistryError.invalidSchema(tool: tool.definition.name, issue: error)
            }
        }
        self.tools = registered
    }

    public var definitions: [ModelToolDefinition] {
        tools.values.map(\.tool.definition).sorted { $0.name < $1.name }
    }

    public func prepare(_ call: ToolCall, context: ToolContext) throws -> PreparedToolCall {
        try context.checkActive()
        guard call.completeness == .complete else { throw ToolRegistryError.truncatedCall }
        guard let registration = tools[call.name],
              registration.tool.definition.name.utf8.elementsEqual(call.name.utf8) else {
            throw ToolRegistryError.unknownTool(call.name)
        }
        guard call.id.rawValue.utf8.elementsEqual(context.callID.rawValue.utf8),
              !call.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolRegistryError.callIdentityMismatch
        }
        let arguments: JSONValue
        do { arguments = try JSONValue.decodeToolArguments(call.argumentsJSON) }
        catch { throw ToolRegistryError.invalidJSON }
        do { try registration.input.validate(arguments) }
        catch let error as ToolSchemaValidationError { throw ToolRegistryError.invalidArguments(error) }
        try context.checkActive()
        return PreparedToolCall(call: call, policy: registration.tool.policy) {
            let result = try await registration.tool.invoke(arguments: arguments, context: context)
            do { try registration.output.validate(result.output) }
            catch let error as ToolSchemaValidationError { throw ToolRegistryError.invalidOutput(error) }
            try context.checkActive()
            return result
        }
    }
}

public struct PreparedToolCall: Sendable {
    public let call: ToolCall
    public let policy: ToolPolicy
    private let operation: @Sendable () async throws -> ToolResult<JSONValue>

    fileprivate init(call: ToolCall, policy: ToolPolicy, operation: @escaping @Sendable () async throws -> ToolResult<JSONValue>) {
        self.call = call
        self.policy = policy
        self.operation = operation
    }

    package func invoke() async throws -> ToolResult<JSONValue> {
        try await operation()
    }
}

public enum ToolRegistryError: Error, Equatable, Sendable {
    case unknownTool(String)
    case duplicateName(String)
    case truncatedCall
    case callIdentityMismatch
    case invalidJSON
    case invalidSchema(tool: String, issue: ToolSchemaValidationError)
    case invalidArguments(ToolSchemaValidationError)
    case invalidOutput(ToolSchemaValidationError)
}
