import AgentModels
import Foundation

package struct ToolRegistry: Sendable {
    private struct Registration: Sendable {
        let tool: AnyAgentTool
        let input: ToolSchemaValidator
        let output: ToolSchemaValidator
        let outputSchema: JSONValue
    }
    private let tools: [String: Registration]
    /// Tools a Run declares to the model from its first request. Every other registered tool is
    /// deferred: callable only once a tool result of the same Run declares it.
    package let initiallyDeclaredNames: Set<String>

    package init(tools: [AnyAgentTool], deferred: Set<String> = []) throws {
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
                registered[tool.definition.name] = Registration(tool: tool, input: input, output: output, outputSchema: outputSchema)
            } catch let error as ToolSchemaValidationError {
                throw ToolRegistryError.invalidSchema(tool: tool.definition.name, issue: error)
            }
        }
        self.tools = registered
        try Self.checkRegistered(deferred, in: registered)
        initiallyDeclaredNames = Set(registered.keys).subtracting(deferred)
    }

    /// Each name must be exactly a registered tool's name, compared without Unicode normalization.
    private static func checkRegistered<Names: Sequence<String>>(_ names: Names,
                                                                 in tools: [String: Registration]) throws {
        for name in names {
            guard let registration = tools[name],
                  registration.tool.definition.name.utf8.elementsEqual(name.utf8) else {
                throw ToolRegistryError.unknownTool(name)
            }
        }
    }

    package var definitions: [ModelToolDefinition] {
        tools.values.map(\.tool.definition).sorted { $0.name < $1.name }
    }

    /// What a model request carries: the definitions of the declared tools only.
    package func definitions(declared: Set<String>) -> [ModelToolDefinition] {
        tools.values.map(\.tool.definition).filter { declared.contains($0.name) }.sorted { $0.name < $1.name }
    }

    package var hasConfirmedNoEffectMutation: Bool {
        tools.values.contains { $0.tool.policy.recoverableErrors == .confirmedNoEffect }
    }

    package var hasMutation: Bool {
        tools.values.contains { $0.tool.policy.effect == .mutation }
    }

    package func hasMutation(named names: Set<String>) -> Bool {
        tools.contains { name, registration in
            names.contains(name) && registration.tool.policy.effect == .mutation
        }
    }

    /// `declared` is the set of tools the model has been told about in this Run (`nil`: those
    /// declared from the start, so omitting it never reaches a deferred tool). A call to a registered
    /// tool outside it is refused exactly as a call naming no registered tool: being bound is not
    /// enough to be callable.
    package func prepare(_ call: ToolCall, context: ToolContext, declared: Set<String>? = nil,
                         prepareAuthorizationBinding: Bool = false) throws -> PreparedToolCall {
        try context.checkActive()
        guard call.completeness == .complete else { throw ToolRegistryError.truncatedCall }
        guard let registration = tools[call.name],
              registration.tool.definition.name.utf8.elementsEqual(call.name.utf8),
              (declared ?? initiallyDeclaredNames).contains(call.name) else {
            throw ToolRegistryError.unknownTool(call.name)
        }
        guard call.id.rawValue.utf8.elementsEqual(context.callID.rawValue.utf8),
              !call.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolRegistryError.callIdentityMismatch
        }
        if registration.tool.policy.recoverableErrors == .confirmedNoEffect,
           call.argumentsJSON.utf8.count > ToolNoEffectProof.maximumInputBytes { throw ToolNoEffectError.payloadTooLarge }
        let arguments: JSONValue
        do { arguments = try JSONValue.decodeToolArguments(call.argumentsJSON) }
        catch { throw ToolRegistryError.invalidJSON }
        do { try registration.input.validate(arguments) }
        catch let error as ToolSchemaValidationError { throw ToolRegistryError.invalidArguments(error) }
        let invocation = try registration.tool.prepare(arguments: arguments, prepareAuthorizationBinding: prepareAuthorizationBinding)
        if registration.tool.policy.recoverableErrors == .confirmedNoEffect {
            try ToolNoEffectProof.checkAdmission(context: context, definition: registration.tool.definition,
                arguments: arguments, resources: invocation.resources, action: invocation.binding,
                expectation: invocation.receiptExpectation)
        }
        try context.checkActive()
        let tools = tools
        let output = registration.output
        let outputSchema = registration.outputSchema
        let definition = registration.tool.definition
        let policy = registration.tool.policy
        @Sendable func checked(_ invoke: @escaping AnyAgentTool.Invocation) -> AnyAgentTool.Invocation {
            { executionContext in
                try await Self.checkedResult(of: invoke, context: executionContext, output: output, outputSchema: outputSchema, tools: tools,
                                             name: definition.name, policy: policy)
            }
        }
        return PreparedToolCall(call: call, policy: registration.tool.policy, resources: invocation.resources,
                                evidenceRequirements: invocation.evidenceRequirements,
                                receiptExpectation: invocation.receiptExpectation, definition: registration.tool.definition,
                                binding: invocation.binding, context: context, preauthorize: invocation.preauthorize,
                                authorizeBeforeLease: invocation.authorizeBeforeLease,
                                authorizedOperation: checked(invocation.invokeAuthorized),
                                operation: checked(invocation.invoke))
    }

    /// What every invocation returns only after: output schema, declared tools and Evidence recorded.
    /// A read-only tool whose recoverable errors are model-visible changed nothing, so output outside its
    /// schema goes back to the model as that tool's error, without its Evidence or declared tools; any
    /// other tool's invalid output still ends the Run.
    private static func checkedResult(of invoke: AnyAgentTool.Invocation, context executionContext: ToolContext,
                                      output: ToolSchemaValidator, outputSchema: JSONValue, tools: [String: Registration],
                                      name: String, policy: ToolPolicy) async throws -> ToolResult<JSONValue> {
        let result = try await invoke(executionContext)
        if !result.isModelVisibleError {
            do { try output.validate(result.output) }
            catch let error as ToolSchemaValidationError {
                guard policy.effect == .readOnly, policy.recoverableErrors == .modelVisible else {
                    throw ToolRegistryError.invalidOutput(error)
                }
                try executionContext.checkActive()
                let safeIssue = ToolSchemaValidationError(kind: error.kind,
                    path: modelVisibleOutputPath(error.path, schema: outputSchema, value: result.output), keyword: error.keyword)
                return ToolResult(modelVisibleError: invalidOutputPayload(name: name, issue: safeIssue))
            }
        }
        // A result can only declare tools this Run already has; it never adds one.
        try checkRegistered(result.declaredTools, in: tools)
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

/// Validator paths can contain property names from the unvalidated output. Keep
/// only schema-declared names and verified array positions in model feedback.
/// At the first dynamic key, stop: even a later declared child lies under that
/// untrusted name. Host fail-closed diagnostics retain the original validator path.
private func modelVisibleOutputPath(_ path: String, schema: JSONValue, value: JSONValue) -> String {
    guard !path.isEmpty else { return "" }
    var schema = schema
    var value = value
    var safePath = ""
    let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
    for (position, segment) in segments.enumerated() {
        guard case .object(let rules) = schema else { return safePath + "/<unrecognized>" }
        let key = String(segment).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        switch value {
        case .object(let object):
            let properties: [String: JSONValue]
            if case .object(let declared) = rules["properties"] { properties = declared } else { properties = [:] }
            if let property = properties.first(where: { $0.key.utf8.elementsEqual(key.utf8) }) {
                safePath += "/" + outputPathSegment(property.key)
                schema = property.value
                guard let nested = ToolSchemaValidator.exactValue(object, property.key) else { return safePath }
                value = nested
            } else if position == segments.count - 1, case .array(let required) = rules["required"],
                      let name = required.compactMap({ item -> String? in
                          if case .string(let name) = item { name } else { nil }
                      }).first(where: { $0.utf8.elementsEqual(key.utf8) }) {
                // A missing required field can be named by the schema even when
                // it has no property-specific schema; it is not an output key.
                return safePath + "/" + outputPathSegment(name)
            } else { return safePath + "/<unrecognized>" }
        case .array(let array):
            guard let items = rules["items"], let index = Int(key), index >= 0,
                  String(index) == key, array.indices.contains(index) else { return safePath + "/<unrecognized>" }
            safePath += "/" + String(index)
            schema = items
            value = array[index]
        default: return safePath + "/<unrecognized>"
        }
    }
    return safePath
}

private func outputPathSegment(_ name: String) -> String {
    name.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
}

/// What the model is told when a read-only tool's output broke its schema: where and which rule, never the
/// output itself, which is what could not be checked.
package func invalidOutputPayload(name: String, issue: ToolSchemaValidationError?) -> JSONValue {
    var detail = ""
    if let issue {
        let path = issue.path.count > 200 ? String(issue.path.prefix(200)) + "..." : issue.path
        detail = path.isEmpty ? " (it breaks the \"\(issue.keyword)\" rule)" : " (the value at \(path) breaks the \"\(issue.keyword)\" rule)"
    }
    let message = "\(name) ran, but what it returned does not match its output schema\(detail), so its result "
        + "cannot be used. Nothing was changed. Go on another way: another source, other arguments or another tool."
    return .object(["code": .string("invalid_output"), "message": .string(message)])
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
    private let authorizedOperation: AnyAgentTool.Invocation
    private let preauthorize: @Sendable (ToolContext) async throws -> Void
    private let authorizeBeforeLease: @Sendable (ToolContext) async throws -> Void

    fileprivate init(call: ToolCall, policy: ToolPolicy, resources: [ToolResource],
                     evidenceRequirements: [EvidenceRequirement], receiptExpectation: ToolReceiptExpectation?,
                     definition: ModelToolDefinition, binding: ToolAuthorizationBinding,
                     context: ToolContext, preauthorize: @escaping @Sendable (ToolContext) async throws -> Void,
                     authorizeBeforeLease: @escaping @Sendable (ToolContext) async throws -> Void,
                     authorizedOperation: @escaping AnyAgentTool.Invocation,
                     operation: @escaping AnyAgentTool.Invocation) {
        self.call = call
        self.policy = policy
        self.resources = resources
        self.evidenceRequirements = evidenceRequirements
        self.receiptExpectation = receiptExpectation
        self.context = context
        self.operation = operation
        self.authorizedOperation = authorizedOperation
        self.definition = definition; self.binding = binding; self.preauthorize = preauthorize
        self.authorizeBeforeLease = authorizeBeforeLease
    }

    package func preauthorizeAudit(deadline: ContinuousClock.Instant) async throws {
        try await preauthorize(executionContext(deadline: deadline))
    }

    /// Runs the tool's own required authorization (no audit) before the scheduler lease and returns
    /// the call to invoke under the lease: it rechecks Evidence and scope there but does not ask again.
    /// A call without required authorization, or under audit, is returned unchanged.
    package func authorizedBeforeLease(deadline: ContinuousClock.Instant) async throws -> Self {
        guard policy.authorization == .required, auditAuthorization == nil else { return self }
        try await authorizeBeforeLease(executionContext(deadline: deadline))
        return Self(call: call, policy: policy, resources: resources, evidenceRequirements: evidenceRequirements,
            receiptExpectation: receiptExpectation, definition: definition, binding: binding, context: context,
            preauthorize: preauthorize, authorizeBeforeLease: authorizeBeforeLease,
            authorizedOperation: authorizedOperation, operation: authorizedOperation)
    }

    package func boundToAudit(_ audit: any ToolAuditAuthorization) -> Self {
        let updated = ToolContext(sessionID: context.sessionID, runID: context.runID, callID: context.callID,
            deadline: context.deadline, idempotencyKey: context.idempotencyKey, argumentsJSON: context.argumentsJSON,
            evidenceLedger: context.evidenceLedger, mutationAdmission: context.mutationAdmission,
            executionAdmission: context.executionAdmission, auditAuthorization: audit)
        return Self(call: call, policy: policy, resources: resources, evidenceRequirements: evidenceRequirements,
            receiptExpectation: receiptExpectation, definition: definition, binding: binding,
            context: updated, preauthorize: preauthorize, authorizeBeforeLease: authorizeBeforeLease,
            authorizedOperation: authorizedOperation, operation: operation)
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
