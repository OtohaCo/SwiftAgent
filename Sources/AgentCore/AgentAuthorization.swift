import AgentModels
import AgentTools
import Foundation

public enum AgentAuthorizationMode: String, Codable, Sendable { case legacy, requiredAudit }

/// Trusted Host context, not authentication or a tenant isolation mechanism.
public struct AgentAuthorizationIdentity: Codable, Equatable, Sendable {
    public let securityDomain: String
    public let tenantID: String?
    public let projectID: String?
    public let subjectID: String
    public let actingSubjectID: String
    public let backend: ToolAuthorizationBackend

    public init(securityDomain: String, tenantID: String? = nil, projectID: String? = nil,
                subjectID: String, actingSubjectID: String, backend: ToolAuthorizationBackend) {
        self.securityDomain = securityDomain; self.tenantID = tenantID; self.projectID = projectID
        self.subjectID = subjectID; self.actingSubjectID = actingSubjectID; self.backend = backend
    }
}

public struct AuthorizationScope: Codable, Equatable, Sendable {
    public let storeID: UUID
    public let operationDomain: String
    public let sessionID: UUID
    public let runID: UUID
    public let authorizationScopeID: UUID
    public let capabilityScopeID: UUID?
    public let capabilityIdentity: String?
    public let capabilityVersion: String?
    public let capabilityGeneration: UInt64?
}

/// A frozen runtime request. It has no public initializer and is never constructed from model text.
public struct AuthorizationRequest: Sendable, Equatable {
    public let version: Int
    public let requestID: UUID
    public let authorizationID: UUID
    public let invocationID: UUID
    public let proposalID: UUID
    public let relatedProposalID: UUID?
    public let modelCallID: ToolCallID
    public let actionDigest: String
    public let scope: AuthorizationScope
    public let identity: AgentAuthorizationIdentity
    public let policyGeneration: UInt64
    public let toolDefinition: ModelToolDefinition
    public let toolPolicy: ToolPolicy
    public let normalizedArguments: JSONValue
    public let binding: ToolAuthorizationBinding
    public let resources: [ToolResource]
    public let receiptExpectation: ToolReceiptExpectation?
    public let operationID: String?
    public let sdkObservedAt: Date
    public let deadline: ContinuousClock.Instant
    /// The challenge never appears in Codable, Journal data, exports or public API.
    package let liveChallenge: UUID
}

public protocol AgentAuthorizer: Sendable {
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision
}

public struct AuthorizationSubject: Codable, Equatable, Sendable {
    public enum SubjectType: String, Codable, Sendable { case human, automatedPolicy, service }
    public let issuer: String
    public let subjectID: String
    public let type: SubjectType
    public init(issuer: String, subjectID: String, type: SubjectType) {
        self.issuer = issuer; self.subjectID = subjectID; self.type = type
    }
}

public struct AuthorizationPolicyReference: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let ruleReferences: [String]
    public init(id: String, version: String, ruleReferences: [String] = []) {
        self.id = id; self.version = version; self.ruleReferences = ruleReferences
    }
}

/// Codable is archival data. Decoding intentionally drops the current request's live challenge.
public struct AuthorizationDecision: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case allow, deny, requiresUserAction }
    public let version: Int
    public let requestID: UUID
    public let actionDigest: String
    public let scope: AuthorizationScope
    public let outcome: Outcome
    public let subject: AuthorizationSubject
    public let policy: AuthorizationPolicyReference
    public let policyGeneration: UInt64
    public let validFor: Duration
    public let notAfter: Date?
    public let hostDecisionTime: Date?
    public let reasonCode: String
    public let safeExplanation: String?
    public let externalApprovalReference: String?
    package let liveChallenge: UUID?

    public init(request: AuthorizationRequest, outcome: Outcome, subject: AuthorizationSubject,
                policy: AuthorizationPolicyReference, validFor: Duration,
                notAfter: Date? = nil, hostDecisionTime: Date? = nil, reasonCode: String,
                safeExplanation: String? = nil, externalApprovalReference: String? = nil) {
        version = 1; requestID = request.requestID; actionDigest = request.actionDigest; scope = request.scope
        self.outcome = outcome; self.subject = subject; self.policy = policy
        policyGeneration = request.policyGeneration; self.validFor = validFor
        self.notAfter = notAfter; self.hostDecisionTime = hostDecisionTime; self.reasonCode = reasonCode
        self.safeExplanation = safeExplanation; self.externalApprovalReference = externalApprovalReference
        liveChallenge = request.liveChallenge
    }

    private enum CodingKeys: String, CodingKey {
        case version, requestID, actionDigest, scope, outcome, subject, policy, policyGeneration,
             validFor, notAfter, hostDecisionTime, reasonCode, safeExplanation, externalApprovalReference
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        requestID = try c.decode(UUID.self, forKey: .requestID)
        actionDigest = try c.decode(String.self, forKey: .actionDigest)
        scope = try c.decode(AuthorizationScope.self, forKey: .scope)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        subject = try c.decode(AuthorizationSubject.self, forKey: .subject)
        policy = try c.decode(AuthorizationPolicyReference.self, forKey: .policy)
        policyGeneration = try c.decode(UInt64.self, forKey: .policyGeneration)
        validFor = try c.decode(Duration.self, forKey: .validFor)
        notAfter = try c.decodeIfPresent(Date.self, forKey: .notAfter)
        hostDecisionTime = try c.decodeIfPresent(Date.self, forKey: .hostDecisionTime)
        reasonCode = try c.decode(String.self, forKey: .reasonCode)
        safeExplanation = try c.decodeIfPresent(String.self, forKey: .safeExplanation)
        externalApprovalReference = try c.decodeIfPresent(String.self, forKey: .externalApprovalReference)
        liveChallenge = nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Archival equality says nothing about executable permission.
        (try? AuditEncoding.encode(lhs)) == (try? AuditEncoding.encode(rhs))
    }
}

