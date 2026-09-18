import AgentModels
import Foundation

package struct ToolRegistry: Sendable {
    private struct Registration: Sendable {
        let tool: AnyAgentTool
        let input: ToolSchemaValidator
        let output: ToolSchemaValidator
    }
    private let tools: [String: Registration]

    package init(tools: [AnyAgentTool]) throws {
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

    package var definitions: [ModelToolDefinition] {
        tools.values.map(\.tool.definition).sorted { $0.name < $1.name }
    }

    package func prepare(_ call: ToolCall, context: ToolContext) throws -> PreparedToolCall {
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
        let invocation = try registration.tool.prepare(arguments: arguments)
        try context.checkActive()
        return PreparedToolCall(call: call, policy: registration.tool.policy, resources: invocation.resources,
                                receiptExpectation: invocation.receiptExpectation, context: context) { executionContext in
            let result = try await invocation.invoke(executionContext)
            do { try registration.output.validate(result.output) }
            catch let error as ToolSchemaValidationError { throw ToolRegistryError.invalidOutput(error) }
            try executionContext.checkActive()
            if !result.evidence.isEmpty {
                guard let ledger = executionContext.evidenceLedger else { throw ToolInvocationError.evidenceUnavailable }
                try await ledger.record(result.evidence, sessionID: executionContext.sessionID, runID: executionContext.runID,
                                        deadline: executionContext.deadline)
                try executionContext.checkActive()
            }
            return result
        }
    }
}

package struct PreparedToolCall: Sendable {
    package let call: ToolCall
    package let policy: ToolPolicy
    package let resources: [ToolResource]
    package var contextSessionID: UUID { context.sessionID }
    package var contextRunID: UUID { context.runID }
    package let receiptExpectation: ToolReceiptExpectation?
    private let context: ToolContext
    private let operation: AnyAgentTool.Invocation

    fileprivate init(call: ToolCall, policy: ToolPolicy, resources: [ToolResource], receiptExpectation: ToolReceiptExpectation?, context: ToolContext, operation: @escaping AnyAgentTool.Invocation) {
        self.call = call
        self.policy = policy
        self.resources = resources
        self.receiptExpectation = receiptExpectation
        self.context = context
        self.operation = operation
    }

    package func invoke(deadline: ContinuousClock.Instant? = nil) async throws -> ToolResult<JSONValue> {
        let effectiveDeadline: ContinuousClock.Instant?
        if let current = context.deadline, let deadline { effectiveDeadline = min(current, deadline) }
        else { effectiveDeadline = context.deadline ?? deadline }
        let executionContext = ToolContext(sessionID: context.sessionID, runID: context.runID, callID: context.callID,
            deadline: effectiveDeadline, idempotencyKey: context.idempotencyKey, argumentsJSON: context.argumentsJSON,
            evidenceLedger: context.evidenceLedger, mutationAdmission: context.mutationAdmission)
        return try await operation(executionContext)
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
