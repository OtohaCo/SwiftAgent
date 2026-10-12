import AgentModels
import Foundation

extension AgentJournal {
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