public struct AgentAuthorizationConfiguration: Sendable {
    public let mode: AgentAuthorizationMode
    public let authorizer: (any AgentAuthorizer)?
    public let identity: AgentAuthorizationIdentity?
    public let scope: AgentAuthorizationScope
    public let authorizerTimeout: Duration
    public let maximumDecisionLifetime: Duration
    public let backlog: AuditBacklogPolicy?
    /// Host-selected lineage for a newly dispatched Run, never an approval credential.
    public let relatedProposalID: UUID?
    var testingHooks: AgentAuditTestingHooks? = nil

    public init(mode: AgentAuthorizationMode = .legacy, authorizer: (any AgentAuthorizer)? = nil,
                identity: AgentAuthorizationIdentity? = nil, scope: AgentAuthorizationScope = .init(),
                authorizerTimeout: Duration = .seconds(30), maximumDecisionLifetime: Duration = .seconds(300),
                backlog: AuditBacklogPolicy? = nil, relatedProposalID: UUID? = nil) {
        self.mode = mode; self.authorizer = authorizer; self.identity = identity; self.scope = scope
        self.authorizerTimeout = authorizerTimeout; self.maximumDecisionLifetime = maximumDecisionLifetime
        self.backlog = backlog
        self.relatedProposalID = relatedProposalID
    }

    package func validate(journal: AgentJournal?) throws {
        guard mode == .requiredAudit else { return }
        guard journal?.supportsAuthorizationAudit == true, journal?.storage == .durable else {
            throw AgentAuthorizationError.auditStoreRequired
        }
        guard authorizer != nil else { throw AgentAuthorizationError.missingAuthorizer }
        guard let identity else { throw AgentAuthorizationError.missingIdentity }
        guard authorizerTimeout > .zero, maximumDecisionLifetime > .zero,
              maximumDecisionLifetime <= .seconds(3600) else { throw AgentAuthorizationError.invalidConfiguration }
        try AuditEncoding.validateIdentity(identity)
        try backlog?.validate()
        try scope.check()
    }
}

struct AgentAuditTestingHooks: Sendable {
    var receivedCommitted: (@Sendable () async -> Void)? = nil
    var beforeApplication: (@Sendable () async -> Void)? = nil
    var applicationCommitted: (@Sendable () async -> Void)? = nil
    var finalAdmitted: (@Sendable () async -> Void)? = nil
}

/// Optional local export pressure. It never changes settlement or authorizes execution.
public struct AuditBacklogPolicy: Sendable {
    public let exportConfigurationID: String
    public let maximumUnacknowledgedRecords: UInt64
    public init(exportConfigurationID: String, maximumUnacknowledgedRecords: UInt64) {
        self.exportConfigurationID = exportConfigurationID
        self.maximumUnacknowledgedRecords = maximumUnacknowledgedRecords
    }
    package func validate() throws {
        guard AuditEncoding.identifier(exportConfigurationID), maximumUnacknowledgedRecords >= 16 else {
            throw AgentAuthorizationError.invalidConfiguration
        }
    }
}

public enum AgentAuthorizationError: Error, Equatable, Sendable {
    case auditStoreRequired, missingAuthorizer, missingIdentity, invalidConfiguration
    case auditUnavailable, proposalTooLarge, tooManyInvocations, invalidDecision, invalidProposalReference
    case authorizationDenied, requiresUserAction, authorizerFailed, authorizerTimedOut
    case actionChanged, expired, revoked, policyGenerationMismatch
    case invalidQuery, cursorMismatch, invalidAcknowledgement, staleExporter, exporterInUse, exporterStopped
    case redactionFailed, backlogExceeded
}

package enum AuditEncoding {
    package static let maximumRawBytes = 64 * 1024
    package static let maximumRecordBytes = 256 * 1024
    package static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    package static func identifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 512
    }
    package static func validateIdentity(_ value: AgentAuthorizationIdentity) throws {
        guard [value.securityDomain, value.subjectID, value.actingSubjectID, value.backend.instanceID,
               value.backend.version, value.backend.accountID, value.backend.credentialGeneration].allSatisfy(identifier),
              [value.tenantID, value.projectID].compactMap({ $0 }).allSatisfy(identifier) else {
            throw AgentAuthorizationError.missingIdentity
        }
    }
}
