import AgentModels
import Foundation

/// Heterogeneous tool registration used by the runtime. Hosts pass
/// `[any AgentTool]` to `Agent`; they do not type-erase tools themselves.
package struct AnyAgentTool: Sendable {
    package let definition: ModelToolDefinition
    package let policy: ToolPolicy
    package typealias Invocation = @Sendable (ToolContext) async throws -> ToolResult<JSONValue>
    package struct PreparedInvocation: Sendable {
        let resources: [ToolResource]
        let evidenceRequirements: [EvidenceRequirement]
        let receiptExpectation: ToolReceiptExpectation?
        let invoke: Invocation
    }
    private let decode: @Sendable (JSONValue) throws -> PreparedInvocation

    package init<T: AgentTool>(_ tool: T) throws {
        let definition = tool.definition
        guard !definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolInvocationError.invalidDefinition
        }
        // A name that comes from the instance, not the type, is one every model API accepts.
        if definition.name != T.name, !Self.portable(definition.name) { throw ToolInvocationError.invalidDefinition }
        self.definition = definition
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
            let resources = try tool.resourceRequirements(for: input)
            try ToolResource.validate(resources)
            if policy.evidence == .required { try EvidenceLedger.checkRequirements(requirements) }
            let receiptExpectation = try tool.receiptExpectation(for: input)
            let requiresReceipt = policy.effect == .mutation || policy.idempotency == .requiresReceipt || receiptExpectation != nil
            if policy.effect == .readOnly && requiresReceipt && receiptExpectation == nil {
                throw ToolInvocationError.receiptValidationUnavailable
            }
            return PreparedInvocation(resources: resources, evidenceRequirements: requirements,
                                      receiptExpectation: receiptExpectation) { context in
                try context.checkActive()
                if policy.effect == .mutation {
                    guard context.mutationAdmission != nil, context.argumentsJSON != nil else {
                        throw ToolInvocationError.mutationIntegrityUnavailable
                    }
                }
                if policy.idempotency == .keyed || requiresReceipt {
                    guard let key = context.idempotencyKey,
                          !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ToolInvocationError.missingIdempotencyKey
                    }
                }
                try await Self.validateEvidence(requirements, context: context)
                try await context.executionAdmission?.check(runID: context.runID, resources: resources)
                if policy.authorization == .required {
                    let authorization = try await tool.authorize(input, context: context)
                    try context.checkActive()
                    guard authorization == .allowed else { throw ToolInvocationError.authorizationDenied }
                    try await Self.validateEvidence(requirements, context: context)
                }
                try await context.executionAdmission?.check(runID: context.runID, resources: resources)
                if policy.effect == .mutation {
                    let mutationAdmission = context.mutationAdmission!
                    let argumentsJSON = context.argumentsJSON!
                    let admission = try await mutationAdmission.admit(.init(
                        sessionID: context.sessionID,
                        runID: context.runID,
                        callID: context.callID,
                        name: definition.name,
                        argumentsJSON: argumentsJSON,
                        resources: resources,
                        idempotencyKey: context.idempotencyKey ?? "",
                        receiptExpectation: receiptExpectation
                    ))
                    try context.checkActive()
                    if case .settled(let receipt, let output) = admission {
                        try await context.executionAdmission?.check(runID: context.runID, resources: resources)
                        guard let receiptExpectation else { throw ToolReceiptError.unexpectedReceipt }
                        guard let operationID = context.idempotencyKey else {
                            throw ToolInvocationError.missingIdempotencyKey
                        }
                        try ToolReceiptValidator.validate(
                            receipt,
                            operationID: operationID,
                            expectation: receiptExpectation
                        )
                        return ToolResult(output: output, receipt: receipt, isIdempotentReplay: true)
                    }
                }
                let result: ToolResult<T.Output>
                do {
                    if let admission = context.executionAdmission {
                        let ticket = try await admission.admit(runID: context.runID, resources: resources)
                        do {
                            try context.checkActive()
                            result = try await tool.execute(input, context: context)
                            await admission.release(ticket)
                        } catch {
                            await admission.release(ticket)
                            throw error
                        }
                    } else {
                        result = try await tool.execute(input, context: context)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as RecoverableToolError {
                    try context.checkActive()
                    guard policy.effect == .readOnly, policy.recoverableErrors == .modelVisible else {
                        throw error
                    }
                    return ToolResult<JSONValue>(modelVisibleError: error.payload)
                }
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

    /// Letters, digits, "_" and "-", at most 64: accepted by every provider's tool names.
    static func portable(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count)
            && name.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D }
    }

    private static func validateEvidence(_ requirements: [EvidenceRequirement], context: ToolContext) async throws {
        guard !requirements.isEmpty else { return }
        try await context.requireEvidence(requirements)
    }

    package func prepare(arguments: JSONValue) throws -> PreparedInvocation {
        try decode(arguments)
    }

    package func invoke(arguments: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        try context.checkActive()
        return try await prepare(arguments: arguments).invoke(context)
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
