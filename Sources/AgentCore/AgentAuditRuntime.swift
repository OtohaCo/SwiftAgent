import AgentModels
import AgentTools
import Foundation

/// One Run's audit ownership. It is part of AgentLoop, never a second executor.
package actor AgentAuditRuntime {
    let configuration: AgentAuthorizationConfiguration
    let journal: AgentJournal
    let scope: AuthorizationScope
    let identity: AgentAuthorizationIdentity
    private let work = AgentAuditWorkDrain()
    private var received: [ToolCallID: AuditRecordLinks] = [:]
    private var unprepared: [UUID: AuditRecordLinks] = [:]
    private var prepared: [UUID: AgentAuditInvocation] = [:]
    private var previousProposal: [String: UUID] = [:]
    private var captured = 0

    init(configuration: AgentAuthorizationConfiguration, journal: AgentJournal, identity: AgentAuthorizationIdentity,
         store: JournalStoreIdentity, sessionID: UUID, runID: UUID, capability: AgentCapabilityInfo?) {
        self.configuration = configuration; self.journal = journal; self.identity = identity
        scope = .init(storeID: store.storeID, operationDomain: store.operationDomain, sessionID: sessionID,
            runID: runID, authorizationScopeID: configuration.scope.id, capabilityScopeID: capability?.scopeInstanceID,
            capabilityIdentity: capability?.identity, capabilityVersion: capability?.version,
            capabilityGeneration: capability?.capturedGeneration)
    }

    func capture(_ call: ToolCall, operationID: String?, mutationIdentity: String?) async throws {
        guard captured < 64 else { throw AgentAuthorizationError.tooManyInvocations }
        captured += 1
        let bounded = call.argumentsJSON.utf8.count <= AuditEncoding.maximumRawBytes
            && call.name.utf8.count <= 512 && call.id.rawValue.utf8.count <= 512
        let links = AuditRecordLinks(storeID: scope.storeID, operationDomain: scope.operationDomain,
            sessionID: scope.sessionID, runID: scope.runID, invocationID: UUID(),
            modelCallID: Self.prefix(call.id.rawValue, bytes: 512), proposalID: UUID(),
            operationID: bounded ? mutationIdentity : nil, logicalOperationID: operationID,
            relatedProposalID: previousProposal[Self.prefix(call.name, bytes: 512)] ?? configuration.relatedProposalID)
        let proposal = AuditProposal(stage: .received, toolName: Self.prefix(call.name, bytes: 512),
            rawArgumentsJSON: bounded ? call.argumentsJSON : Self.prefix(call.argumentsJSON, bytes: 4096),
            normalizedArguments: nil, originalUTF8Bytes: call.argumentsJSON.utf8.count,
            payloadTruncated: !bounded, reconstructable: bounded && call.completeness == .complete,
            definition: nil, policy: nil, binding: nil, resources: nil, receiptExpectation: nil,
            actionDigest: nil, identity: identity, scope: scope)
        try await journal.appendAudit([.init(links: links, fact: .proposal(proposal))], admitsNewWork: true)
        received[call.id] = links
        unprepared[links.invocationID] = links
        previousProposal[proposal.toolName] = links.proposalID
        if !bounded {
            try await rejected(call.id, reason: "proposal_too_large")
            throw AgentAuthorizationError.proposalTooLarge
        }
        await configuration.testingHooks?.receivedCommitted?()
    }

    func prepare(_ call: PreparedToolCall, deadline: ContinuousClock.Instant) async throws -> PreparedToolCall {
        guard let links = received[call.call.id] else { throw AgentAuthorizationError.auditUnavailable }
        let arguments = try JSONValue.decodeToolArguments(call.call.argumentsJSON)
        try Self.validateBinding(call.binding, resources: call.resources)
        let material = Action(version: 1, scope: scope, relatedProposalID: links.relatedProposalID, identity: identity, definition: call.definition,
            policy: call.policy, binding: call.binding, arguments: arguments, resources: call.resources,
            receiptExpectation: call.receiptExpectation)
        let bytes = try AuditEncoding.encode(material)
        guard bytes.count <= 128 * 1024 else { throw AgentAuthorizationError.proposalTooLarge }
        let digest = "sha256-action-v1:" + (try await journal.auditDigest(bytes))
        let request = AuthorizationRequest(version: 1, requestID: UUID(), authorizationID: UUID(),
            invocationID: links.invocationID, proposalID: links.proposalID, relatedProposalID: links.relatedProposalID, modelCallID: call.call.id,
            actionDigest: digest, scope: scope, identity: identity, policyGeneration: configuration.scope.policyGeneration,
            toolDefinition: call.definition, toolPolicy: call.policy, normalizedArguments: arguments,
            binding: call.binding, resources: call.resources, receiptExpectation: call.receiptExpectation,
            operationID: links.operationID, sdkObservedAt: Date(), deadline: deadline, liveChallenge: UUID())
        let proposal = AuditProposal(stage: .prepared, toolName: call.call.name, rawArgumentsJSON: nil,
            normalizedArguments: arguments, originalUTF8Bytes: call.call.argumentsJSON.utf8.count,
            payloadTruncated: false, reconstructable: true, definition: call.definition, policy: call.policy,
            binding: call.binding, resources: call.resources, receiptExpectation: call.receiptExpectation,
            actionDigest: digest, identity: identity, scope: scope)
        try await journal.appendAudit([.init(links: links.authorizing(request), fact: .proposal(proposal))])
        received[call.call.id] = links.authorizing(request)
        unprepared.removeValue(forKey: links.invocationID)
        let invocation = AgentAuditInvocation(request: request, links: links.authorizing(request),
            journal: journal, configuration: configuration, work: work)
        prepared[links.invocationID] = invocation
        return call.boundToAudit(invocation)
    }

    func rejected(_ callID: ToolCallID, reason: String) async throws {
        guard let links = received[callID] else { return }
        try await journal.appendAudit([
            .init(links: links, fact: .authorization(.init(layer: .enterprise, status: .notEvaluated, reasonCode: reason))),
            .init(links: links, fact: .disposition(.init(state: .notExecuted, reasonCode: reason))),
        ])
        unprepared.removeValue(forKey: links.invocationID)
        prepared.removeValue(forKey: links.invocationID)
    }

    func closeUnstarted(_ error: any Error) async throws {
        for invocation in prepared.values { try await invocation.closeUnstarted(error) }
    }

    func rejectUnprepared(_ error: any Error) async throws {
        while !unprepared.isEmpty {
            let pending = Array(unprepared.values.prefix(32))
            let drafts = pending.flatMap { links in [
                JournalAuditDraft(links: links, fact: .authorization(.init(layer: .enterprise,
                    status: .notEvaluated, reasonCode: AgentAuditInvocation.reason(error)))),
                JournalAuditDraft(links: links, fact: .disposition(.init(state: .notExecuted,
                    reasonCode: AgentAuditInvocation.reason(error)))),
            ] }
            try await journal.appendAudit(drafts)
            for links in pending { unprepared.removeValue(forKey: links.invocationID) }
        }
    }

    func beginBody() async { await work.begin() }
    func finishBody() async { await work.end() }
    func waitForDrain() async { await work.wait() }

    private struct Action: Codable {
        let version: Int; let scope: AuthorizationScope; let relatedProposalID: UUID?; let identity: AgentAuthorizationIdentity
        let definition: ModelToolDefinition; let policy: ToolPolicy; let binding: ToolAuthorizationBinding
        let arguments: JSONValue; let resources: [ToolResource]; let receiptExpectation: ToolReceiptExpectation?
    }

    private static func prefix(_ value: String, bytes: Int) -> String {
        // Iterate the prefix only; do not copy a maliciously large payload into an Array/Data.
        var result = "", count = 0
        for scalar in value.unicodeScalars {
            let size = scalar.utf8.count
            if count + size > bytes { break }
            result.unicodeScalars.append(scalar); count += size
        }
        return result
    }

    private static func validateBinding(_ binding: ToolAuthorizationBinding, resources: [ToolResource]) throws {
        guard AuditEncoding.identifier(binding.definitionVersion), AuditEncoding.identifier(binding.implementationVersion),
              binding.materials.count <= 32, binding.resourceRevisions.count <= 64,
              binding.materials.allSatisfy({ AuditEncoding.identifier($0.id) && AuditEncoding.identifier($0.version) && AuditEncoding.identifier($0.contentDigest) }),
              binding.resourceRevisions.allSatisfy({ resources.contains($0.resource) && AuditEncoding.identifier($0.revision) }),
              Set(binding.materials.map(\.id)).count == binding.materials.count,
              Set(binding.resourceRevisions.map(\.resource)).count == binding.resourceRevisions.count else {
            throw AgentAuthorizationError.invalidConfiguration
        }
        if let backend = binding.backend {
            guard [backend.instanceID, backend.version, backend.accountID, backend.credentialGeneration].allSatisfy(AuditEncoding.identifier) else {
                throw AgentAuthorizationError.invalidConfiguration
            }
        }
    }
}

