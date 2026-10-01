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
    public let canonicalArguments: JSONValue
    public let resources: [ToolResource]
    public let actionBinding: ToolAuthorizationBinding
    public let receiptExpectation: ToolReceiptExpectation?
    public let receipt: ToolReceipt
    public let wholeOperationHadNoEffect: Bool
    public let noOutstandingEffects: Bool
    public let basis: String
}

/// Only an SDK-issued executor context can construct this channel. A public error type
/// thrown by another callback does not acquire executor provenance.
public struct ConfirmedNoEffectToolError: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let proof: ToolNoEffectProof
    public let error: RecoverableToolError
    package let token: UUID
    public var description: String { "Confirmed no-effect executor outcome" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["status": description]) }
    package init(proof: ToolNoEffectProof, error: RecoverableToolError, token: UUID) {
        self.proof = proof; self.error = error; self.token = token
    }
}

public enum ToolNoEffectError: Error, Equatable, Sendable {
    case unavailable, insufficientConfirmation, invalidReceipt, invalidBinding, payloadTooLarge
}

extension ToolNoEffectProof {
    package func validate(sessionID: UUID, runID: UUID, callID: ToolCallID, name: String,
                          operationID: String, arguments: JSONValue, resources: [ToolResource], expectation: ToolReceiptExpectation?) throws {
        let identifier: (String) -> Bool = { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 }
        guard let backend = actionBinding.backend,
              [actionBinding.definitionVersion, actionBinding.implementationVersion, backend.instanceID,
               backend.version, backend.accountID, backend.credentialGeneration].allSatisfy(identifier),
              actionBinding.materials.count <= 32, actionBinding.resourceRevisions.count <= 64,
              actionBinding.materials.allSatisfy({ identifier($0.id) && identifier($0.version) && identifier($0.contentDigest) }),
              actionBinding.resourceRevisions.allSatisfy({ resources.contains($0.resource) && identifier($0.revision) }),
              Set(actionBinding.materials.map(\.id)).count == actionBinding.materials.count,
              Set(actionBinding.resourceRevisions.map(\.resource)).count == actionBinding.resourceRevisions.count else { throw ToolNoEffectError.invalidBinding }
        guard version == 1, self.sessionID == sessionID, self.runID == runID, modelCallID == callID,
              definition.name == name, receipt.operationID.utf8.elementsEqual(operationID.utf8),
              receipt.status == .failed, receipt.failure == .rejected || receipt.failure == .conflict,
              receipt.confirmedTargets.isEmpty, wholeOperationHadNoEffect, noOutstandingEffects,
              canonicalArguments == arguments, self.resources == resources, receiptExpectation == expectation,
              !basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              basis.utf8.count <= 4096, try JSONEncoder().encode(self).count <= 131072,
              actionBinding.backend != nil, actionBinding.implementationVersion != "unversioned" else {
            throw ToolNoEffectError.invalidBinding
        }
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
        let proof = ToolNoEffectProof(version: 1, invocationID: binding.invocationID,
            sessionID: sessionID, runID: runID, scopeInstanceID: executionAdmission?.scopeInstanceID, modelCallID: callID, definition: binding.definition,
            canonicalArguments: binding.canonicalArguments, resources: binding.resources,
            actionBinding: binding.action, receiptExpectation: binding.expectation, receipt: receipt, wholeOperationHadNoEffect: true,
            noOutstandingEffects: true, basis: basis)
        guard binding.action.backend != nil, binding.action.implementationVersion != "unversioned" else { throw ToolNoEffectError.invalidBinding }
        guard basis.utf8.count <= 4096, try JSONEncoder().encode(error.payload).count <= 8192,
              try JSONEncoder().encode(proof).count <= 131072 else { throw ToolNoEffectError.payloadTooLarge }
        try proof.validate(sessionID: sessionID, runID: runID, callID: callID, name: binding.definition.name,
            operationID: idempotencyKey, arguments: binding.canonicalArguments, resources: binding.resources, expectation: binding.expectation)
        return .init(proof: proof, error: error, token: binding.token)
    }
}
