import AgentModels
import Foundation

/// Archival assertion from trusted Host code; decoding it never creates execution permission.
/// The Host must establish whole-operation truth, including absence of outstanding work.
public struct ToolNoEffectProof: Codable, Equatable, Sendable {
    public let version: Int
    public let invocationID: UUID
    public let sessionID: UUID
    public let runID: UUID
    public let scopeInstanceID: UUID?
    public let modelCallID: ToolCallID
    public let definition: ModelToolDefinition
    /// Inline v1 parameters, or bounded v2 parameters; nil means consult argumentBinding.
    public let canonicalArguments: JSONValue?
    public let argumentBinding: ToolNoEffectDigest?
    /// Exact model-input bytes, distinct from canonical UTF-8 bytes. Present in v2.
    public let originalArgumentsUTF8Bytes: Int?
    public let resources: [ToolResource]
    public let actionBinding: ToolAuthorizationBinding
    public let receiptExpectation: ToolReceiptExpectation?
    /// Original receipt only when inline. Never contains a substituted operation ID.
    public let receipt: ToolReceipt?
    public let receiptSummary: ToolNoEffectReceiptSummary?
    public let wholeOperationHadNoEffect: Bool
    public let noOutstandingEffects: Bool
    public let basis: String
}

/// Only an SDK-issued executor context can construct this channel. A public error type
/// thrown by another callback does not acquire executor provenance.
public struct ConfirmedNoEffectToolError: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let proof: ToolNoEffectProof
    public let error: RecoverableToolError
    /// Full executor receipt, validated again at the executor return boundary.
    public let receipt: ToolReceipt
    package let token: UUID
    public var description: String { "Confirmed no-effect executor outcome" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["status": description]) }
    package init(proof: ToolNoEffectProof, receipt: ToolReceipt, error: RecoverableToolError, token: UUID) {
        self.proof = proof; self.receipt = receipt; self.error = error; self.token = token
    }
}

public enum ToolNoEffectError: Error, Equatable, Sendable {
    case unavailable, insufficientConfirmation, invalidReceipt, invalidBinding, payloadTooLarge
}

extension ToolNoEffectProof {
    package static let maximumProofBytes = 131_072
    package static let maximumInputBytes = 1_048_576
    package static let maximumCanonicalBytes = 8_388_608

    package func validate(sessionID: UUID, runID: UUID, callID: ToolCallID, name: String,
                          operationID: String, arguments: JSONValue, resources: [ToolResource],
                          expectation: ToolReceiptExpectation?, originalArgumentsUTF8Bytes: Int? = nil) throws {
        try Self.validateAction(actionBinding, resources: resources)
        guard self.sessionID == sessionID, self.runID == runID, modelCallID == callID,
              definition.name.utf8.elementsEqual(name.utf8), wholeOperationHadNoEffect, noOutstandingEffects,
              self.resources == resources, receiptExpectation == expectation,
              !basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              basis.utf8.count <= 4096, try JSONEncoder().encode(self).count <= Self.maximumProofBytes else {
            throw ToolNoEffectError.invalidBinding
        }
        switch version {
        case 1:
            guard argumentBinding == nil, receiptSummary == nil, self.originalArgumentsUTF8Bytes == nil,
                  canonicalArguments == arguments, let receipt else { throw ToolNoEffectError.invalidBinding }
            try Self.validateReceipt(receipt, operationID: operationID)
        case 2:
            let expectedArguments = try ToolNoEffectDigest.arguments(arguments)
            guard argumentBinding == expectedArguments, let summary = receiptSummary,
                  summary.operation.source == .intentIdempotencyKey,
                  summary.operation.key == .operationKey(operationID),
                  summary.status == .failed, summary.failure == .rejected || summary.failure == .conflict,
                  summary.confirmedTargets.isEmpty, (summary.revision?.utf8.count ?? 0) <= 4096,
                  let rawBytes = self.originalArgumentsUTF8Bytes, rawBytes >= 0,
                  rawBytes <= Self.maximumInputBytes, expectedArguments.utf8Bytes <= Self.maximumCanonicalBytes,
                  operationID.utf8.count <= Self.maximumCanonicalBytes,
                  originalArgumentsUTF8Bytes.map({ $0 == rawBytes }) ?? false,
                  (canonicalArguments == nil) == (receipt == nil) else { throw ToolNoEffectError.invalidBinding }
            if let canonicalArguments, let receipt {
                guard try ToolNoEffectDigest.arguments(canonicalArguments) == expectedArguments,
                      ToolNoEffectReceiptSummary(receipt) == summary,
                      try JSONEncoder().encode(canonicalArguments).count + JSONEncoder().encode(receipt).count <= 16_384 else {
                    throw ToolNoEffectError.invalidBinding
                }
                try Self.validateReceipt(receipt, operationID: operationID)
            }
        default: throw ToolNoEffectError.invalidBinding
        }
    }

