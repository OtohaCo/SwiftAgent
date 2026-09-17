import AgentModels
import Foundation

/// Heterogeneous tool registration. The invocation bridge is package-only;
/// model-call validation and scheduling belong to the registry and runtime.
public struct AnyAgentTool: Sendable {
    public let definition: ModelToolDefinition
    public let policy: ToolPolicy
    private let operation: @Sendable (JSONValue, ToolContext) async throws -> ToolResult<JSONValue>

    public init<T: AgentTool>(_ tool: T) throws {
        guard !T.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolInvocationError.invalidDefinition
        }
        definition = ModelToolDefinition(name: T.name, description: T.description,
                                         inputSchema: T.inputSchema.json, outputSchema: T.outputSchema.json)
        let policy = tool.policy
        self.policy = policy
        operation = { arguments, context in
            let input: T.Input
            do {
                input = try JSONDecoder().decode(T.Input.self, from: JSONEncoder().encode(arguments))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ToolInvocationError.invalidArguments
            }
            try context.checkActive()
            if policy.authorization == .required {
                let authorization = try await tool.authorize(input, context: context)
                try context.checkActive()
                guard authorization == .allowed else {
                    throw ToolInvocationError.authorizationDenied
                }
            }
            let result = try await tool.execute(input, context: context)
            try context.checkActive()
            do {
                let output = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result.output))
                return ToolResult(output: output)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ToolInvocationError.invalidOutput
            }
        }
    }

    package func invoke(arguments: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        try context.checkActive()
        guard policy.effect == .readOnly else { throw ToolInvocationError.mutationIntegrityUnavailable }
        guard policy.idempotency != .requiresReceipt else { throw ToolInvocationError.receiptValidationUnavailable }
        if policy.idempotency == .keyed {
            guard let key = context.idempotencyKey,
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolInvocationError.missingIdempotencyKey
            }
        }
        return try await operation(arguments, context)
    }
}

public enum ToolInvocationError: Error, Equatable, Sendable {
    case invalidDefinition
    case invalidArguments
    case invalidOutput
    case missingIdempotencyKey
    case deadlineExceeded
    case authorizationDenied
    case mutationIntegrityUnavailable
    case receiptValidationUnavailable
}
