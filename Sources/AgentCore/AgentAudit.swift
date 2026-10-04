import AgentModels
import AgentTools
import Foundation

public struct AuditRecordLinks: Codable, Equatable, Sendable {
    public let storeID: UUID
    public let operationDomain: String
    public let sessionID: UUID
    public let runID: UUID
    public let invocationID: UUID
    public let modelCallID: String
    public let proposalID: UUID
    public let authorizationID: UUID?
    public let requestID: UUID?
    /// Existing mutation identity, including canonical arguments. Restricted to trusted queries.
    public let operationID: String?
    public let logicalOperationID: String?
    public let relatedProposalID: UUID?

    package init(storeID: UUID, operationDomain: String, sessionID: UUID, runID: UUID,
                 invocationID: UUID, modelCallID: String, proposalID: UUID,
                 authorizationID: UUID? = nil, requestID: UUID? = nil, operationID: String? = nil,
                 logicalOperationID: String? = nil, relatedProposalID: UUID? = nil) {
        self.storeID = storeID; self.operationDomain = operationDomain; self.sessionID = sessionID
        self.runID = runID; self.invocationID = invocationID; self.modelCallID = modelCallID
        self.proposalID = proposalID; self.authorizationID = authorizationID; self.requestID = requestID
        self.operationID = operationID; self.logicalOperationID = logicalOperationID; self.relatedProposalID = relatedProposalID
    }

    package func authorizing(_ request: AuthorizationRequest) -> Self {
        .init(storeID: storeID, operationDomain: operationDomain, sessionID: sessionID, runID: runID,
              invocationID: invocationID, modelCallID: modelCallID, proposalID: proposalID,
              authorizationID: request.authorizationID, requestID: request.requestID,
              operationID: operationID, logicalOperationID: logicalOperationID, relatedProposalID: relatedProposalID)
    }

    package var indexKeys: [String] {
        ["session/\(sessionID)", "run/\(runID)", "invocation/\(invocationID)", "proposal/\(proposalID)"]
            + authorizationID.map { ["authorization/\($0)"] }.orEmpty
            + operationID.map { ["operation/\($0)"] }.orEmpty
            + logicalOperationID.map { ["logical/\($0)"] }.orEmpty
    }
}

private extension Optional where Wrapped == [String] {
    var orEmpty: [String] { self ?? [] }
}

/// Restricted raw payload and the normalized semantics are retained independently of conversation.
public struct AuditProposal: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case received, prepared }
    public let stage: Stage
    public let toolName: String
    public let rawArgumentsJSON: String?
    public let normalizedArguments: JSONValue?
    public let originalUTF8Bytes: Int
    public let payloadTruncated: Bool
    public let reconstructable: Bool
    public let definition: ModelToolDefinition?
    public let policy: ToolPolicy?
    public let binding: ToolAuthorizationBinding?
    public let resources: [ToolResource]?
    public let receiptExpectation: ToolReceiptExpectation?
    public let actionDigest: String?
    public let identity: AgentAuthorizationIdentity?
    public let scope: AuthorizationScope?

    package func regularView() -> Self {
        .init(stage: stage, toolName: toolName, rawArgumentsJSON: nil, normalizedArguments: nil,
              originalUTF8Bytes: originalUTF8Bytes, payloadTruncated: payloadTruncated,
              reconstructable: reconstructable, definition: nil, policy: policy, binding: nil,
              resources: nil, receiptExpectation: nil, actionDigest: actionDigest, identity: identity, scope: scope)
    }
}

public struct AuditAuthorizationEvaluation: Codable, Equatable, Sendable {
    public enum Layer: String, Codable, Sendable { case enterprise, tool }
    public enum Status: String, Codable, Sendable {
        case allowed, denied, requiresUserAction, notEvaluated, incomplete, notRequired, invalidDecision
    }
    public let layer: Layer
    public let status: Status
    public let decision: AuthorizationDecision?
    public let reasonCode: String?
    package init(layer: Layer, status: Status, decision: AuthorizationDecision? = nil, reasonCode: String? = nil) {
        self.layer = layer; self.status = status; self.decision = decision; self.reasonCode = reasonCode
    }
}

public struct AuditExecutionDisposition: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case dispatchPrepared, runtimeAdmitted, executorObserved, notExecuted, interrupted, uncertain
    }
    public let state: State
    public let reasonCode: String?
    public let actionDigest: String?
    public let localPolicyGeneration: UInt64?
    package init(state: State, reasonCode: String? = nil, actionDigest: String? = nil, localPolicyGeneration: UInt64? = nil) {
        self.state = state; self.reasonCode = reasonCode; self.actionDigest = actionDigest
        self.localPolicyGeneration = localPolicyGeneration
    }
}