    package static func validateReceipt(_ receipt: ToolReceipt, operationID: String, maximumRevisionBytes: Int? = nil) throws {
        guard receipt.operationID.utf8.elementsEqual(operationID.utf8), receipt.status == .failed,
              receipt.failure == .rejected || receipt.failure == .conflict,
              receipt.confirmedTargets.isEmpty, maximumRevisionBytes.map({ (receipt.revision?.utf8.count ?? 0) <= $0 }) ?? true else {
            throw ToolNoEffectError.invalidReceipt
        }
    }

    package static func validateAction(_ action: ToolAuthorizationBinding, resources: [ToolResource]) throws {
        let identifier: (String) -> Bool = { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 }
        guard let backend = action.backend,
              [action.definitionVersion, action.implementationVersion, backend.instanceID,
               backend.version, backend.accountID, backend.credentialGeneration].allSatisfy(identifier),
              action.implementationVersion != "unversioned",
              action.materials.count <= 32, action.resourceRevisions.count <= 64,
              action.materials.allSatisfy({ identifier($0.id) && identifier($0.version) && identifier($0.contentDigest) }),
              action.resourceRevisions.allSatisfy({ resources.contains($0.resource) && identifier($0.revision) }),
              Set(action.materials.map(\.id)).count == action.materials.count,
              Set(action.resourceRevisions.map(\.resource)).count == action.resourceRevisions.count else {
            throw ToolNoEffectError.invalidBinding
        }
    }

    package static func make(version: Int, invocationID: UUID, context: ToolContext,
                             definition: ModelToolDefinition, arguments: JSONValue, resources: [ToolResource],
                             action: ToolAuthorizationBinding, expectation: ToolReceiptExpectation?,
                             receipt: ToolReceipt, basis: String) throws -> Self {
        guard version == 1 || version == 2 else { throw ToolNoEffectError.unavailable }
        let inline = try version == 1 || (JSONEncoder().encode(arguments).count + JSONEncoder().encode(receipt).count <= 16_384)
        return .init(version: version, invocationID: invocationID, sessionID: context.sessionID,
            runID: context.runID, scopeInstanceID: context.executionAdmission?.scopeInstanceID,
            modelCallID: context.callID, definition: definition,
            canonicalArguments: inline ? arguments : nil,
            argumentBinding: version == 2 ? try .arguments(arguments) : nil,
            originalArgumentsUTF8Bytes: version == 2 ? context.argumentsJSON?.utf8.count : nil,
            resources: resources, actionBinding: action, receiptExpectation: expectation,
            receipt: inline ? receipt : nil, receiptSummary: version == 2 ? .init(receipt) : nil,
            wholeOperationHadNoEffect: true, noOutstandingEffects: true, basis: basis)
    }

