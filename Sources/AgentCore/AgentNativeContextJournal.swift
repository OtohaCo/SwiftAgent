import AgentModels
import Foundation

package struct CompletedReminderTurnProof: Sendable {
    let runID: UUID
    let boundary: Int
}

extension AgentJournal {
    /// One store snapshot proves the active reminder belongs to the last completed
    /// Run at the same persistent history head. The Session owns its drained lease.
    package func completedReminderTurn(sessionID: UUID, boundary: Int,
                                       expectedHistory: AgentJournalHistoryWitness) throws -> CompletedReminderTurnProof? {
        guard let store, supportsRunRecords, boundary > 0 else { return nil }
        return try store.read { view in
            guard let header = try view.header(sessionID),
                  AgentJournalHistoryWitness(head: header.historyHead) == expectedHistory,
                  let runID = header.lastRunID else { return nil }
            let proof = CompletedReminderTurnProof(runID: runID, boundary: boundary)
            return try Self.isCompletedReminderTurn(sessionID: sessionID, proof: proof, header: header, view: view) ? proof : nil
        }
    }

    /// Reused inside the publication transaction; metadata writes may not advance historyHead.
    static func isCompletedReminderTurn(sessionID: UUID, proof: CompletedReminderTurnProof, header: JournalSessionHeader,
                                        view: any JournalStoreView) throws -> Bool {
        let boundary = proof.boundary, runID = proof.runID
        guard boundary > 0, header.lastRunID == runID,
              let admission = try view.runRecord(sessionID: sessionID, runID: runID),
              try view.runTerminal(sessionID: sessionID, runID: runID) == .completed,
              header.pendingIdentity == nil, try view.pending(sessionID: sessionID).isEmpty else { return false }
        // Controls count formal messages; the persisted admission ordinal is zero-based.
        return admission.formalMessageOrdinal < UInt64(boundary) && UInt64(boundary) <= header.messageCount
    }
    /// Read-only effective context; canonical latestCheckpoint remains complete.
    public func nativeContextCheckpoint(sessionID: UUID) throws -> ModelNativeContextCheckpoint? {
        if let store { return try store.read { try $0.header(sessionID)?.nativeContext } }
        return memoryNativeContext(sessionID: sessionID)
    }

    package func publishNativeContext(_ checkpoint: ModelNativeContextCheckpoint,
                                     history: [ModelMessage], sessionID: UUID, runID: UUID?,
                                     expectedHistory: AgentJournalHistoryWitness, steeringIDs: [UUID] = [],
                                     deadline: ContinuousClock.Instant? = nil, completedReminderProof: CompletedReminderTurnProof? = nil) throws {
        guard supportsNativeContext else { throw AgentJournalError.unsupportedFormat }
        // No synthetic assistant response. Both view and history witness publish atomically.
        _ = try appendCheckpoint([.nativeContextCheckpoint(checkpoint), .checkpoint(history: history, steeringIDs: steeringIDs)],
                                 sessionID: sessionID, runID: runID, timestamp: Date(),
                                 durability: storage == .durable ? .durable : .memory,
                                 allowMutationSettlement: false, admissionDeadline: deadline, checkAdmissionCancellation: deadline != nil,
                                 expectedHistory: expectedHistory, admitsNewWork: false, completedReminderProof: completedReminderProof)
    }

    static func validateNativeContext(_ value: ModelNativeContextCheckpoint,
                                      previous: ModelNativeContextCheckpoint?, sessionID: UUID,
                                      messageCount: UInt64, publishedMessageCount: UInt64, view: any JournalStoreView) throws {
        try validateNativeContextShape(value, previous: previous, sessionID: sessionID, messageCount: messageCount, publishedMessageCount: publishedMessageCount)
        let source = value.transition.source
        let last = try view.messages(sessionID: sessionID, after: UInt64(source.canonicalMessageCount - 1), limit: 1)
        guard last.count == 1, last[0].id == source.lastMessageID else { throw AgentJournalError.concurrentWriter }
    }

    static func validateNativeContextShape(_ value: ModelNativeContextCheckpoint,
                                          previous: ModelNativeContextCheckpoint?, sessionID: UUID,
                                          messageCount: UInt64, publishedMessageCount: UInt64) throws {
        let source = value.transition.source
        if let lineage = value.preservedThinkingLineage {
            guard value.transition.mode == .anthropicOnDemand, lineage.parentCheckpointID == previous?.id,
                  lineage.boundary.source.sessionID == sessionID,
                  lineage.boundary.source.canonicalMessageCount == value.canonicalTailStart,
                  value.canonicalTailStart == source.canonicalMessageCount,
                  lineage.boundary.rootConfigurationDigest == value.rootConfigurationDigest,
                  lineage.tailMessageCount > 0, value.canonicalTailStart >= 0,
                  UInt64(value.canonicalTailStart) <= publishedMessageCount,
                  UInt64(lineage.tailMessageCount) <= publishedMessageCount - UInt64(value.canonicalTailStart),
                  !lineage.tailDigest.isEmpty, !lineage.boundary.witness.prefixDigest.isEmpty,
                  !lineage.boundary.witness.rootToolsDigest.isEmpty, !lineage.boundary.witness.qualificationScope.isEmpty,
                  lineage.replacements.count <= 10_000,
                  lineage.replacements.allSatisfy({ !$0.originalDigest.isEmpty && !$0.replacementDigest.isEmpty && !$0.continuationPayloadDigest.isEmpty }) else {
                throw AgentJournalError.invalidRecord
            }
        }
        guard source.sessionID == sessionID, source.canonicalMessageCount > 0,
              UInt64(source.canonicalMessageCount) <= messageCount,
              value.canonicalTailStart >= source.canonicalMessageCount,
              UInt64(value.canonicalTailStart) <= publishedMessageCount,
              value.transition.replayPosition >= 0, !value.transition.responseID.isEmpty,
              !source.canonicalDigest.isEmpty, !source.requestDigest.isEmpty,
              !value.rootConfigurationDigest.isEmpty,
              value.continuation.contextTransition == value.transition,
              value.generation > 0, previous?.generation != .max,
              value.generation == (previous?.generation ?? 0) + 1,
              source.previousCheckpointID == previous?.id else { throw AgentJournalError.invalidRecord }
    }
}
