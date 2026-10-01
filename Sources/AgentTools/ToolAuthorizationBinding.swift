import AgentModels
import Foundation

/// Non-secret identifiers for the actual backend/account captured by a Host tool.
public struct ToolAuthorizationBackend: Codable, Equatable, Sendable {
    public let instanceID: String
    public let version: String
    public let accountID: String
    public let credentialGeneration: String

    public init(instanceID: String, version: String, accountID: String, credentialGeneration: String) {
        self.instanceID = instanceID; self.version = version
        self.accountID = accountID; self.credentialGeneration = credentialGeneration
    }
}

public struct ToolAuthorizationResourceRevision: Codable, Equatable, Sendable {
    public let resource: ToolResource
    public let revision: String
    public init(resource: ToolResource, revision: String) { self.resource = resource; self.revision = revision }
}

/// A Host-declared immutable material or artifact version. A mutable path alone is insufficient.
public struct ToolAuthorizationMaterial: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let contentDigest: String
    public init(id: String, version: String, contentDigest: String) {
        self.id = id; self.version = version; self.contentDigest = contentDigest
    }
}

/// Additional action identity captured during preparation and checked again before dispatch.
/// The Host must also enforce revisions with immutable reads or conditional writes in its executor.
public struct ToolAuthorizationBinding: Codable, Equatable, Sendable {
    public let definitionVersion: String
    public let implementationVersion: String
    public let backend: ToolAuthorizationBackend?
    public let resourceRevisions: [ToolAuthorizationResourceRevision]
    public let materials: [ToolAuthorizationMaterial]

    public init(definitionVersion: String = "unversioned", implementationVersion: String = "unversioned",
                backend: ToolAuthorizationBackend? = nil,
                resourceRevisions: [ToolAuthorizationResourceRevision] = [],
                materials: [ToolAuthorizationMaterial] = []) {
        self.definitionVersion = definitionVersion; self.implementationVersion = implementationVersion
        self.backend = backend; self.resourceRevisions = resourceRevisions; self.materials = materials
    }
}

/// Tagged by the runtime at the actual throwing boundary, never inferred from
/// public error types that a Host callback can also throw.
package enum ToolAuditFailureOrigin: Sendable {
    case runtimeEvidence, toolAuthorization, toolDenied
}

/// Core supplies this process-local owner. A Host cannot manufacture one through ToolContext.
package protocol ToolAuditAuthorization: Sendable {
    var invocationID: UUID { get }
    func beginEvaluation()
    func noteFailureOrigin(_ origin: ToolAuditFailureOrigin)
    func authorize(context: ToolContext) async throws
    func recordToolAuthorization(_ value: ToolAuthorization?, failed: Bool) async throws
    func apply(mutation: ToolMutationAdmissionRequest?) async throws -> ToolMutationAdmissionResult?
    func checkFinal(binding: ToolAuthorizationBinding) throws
    func checkPreparedAction(definition: ModelToolDefinition, policy: ToolPolicy, resources: [ToolResource],
                             expectation: ToolReceiptExpectation?, binding: ToolAuthorizationBinding) throws
    func admitFinal() throws -> UUID
    func recordAdmission() async throws
    func observeExecutor()
    func releaseFinal(_ ticket: UUID)
    func failed(_ error: any Error) async throws
}