    /// Reject statically unrepresentable metadata and schema-6/v1 calls before intent/executor.
    /// Reserve the maximum dynamic basis and receipt revision, using worst-case JSON escaping.
    package static func checkAdmission(context: ToolContext, definition: ModelToolDefinition,
                                      arguments: JSONValue, resources: [ToolResource],
                                      action: ToolAuthorizationBinding, expectation: ToolReceiptExpectation?) throws {
        try validateAction(action, resources: resources)
        guard let key = context.idempotencyKey, let raw = context.argumentsJSON,
              raw.utf8.count <= maximumInputBytes, key.utf8.count <= maximumCanonicalBytes,
              try ToolNoEffectDigest.arguments(arguments).utf8Bytes <= maximumCanonicalBytes else {
            throw ToolNoEffectError.payloadTooLarge
        }
        let reserve = String(repeating: "\u{0001}", count: 4096)
        let receipt = ToolReceipt(operationID: key, status: .failed, confirmedTargets: [], revision: reserve, failure: .rejected)
        let proof = try make(version: context.mutationAdmission?.noEffectProofVersion ?? 1, invocationID: UUID(),
            context: context, definition: definition, arguments: arguments, resources: resources,
            action: action, expectation: expectation, receipt: receipt, basis: reserve)
        // Reserve escaping for all remaining dynamic text; a compact proof remains compact.
        guard try JSONEncoder().encode(proof).count + (proof.version == 2 ? 16_384 : 0) <= maximumProofBytes else { throw ToolNoEffectError.payloadTooLarge }
    }
}

package struct ToolNoEffectBinding: Sendable {
    let token: UUID
    let invocationID: UUID
    let definition: ModelToolDefinition
    let canonicalArguments: JSONValue
    let resources: [ToolResource]
    let action: ToolAuthorizationBinding
    let expectation: ToolReceiptExpectation?
}

extension ToolContext {
    /// Call only after the trusted executor has established no effect for the entire
    /// operation and no outstanding action. HTTP status/error text is not that evidence.
    /// `error` is bounded model-visible text; `basis` remains restricted Journal material.
    public func confirmNoEffect(receipt: ToolReceipt, error: RecoverableToolError,
                                wholeOperationHadNoEffect: Bool, noOutstandingEffects: Bool,
                                basis: String) throws -> ConfirmedNoEffectToolError {
        try checkActive()
        guard let binding = noEffectBinding else { throw ToolNoEffectError.unavailable }
        guard wholeOperationHadNoEffect, noOutstandingEffects,
              !basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolNoEffectError.insufficientConfirmation
        }
        guard let idempotencyKey, receipt.operationID.utf8.elementsEqual(idempotencyKey.utf8), receipt.status == .failed,
              receipt.failure == .conflict || receipt.failure == .rejected,
              receipt.confirmedTargets.isEmpty else { throw ToolNoEffectError.invalidReceipt }
        try ToolNoEffectProof.validateReceipt(receipt, operationID: idempotencyKey, maximumRevisionBytes: 4096)
        let proof = try ToolNoEffectProof.make(version: mutationAdmission?.noEffectProofVersion ?? 1,
            invocationID: binding.invocationID, context: self, definition: binding.definition,
            arguments: binding.canonicalArguments, resources: binding.resources, action: binding.action,
            expectation: binding.expectation, receipt: receipt, basis: basis)
        guard basis.utf8.count <= 4096, try JSONEncoder().encode(error.payload).count <= 8192,
              try JSONEncoder().encode(proof).count <= ToolNoEffectProof.maximumProofBytes else { throw ToolNoEffectError.payloadTooLarge }
        try proof.validate(sessionID: sessionID, runID: runID, callID: callID, name: binding.definition.name,
            operationID: idempotencyKey, arguments: binding.canonicalArguments, resources: binding.resources,
            expectation: binding.expectation, originalArgumentsUTF8Bytes: argumentsJSON?.utf8.count)
        return .init(proof: proof, receipt: receipt, error: error, token: binding.token)
    }
}
