import AgentModels
import AgentTools
import Foundation

extension AgentJournal {
    /// Current persisted control authority, without consulting a Session cache.
    /// This advisory snapshot certifies neither physical drain nor handoff eligibility.
    public func conversationControlState(sessionID: UUID) throws -> ModelConversationControlState? {
        if let store { return try store.read { try $0.header(sessionID)?.conversationControls } }
        return try historySnapshot(sessionID: sessionID).conversationControls
    }

    package func closedHandoffTurn(sessionID: UUID, expectedHistory: AgentJournalHistoryWitness) throws -> AgentContextHandoffTurnProof {
        guard supportsIncompleteContextHandoff, let store else { throw AgentJournalError.unsupportedFormat }
        return try store.read { view in
            guard let header = try view.header(sessionID), header.historyHead == expectedHistory.head,
                  let head = header.historyHead, let runID = header.lastRunID,
                  let admission = try view.runRecord(sessionID: sessionID, runID: runID),
                  let terminal = try view.runTerminal(sessionID: sessionID, runID: runID) else {
                throw ModelProviderError(kind: .unsupportedCapability, message: "Incomplete handoff requires a persisted admission and terminal at the current history boundary.")
            }
            let proof = AgentContextHandoffTurnProof(storeID: store.storeID, sessionID: sessionID, runID: runID, terminal: terminal,
                formalMessageID: admission.record.formalMessageID, formalMessageOrdinal: admission.formalMessageOrdinal, historyHead: head)
            guard try Self.isClosedHandoffTurn(proof, sessionID: sessionID, header: header, view: view) else {
                throw AgentJournalError.mutationRequiresReconciliation
            }
            return proof
        }
    }

    static func isClosedHandoffTurn(_ proof: AgentContextHandoffTurnProof, sessionID: UUID,
                                    header: JournalSessionHeader, view: any JournalStoreView) throws -> Bool {
        guard proof.sessionID == sessionID, header.historyHead == proof.historyHead, header.lastRunID == proof.runID,
              let admission = try view.runRecord(sessionID: sessionID, runID: proof.runID),
              admission.record.storeID == proof.storeID, admission.record.sessionID == sessionID,
              admission.record.formalMessageID == proof.formalMessageID,
              admission.formalMessageOrdinal == proof.formalMessageOrdinal,
              proof.formalMessageOrdinal < header.messageCount,
              try view.runTerminal(sessionID: sessionID, runID: proof.runID) == proof.terminal,
              header.pendingIdentity == nil, try view.pending(sessionID: sessionID).isEmpty else { return false }
        let user = try view.messages(sessionID: sessionID, after: proof.formalMessageOrdinal, limit: 1)
        return user.count == 1 && user[0].id == proof.formalMessageID && user[0].value.role == .user
    }

    static func handoffRegistryDigest(_ registry: ToolRegistry) throws -> String {
        struct Baseline: Encodable { let tools: [ModelToolDefinition]; let declared: [String]; let policies: [String: ToolPolicy] }
        return ModelImageDigest.sha256Hex(try AgentConversationControlState.encode(
            Baseline(tools: registry.definitions, declared: registry.initiallyDeclaredNames.sorted(), policies: registry.policyDefinitions)))
    }

    package func validateStoredHandoff(_ value: AgentContextHandoff, sessionID: UUID) throws {
        guard let proof = value.closedTurnProof else { return }
        guard supportsIncompleteContextHandoff, let store, proof.storeID == store.storeID, proof.sessionID == sessionID else {
            throw AgentJournalError.invalidRecord
        }
        try store.read { view in
            guard let admission = try view.runRecord(sessionID: sessionID, runID: proof.runID),
                  admission.record.formalMessageID == proof.formalMessageID, admission.formalMessageOrdinal == proof.formalMessageOrdinal,
                  try view.runTerminal(sessionID: sessionID, runID: proof.runID) == proof.terminal else { throw AgentJournalError.invalidRecord }
            let user = try view.messages(sessionID: sessionID, after: proof.formalMessageOrdinal, limit: 1)
            guard user.count == 1, user[0].id == proof.formalMessageID, user[0].value.role == .user else { throw AgentJournalError.invalidRecord }
        }
    }

    /// Latest authority retirement. Older canonical checkpoints and evidence
    /// remain archival facts; this value only governs subsequent request views.
    public func contextHandoff(sessionID: UUID) throws -> AgentContextHandoff? {
        try historySnapshot(sessionID: sessionID).contextHandoff
    }

    package func publishContextHandoff(_ value: AgentContextHandoff, history: [ModelMessage], sessionID: UUID,
                                       expectedHistory: AgentJournalHistoryWitness, steeringIDs: [UUID], deadline: ContinuousClock.Instant) throws {
        guard supportsContextHandoff else { throw AgentJournalError.unsupportedFormat }
        _ = try appendCheckpoint([.contextHandoff(value), .checkpoint(history: history, steeringIDs: steeringIDs)],
            sessionID: sessionID, runID: nil, timestamp: Date(), durability: storage == .durable ? .durable : .memory,
            allowMutationSettlement: false, admissionDeadline: deadline, checkAdmissionCancellation: true,
            expectedHistory: expectedHistory, admitsNewWork: false)
    }

    static func controlsDigest(_ value: ModelConversationControlState?) throws -> String {
        ModelImageDigest.sha256Hex(try AgentConversationControlState.encode(value))
    }

    static func validateHandoff(_ value: AgentContextHandoff, previous: AgentContextHandoff?, native: ModelNativeContextCheckpoint?,
                                controls: ModelConversationControlState?, messageCount: Int) throws {
        guard previous?.generation != .max, value.generation == (previous?.generation ?? 0) + 1,
              value.previousHandoffID == previous?.id, value.canonicalMessageCount == messageCount,
              value.retiredNativeCheckpointID == native?.id,
              value.retiredControlsDigest == (try controlsDigest(controls)),
              controls?.entries.contains(where: { if case .instruction = $0.control { true } else { false } }) != true else {
            throw AgentJournalError.concurrentWriter
        }
    }
}