actor AgentAuditWorkDrain {
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func begin() { active += 1 }
    func end() {
        active -= 1
        if active == 0 { let ready = waiters; waiters.removeAll(); ready.forEach { $0.resume() } }
    }
    func wait() async {
        if active == 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// No public initializer, no Codable, no durable permit. Every invocation owns its current request.
final class AgentAuditInvocation: ToolAuditAuthorization, @unchecked Sendable {
    let request: AuthorizationRequest
    let links: AuditRecordLinks
    private let journal: AgentJournal
    private let configuration: AgentAuthorizationConfiguration
    private let work: AgentAuditWorkDrain
    private let lock = NSLock()
    private var expires: ContinuousClock.Instant?
    private var enterpriseEvaluated = false
    private var enterpriseStarted = false
    private var dispatchPrepared = false
    private var admitted = false
    private var executorObserved = false
    private var replaySource: JournalStoredMutation?
    private var failureRecorded = false
    private var dispatchStarted = false
    private var enterprisePhase = false
    private var failureOrigin: ToolAuditFailureOrigin?

    init(request: AuthorizationRequest, links: AuditRecordLinks, journal: AgentJournal,
         configuration: AgentAuthorizationConfiguration, work: AgentAuditWorkDrain) {
        self.request = request; self.links = links; self.journal = journal
        self.configuration = configuration; self.work = work
    }

    func beginEvaluation() { lock.withLock { dispatchStarted = true } }
    func noteFailureOrigin(_ origin: ToolAuditFailureOrigin) {
        lock.withLock { if failureOrigin == nil { failureOrigin = origin } }
    }

    /// The scheduler has ended without ever starting this invocation. A started
    /// or completed sibling must retain its own execution/settlement facts.
    func closeUnstarted(_ error: any Error) async throws {
        let shouldClose = lock.withLock {
            guard !dispatchStarted, !failureRecorded else { return false }
            failureRecorded = true
            return true
        }
        guard shouldClose else { return }
        let reason = error is CancellationError ? "cancelled_before_scheduling" : "batch_stopped_before_scheduling"
        try await journal.appendAudit([
            .init(links: links, fact: .authorization(.init(layer: .enterprise, status: .notEvaluated, reasonCode: reason))),
            .init(links: links, fact: .disposition(.init(state: .notExecuted, reasonCode: reason))),
        ])
    }

    func authorize(context: ToolContext) async throws {
        lock.withLock { enterprisePhase = true }
        guard let authorizer = configuration.authorizer else { throw AgentAuthorizationError.missingAuthorizer }
        try configuration.scope.check(expectedGeneration: request.policyGeneration)
        try await journal.checkAuditAvailability(backlog: configuration.backlog)
        let started = ContinuousClock.now
        let deadline = min(context.deadline ?? request.deadline, started.advanced(by: configuration.authorizerTimeout))
        await work.begin()
        do {
            try await withOperationDeadline(deadline, timeoutError: AgentAuthorizationError.authorizerTimedOut) {
                let decision: AuthorizationDecision
                self.lock.withLock { self.enterpriseStarted = true }
                do { decision = try await authorizer.decide(self.request) }
                catch {
                    try await self.recordEnterprise(.init(layer: .enterprise, status: .incomplete,
                        reasonCode: Task.isCancelled ? "authorizer_cancelled" : "authorizer_error"))
                    if error is CancellationError { throw CancellationError() }
                    throw AgentAuthorizationError.authorizerFailed
                }
                let sized = try self.validateDecision(decision, started: started)
                let correlated = decision.liveChallenge == self.request.liveChallenge
                    && decision.requestID == self.request.requestID && decision.actionDigest == self.request.actionDigest
                    && decision.scope == self.request.scope && decision.policyGeneration == self.request.policyGeneration
                let status: AuditAuthorizationEvaluation.Status
                if !sized || !correlated { status = .invalidDecision }
                else {
                    switch decision.outcome {
                    case .allow: status = .allowed
                    case .deny: status = .denied
                    case .requiresUserAction: status = .requiresUserAction
                    }
                }
                // Actual decisions are recorded even when cancellation or expiry makes them unusable.
                try await self.recordEnterprise(.init(layer: .enterprise, status: status,
                    decision: sized ? decision : nil, reasonCode: sized ? nil : "invalid_decision"))
                guard sized, correlated else {
                    throw AgentAuthorizationError.invalidDecision
                }
                try context.checkActive()
                try self.configuration.scope.check(expectedGeneration: self.request.policyGeneration)
                guard ContinuousClock.now < deadline else { throw AgentAuthorizationError.authorizerTimedOut }
                switch decision.outcome {
                case .deny: throw AgentAuthorizationError.authorizationDenied
                case .requiresUserAction: throw AgentAuthorizationError.requiresUserAction
                case .allow: break
                }
                var expires = min(self.request.deadline, started.advanced(by: decision.validFor))
                if let notAfter = decision.notAfter {
                    let seconds = notAfter.timeIntervalSinceNow
                    guard seconds > 0 else { throw AgentAuthorizationError.expired }
                    expires = min(expires, ContinuousClock.now.advanced(by: .seconds(seconds)))
                }
                guard ContinuousClock.now < expires else { throw AgentAuthorizationError.expired }
                self.lock.withLock { self.expires = expires; self.enterprisePhase = false }
            } onOperationFinished: { await self.work.end() }
        } catch { throw error }
    }

    private func validateDecision(_ value: AuthorizationDecision, started: ContinuousClock.Instant) throws -> Bool {
        guard value.version == 1, value.validFor > .zero,
              value.validFor <= configuration.maximumDecisionLifetime,
              [value.subject.issuer, value.subject.subjectID, value.policy.id, value.policy.version, value.reasonCode].allSatisfy(AuditEncoding.identifier),
              value.policy.ruleReferences.count <= 32, value.policy.ruleReferences.allSatisfy(AuditEncoding.identifier),
              value.safeExplanation.map({ $0.utf8.count <= 2048 }) ?? true,
              value.externalApprovalReference.map(AuditEncoding.identifier) ?? true,
              try AuditEncoding.encode(value).count <= 16 * 1024 else { return false }
        return true
    }

    private func recordEnterprise(_ value: AuditAuthorizationEvaluation) async throws {
        try await journal.appendAudit([.init(links: links, fact: .authorization(value))])
        lock.withLock { enterpriseEvaluated = true }
    }

    func recordToolAuthorization(_ value: ToolAuthorization?, failed: Bool) async throws {
        let status: AuditAuthorizationEvaluation.Status = failed ? .incomplete : value.map { $0 == .allowed ? .allowed : .denied } ?? .notRequired
        try await journal.appendAudit([.init(links: links, fact: .authorization(.init(layer: .tool, status: status)))])
        if value == .denied { noteFailureOrigin(.toolDenied) }
    }

    func apply(mutation: ToolMutationAdmissionRequest?) async throws -> ToolMutationAdmissionResult? {
        try checkFinal(binding: request.binding)
        try await journal.checkAuditAvailability(backlog: configuration.backlog)
        await configuration.testingHooks?.beforeApplication?()
        let draft = JournalAuditDraft(links: links, fact: .disposition(.init(state: .dispatchPrepared,
            actionDigest: request.actionDigest, localPolicyGeneration: request.policyGeneration)))
        let result: ToolMutationAdmissionResult?
        if let mutation { result = try await journal.admit(mutation, auditDrafts: [draft], backlog: configuration.backlog) }
        else { try await journal.appendAudit([draft], admitsNewWork: true, backlog: configuration.backlog); result = nil }
        lock.withLock { dispatchPrepared = true }
        await configuration.testingHooks?.applicationCommitted?()
        if case .settled = result, let key = links.operationID {
            let source = try await journal.auditMutationSource(identity: key)
            lock.withLock { replaySource = source }
        }
        return result
    }

    func checkFinal(binding: ToolAuthorizationBinding) throws {
        try Task.checkCancellation()
        guard binding == request.binding else { throw AgentAuthorizationError.actionChanged }
        let expires = lock.withLock { expires }
        guard let expires, ContinuousClock.now < expires else { throw AgentAuthorizationError.expired }
        try configuration.scope.check(expectedGeneration: request.policyGeneration)
    }

    func checkPreparedAction(definition: ModelToolDefinition, policy: ToolPolicy, resources: [ToolResource],
                             expectation: ToolReceiptExpectation?, binding: ToolAuthorizationBinding) throws {
        guard definition == request.toolDefinition, policy == request.toolPolicy, resources == request.resources,
              expectation == request.receiptExpectation else { throw AgentAuthorizationError.actionChanged }
        try checkFinal(binding: binding)
    }

    func admitFinal() throws -> UUID {
        guard let expires = lock.withLock({ expires }) else { throw AgentAuthorizationError.invalidDecision }
        let ticket = try configuration.scope.admit(generation: request.policyGeneration, expires: expires)
        lock.withLock { admitted = true }
        return ticket
    }

    func recordAdmission() async throws {
        try await journal.appendAudit([.init(links: links, fact: .disposition(.init(state: .runtimeAdmitted,
            actionDigest: request.actionDigest, localPolicyGeneration: request.policyGeneration)))])
        await configuration.testingHooks?.finalAdmitted?()
    }

    func observeExecutor() { lock.withLock { executorObserved = true } }
    func releaseFinal(_ ticket: UUID) { configuration.scope.releaseAdmission(ticket) }

    func failed(_ error: any Error) async throws {
        let state = lock.withLock { () -> (Bool, Bool, Bool, Bool)? in
            if failureRecorded { return nil }; failureRecorded = true
            return (enterpriseEvaluated, dispatchPrepared, executorObserved, enterpriseStarted)
        }
        guard let state else { return }
        let reason = failureReason(error)
        var drafts: [JournalAuditDraft] = []
        if !state.0 {
            drafts.append(.init(links: links, fact: .authorization(.init(layer: .enterprise,
                status: state.3 ? .incomplete : .notEvaluated, reasonCode: reason))))
        }
        if state.2 { drafts.append(.init(links: links, fact: .disposition(.init(state: .executorObserved)))) }
        let unknown = request.toolPolicy.effect == .mutation && state.1 && replaySource == nil
        let disposition: AuditExecutionDisposition.State = unknown ? .uncertain : state.2 ? .interrupted : .notExecuted
        drafts.append(.init(links: links, fact: .disposition(.init(state: disposition,
            reasonCode: reason))))
        try await journal.appendAudit(drafts)
    }

    var invocationID: UUID { links.invocationID }

    func resultDrafts(_ result: ToolResult<JSONValue>) async throws -> [JournalAuditDraft] {
        let source = lock.withLock { replaySource }
        let kind: AuditResultReference.Kind = result.confirmedNoEffect != nil ? .noEffectConfirmation : result.isIdempotentReplay ? .replay : request.toolPolicy.effect == .mutation ? .settlement : .readOnlyOutput
        let reference = AuditResultReference(kind: kind, sourceSessionID: source?.sessionID ?? links.sessionID,
            sourceRunID: source?.runID ?? links.runID, sourceModelCallID: source?.intent.call.id.rawValue ?? links.modelCallID,
            receipt: result.receipt, outputDigest: try await journal.auditDigest(AuditEncoding.encode(result.output)),
            settlementSource: kind == .settlement || kind == .noEffectConfirmation ? .executor : nil)
        var drafts: [JournalAuditDraft] = []
        if lock.withLock({ executorObserved }) { drafts.append(.init(links: links, fact: .disposition(.init(state: .executorObserved)))) }
        drafts.append(.init(links: links, fact: .result(reference)))
        return drafts
    }

    private func failureReason(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        return lock.withLock {
            if executorObserved { return "executor_failed" }
            switch failureOrigin {
            case .runtimeEvidence: return "runtime_evidence_rejected"
            case .toolAuthorization: return "tool_authorization_failed"
            case .toolDenied: return "tool_denied"
            case nil: return Self.reason(error, enterprise: enterprisePhase)
            }
        }
    }

    static func reason(_ error: any Error, enterprise: Bool = false) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? AgentAuthorizationError {
            switch error {
            case .authorizationDenied: return enterprise ? "host_denied" : "authorization_invalid"
            case .requiresUserAction: return enterprise ? "user_action_required" : "authorization_invalid"
            case .authorizerTimedOut: return enterprise ? "authorizer_timeout" : "authorization_invalid"
            case .authorizerFailed: return enterprise ? "authorizer_error" : "authorization_invalid"
            case .actionChanged: return "action_changed"
            case .expired: return "expired"
            case .revoked: return "revoked"
            default: return "authorization_invalid"
            }
        }
        return "runtime_failed"
    }
}