/// This is a reference to the authoritative ledger/result, not another mutation success state.
public struct AuditResultReference: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case settlement, readOnlyOutput, replay, reconciliation, noEffectConfirmation }
    public let kind: Kind
    public let sourceSessionID: UUID
    public let sourceRunID: UUID
    public let sourceModelCallID: String
    public let receipt: ToolReceipt?
    public let outputDigest: String?
    public let settlementSource: AgentMutationSettlementSource?
    /// SHA-256 digests of the images the result gave the model (ADR 0012); never their bytes.
    /// Nil when there were none, so records without images keep their encoding.
    public let imageDigests: [String]?
    package init(kind: Kind, sourceSessionID: UUID, sourceRunID: UUID, sourceModelCallID: String,
                 receipt: ToolReceipt? = nil, outputDigest: String? = nil,
                 settlementSource: AgentMutationSettlementSource? = nil, imageDigests: [String]? = nil) {
        self.kind = kind; self.sourceSessionID = sourceSessionID; self.sourceRunID = sourceRunID
        self.sourceModelCallID = sourceModelCallID; self.receipt = receipt
        self.outputDigest = outputDigest; self.settlementSource = settlementSource
        self.imageDigests = imageDigests?.isEmpty == true ? nil : imageDigests
    }
}

public enum AuditFact: Codable, Equatable, Sendable {
    case proposal(AuditProposal)
    case authorization(AuditAuthorizationEvaluation)
    case disposition(AuditExecutionDisposition)
    case result(AuditResultReference)
}

/// Stable immutable committed fact. Digests cover the restricted original, not a redacted view.
public struct AuditRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let auditRecordID: UUID
    /// Global audit publication order, starting at 1, within this store.
    public let sequence: UInt64
    /// Order shared with ordinary Journal lifecycle records.
    public let journalRecordSequence: UInt64
    public let sdkObservedAt: Date
    public let links: AuditRecordLinks
    public let fact: AuditFact
    public let digest: String
    public let restrictedPayloadIncluded: Bool

    package init(version: Int = 1, auditRecordID: UUID, sequence: UInt64, journalRecordSequence: UInt64,
                 sdkObservedAt: Date, links: AuditRecordLinks, fact: AuditFact, digest: String,
                 restrictedPayloadIncluded: Bool = true) {
        self.version = version; self.auditRecordID = auditRecordID; self.sequence = sequence
        self.journalRecordSequence = journalRecordSequence; self.sdkObservedAt = sdkObservedAt
        self.links = links; self.fact = fact; self.digest = digest
        self.restrictedPayloadIncluded = restrictedPayloadIncluded
    }

    package func regularView() -> Self {
        let view: AuditFact
        switch fact {
        case .proposal(let p): view = .proposal(p.regularView())
        case .result(let r):
            view = .result(.init(kind: r.kind, sourceSessionID: r.sourceSessionID, sourceRunID: r.sourceRunID,
                sourceModelCallID: r.sourceModelCallID, outputDigest: r.outputDigest, settlementSource: r.settlementSource,
                imageDigests: r.imageDigests))
        default: view = fact
        }
        let boundedLinks = AuditRecordLinks(storeID: links.storeID, operationDomain: links.operationDomain,
            sessionID: links.sessionID, runID: links.runID, invocationID: links.invocationID,
            modelCallID: links.modelCallID, proposalID: links.proposalID, authorizationID: links.authorizationID,
            requestID: links.requestID, operationID: nil, logicalOperationID: links.logicalOperationID,
            relatedProposalID: links.relatedProposalID)
        return .init(version: version, auditRecordID: auditRecordID, sequence: sequence,
            journalRecordSequence: journalRecordSequence, sdkObservedAt: sdkObservedAt, links: boundedLinks,
            fact: view, digest: digest, restrictedPayloadIncluded: false)
    }

    package func unsignedBytes() throws -> Data {
        try AuditEncoding.encode(Unsigned(version: version, auditRecordID: auditRecordID,
            sequence: sequence, journalRecordSequence: journalRecordSequence, sdkObservedAt: sdkObservedAt,
            links: links, fact: fact))
    }

    private struct Unsigned: Codable {
        let version: Int; let auditRecordID: UUID; let sequence: UInt64; let journalRecordSequence: UInt64
        let sdkObservedAt: Date; let links: AuditRecordLinks; let fact: AuditFact
    }

    package func validate() throws {
        guard version == 1, sequence > 0, journalRecordSequence > 0, restrictedPayloadIncluded,
              links.modelCallID.utf8.count <= 512, links.operationDomain.utf8.count <= 512,
              links.operationID.map({ $0.utf8.count <= 96 * 1024 }) ?? true,
              links.logicalOperationID.map(AuditEncoding.identifier) ?? true,
              digest.utf8.count == 64, try unsignedBytes().count <= AuditEncoding.maximumRecordBytes else {
            throw AgentJournalError.invalidRecord
        }
        if case .proposal(let p) = fact {
            guard p.toolName.utf8.count <= 512,
                  p.rawArgumentsJSON.map({ $0.utf8.count <= AuditEncoding.maximumRawBytes }) ?? true,
                  p.originalUTF8Bytes >= 0, !p.payloadTruncated || !p.reconstructable else {
                throw AgentJournalError.invalidRecord
            }
        }
    }
}

