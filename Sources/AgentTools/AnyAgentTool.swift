import AgentModels
import Foundation

/// Heterogeneous tool registration. The invocation bridge is package-only;
/// model-call validation and scheduling belong to the registry and runtime.
public struct AnyAgentTool: Sendable {
    public let definition: ModelToolDefinition
    public let policy: ToolPolicy
    package typealias Invocation = @Sendable (ToolContext) async throws -> ToolResult<JSONValue>
    private let decode: @Sendable (JSONValue) throws -> Invocation

    public init<T: AgentTool>(_ tool: T) throws {
        guard !T.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolInvocationError.invalidDefinition
        }
        definition = ModelToolDefinition(name: T.name, description: T.description,
                                         inputSchema: T.inputSchema.json, outputSchema: T.outputSchema.json)
        let policy = tool.policy
        self.policy = policy
        decode = { arguments in
            let input: T.Input
            do {
                input = try JSONDecoder().decode(T.Input.self, from: JSONEncoder().encode(arguments))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ToolInvocationError.invalidArguments
            }
            let requirements = policy.evidence == .required ? try tool.evidenceRequirements(for: input) : []
            if policy.evidence == .required { try EvidenceLedger.checkRequirements(requirements) }
            let receiptExpectation = try tool.receiptExpectation(for: input)
            let requiresReceipt = policy.effect == .mutation || policy.idempotency == .requiresReceipt || receiptExpectation != nil
            if policy.effect == .readOnly && requiresReceipt && receiptExpectation == nil {
                throw ToolInvocationError.receiptValidationUnavailable
            }
            return { context in
                try context.checkActive()
                guard policy.effect == .readOnly else { throw ToolInvocationError.mutationIntegrityUnavailable }
                if policy.idempotency == .keyed || requiresReceipt {
                    guard let key = context.idempotencyKey,
                          !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ToolInvocationError.missingIdempotencyKey
                    }
                }
                try await Self.validateEvidence(requirements, context: context)
                if policy.authorization == .required {
                    let authorization = try await tool.authorize(input, context: context)
                    try context.checkActive()
                    guard authorization == .allowed else { throw ToolInvocationError.authorizationDenied }
                    try await Self.validateEvidence(requirements, context: context)
                }
                let result = try await tool.execute(input, context: context)
                try context.checkActive()
                if requiresReceipt || result.receipt != nil {
                    guard let receiptExpectation else { throw ToolReceiptError.unexpectedReceipt }
                    guard let operationID = context.idempotencyKey else { throw ToolInvocationError.missingIdempotencyKey }
                    try ToolReceiptValidator.validate(result.receipt, operationID: operationID, expectation: receiptExpectation)
                }
                let output: JSONValue
                do {
                    output = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result.output))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ToolInvocationError.invalidOutput
                }
                try context.checkActive()
                return ToolResult(output: output, evidence: result.evidence, receipt: result.receipt)
            }
        }
    }

    private static func validateEvidence(_ requirements: [EvidenceRequirement], context: ToolContext) async throws {
        guard !requirements.isEmpty else { return }
        try await context.requireEvidence(requirements)
    }

    package func prepare(arguments: JSONValue) throws -> Invocation {
        try decode(arguments)
    }

    package func invoke(arguments: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        try context.checkActive()
        return try await prepare(arguments: arguments)(context)
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
    case evidenceUnavailable
}
