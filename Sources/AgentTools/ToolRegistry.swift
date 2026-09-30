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

    package var hasMutation: Bool {
        tools.values.contains { $0.tool.policy.effect == .mutation }
    }

    package func hasMutation(named names: Set<String>) -> Bool {
        tools.contains { name, registration in
            names.contains(name) && registration.tool.policy.effect == .mutation
        }
    }

    package func prepare(_ call: ToolCall, context: ToolContext, prepareAuthorizationBinding: Bool = false) throws -> PreparedToolCall {
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
        let invocation = try registration.tool.prepare(arguments: arguments, prepareAuthorizationBinding: prepareAuthorizationBinding)
        try context.checkActive()
        return PreparedToolCall(call: call, policy: registration.tool.policy, resources: invocation.resources,
                                evidenceRequirements: invocation.evidenceRequirements,
                                receiptExpectation: invocation.receiptExpectation, definition: registration.tool.definition,
                                binding: invocation.binding, context: context, preauthorize: invocation.preauthorize) { executionContext in
            let result = try await invocation.invoke(executionContext)
            if !result.isModelVisibleError {
                do { try registration.output.validate(result.output) }
                catch let error as ToolSchemaValidationError { throw ToolRegistryError.invalidOutput(error) }
            }
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
    private let evidenceRequirements: [EvidenceRequirement]
    package var contextSessionID: UUID { context.sessionID }
    package var contextRunID: UUID { context.runID }
    package let receiptExpectation: ToolReceiptExpectation?
    package let definition: ModelToolDefinition
    package let binding: ToolAuthorizationBinding
    package var auditAuthorization: (any ToolAuditAuthorization)? { context.auditAuthorization }
    private let context: ToolContext
    private let operation: AnyAgentTool.Invocation
    private let preauthorize: @Sendable (ToolContext) async throws -> Void

    fileprivate init(call: ToolCall, policy: ToolPolicy, resources: [ToolResource],
                     evidenceRequirements: [EvidenceRequirement], receiptExpectation: ToolReceiptExpectation?,
                     definition: ModelToolDefinition, binding: ToolAuthorizationBinding,
                     context: ToolContext, preauthorize: @escaping @Sendable (ToolContext) async throws -> Void,
                     operation: @escaping AnyAgentTool.Invocation) {
        self.call = call
        self.policy = policy
        self.resources = resources
        self.evidenceRequirements = evidenceRequirements
        self.receiptExpectation = receiptExpectation
        self.context = context
        self.operation = operation
        self.definition = definition; self.binding = binding; self.preauthorize = preauthorize
    }

    package func preauthorizeAudit(deadline: ContinuousClock.Instant) async throws {
        try await preauthorize(executionContext(deadline: deadline))
    }

    package func boundToAudit(_ audit: any ToolAuditAuthorization) -> Self {
        let updated = ToolContext(sessionID: context.sessionID, runID: context.runID, callID: context.callID,
            deadline: context.deadline, idempotencyKey: context.idempotencyKey, argumentsJSON: context.argumentsJSON,
            evidenceLedger: context.evidenceLedger, mutationAdmission: context.mutationAdmission,
            executionAdmission: context.executionAdmission, auditAuthorization: audit)
        return Self(call: call, policy: policy, resources: resources, evidenceRequirements: evidenceRequirements,
            receiptExpectation: receiptExpectation, definition: definition, binding: binding,
            context: updated, preauthorize: preauthorize, operation: operation)
    }

    /// Only this runtime-owned ledger resolution can return a trusted, pre-admission rejection.
    /// Host callbacks and the executor have not been invoked. Invocation rechecks Evidence later.
    package func preAdmissionEvidenceRejection() async throws -> ToolPreAdmissionRejection? {
        guard !evidenceRequirements.isEmpty else { return nil }
        do {
            try await context.requireEvidence(evidenceRequirements)
            return nil
        } catch EvidenceError.unavailable(let reference) {
            return ToolPreAdmissionRejection(sessionID: context.sessionID, runID: context.runID,
                callID: call.id, toolName: call.name, reference: reference)
        }
    }

    package func invoke(deadline: ContinuousClock.Instant? = nil) async throws -> ToolResult<JSONValue> {
        try await operation(executionContext(deadline: deadline))
    }

    private func executionContext(deadline: ContinuousClock.Instant?) -> ToolContext {
        let effectiveDeadline: ContinuousClock.Instant?
        if let current = context.deadline, let deadline { effectiveDeadline = min(current, deadline) }
        else { effectiveDeadline = context.deadline ?? deadline }
        let executionContext = ToolContext(sessionID: context.sessionID, runID: context.runID, callID: context.callID,
            deadline: effectiveDeadline, idempotencyKey: context.idempotencyKey, argumentsJSON: context.argumentsJSON,
            evidenceLedger: context.evidenceLedger, mutationAdmission: context.mutationAdmission,
            executionAdmission: context.executionAdmission, auditAuthorization: context.auditAuthorization)
        return executionContext
    }
}

package struct ToolPreAdmissionRejection: Sendable {
    package let sessionID: UUID
    package let runID: UUID
    package let callID: ToolCallID
    package let toolName: String
    package let reference: EvidenceReference
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