/// Host administration only; never installed as a model tool. All non-nil fields are AND filters.
public struct AuditQuery: Codable, Equatable, Sendable {
    public let sessionID: UUID?
    public let runID: UUID?
    public let invocationID: UUID?
    public let proposalID: UUID?
    public let authorizationID: UUID?
    public let operationID: String?
    public let logicalOperationID: String?
    public init(sessionID: UUID? = nil, runID: UUID? = nil, invocationID: UUID? = nil, proposalID: UUID? = nil,
                authorizationID: UUID? = nil, operationID: String? = nil, logicalOperationID: String? = nil) {
        self.sessionID = sessionID; self.runID = runID; self.invocationID = invocationID; self.proposalID = proposalID
        self.authorizationID = authorizationID; self.operationID = operationID; self.logicalOperationID = logicalOperationID
    }
    package var indexKey: String? {
        if let invocationID { return "invocation/\(invocationID)" }
        if let proposalID { return "proposal/\(proposalID)" }
        if let authorizationID { return "authorization/\(authorizationID)" }
        if let operationID { return "operation/\(operationID)" }
        if let logicalOperationID { return "logical/\(logicalOperationID)" }
        if let runID { return "run/\(runID)" }
        if let sessionID { return "session/\(sessionID)" }
        return nil
    }
    package func matches(_ links: AuditRecordLinks) -> Bool {
        (sessionID == nil || sessionID == links.sessionID) && (runID == nil || runID == links.runID)
            && (invocationID == nil || invocationID == links.invocationID)
            && (proposalID == nil || proposalID == links.proposalID)
            && (authorizationID == nil || authorizationID == links.authorizationID)
            && (operationID == nil || operationID == links.operationID)
            && (logicalOperationID == nil || logicalOperationID == links.logicalOperationID)
    }
}

public struct AuditCursor: Codable, Equatable, Sendable {
    package let storeID: UUID
    package let queryDigest: String
    public let highWaterSequence: UInt64
    public let afterExclusiveSequence: UInt64
    package let nextOrdinal: UInt64
    package let restricted: Bool
    package let digest: String
}

public struct AuditPage: Sendable, Equatable {
    public let records: [AuditRecord]
    public let highWaterSequence: UInt64
    public let nextCursor: AuditCursor?
    /// Advances even over non-matching records. Work per page is bounded.
    public let scannedThroughSequence: UInt64
}

package struct JournalAuditDraft: Sendable {
    package let links: AuditRecordLinks
    package let fact: AuditFact
    package let observedAt: Date
    package init(links: AuditRecordLinks, fact: AuditFact, observedAt: Date = Date()) {
        self.links = links; self.fact = fact; self.observedAt = observedAt
    }
}

package struct JournalAuditChange: Sendable {
    package let records: [AuditRecord]
    package let admitsNewWork: Bool
}

package struct JournalAuditExportCheckpoint: Codable, Equatable, Sendable {
    package let configurationID: String
    package let configurationDigest: String
    package let throughSequence: UInt64
    package let batchID: UUID
    package let batchDigest: String
    package init(configurationID: String, configurationDigest: String, throughSequence: UInt64,
                 batchID: UUID, batchDigest: String) {
        self.configurationID = configurationID; self.configurationDigest = configurationDigest
        self.throughSequence = throughSequence; self.batchID = batchID; self.batchDigest = batchDigest
    }
}

package struct JournalAuditExportChange: Sendable {
    package let checkpoint: JournalAuditExportCheckpoint
    package let expectedThroughSequence: UInt64
}
