import AgentModels
import Foundation

extension AgentJournal {
    static func validateConversationControls(_ value: ModelConversationControlState,
                                             previous: ModelConversationControlState?, history: [ModelMessage]) throws {
        let formal = history.dropFirst(history.prefix { $0.role == .system || $0.role == .developer }.count)
        guard previous?.generation != .max, value.generation == (previous?.generation ?? 0) + 1,
              value.lastBoundaryMessageCount <= formal.count,
              value.lastBoundaryMessageCount >= (previous?.lastBoundaryMessageCount ?? 0) else { throw AgentJournalError.invalidRecord }
        if let previous {
            guard value.origin == previous.origin, value.rootConfigurationDigest == previous.rootConfigurationDigest,
                  value.toolBaseline == previous.toolBaseline, value.deferredBaselineToolNames == previous.deferredBaselineToolNames,
                  value.entries.starts(with: previous.entries) else { throw AgentJournalError.invalidRecord }
        }
        var tools = Dictionary(uniqueKeysWithValues: (previous?.activeTools ?? value.toolBaseline.filter { !value.deferredBaselineToolNames.contains($0.name) }).map { ($0.name, $0) })
        var checkedBoundary = previous?.lastBoundaryMessageCount ?? 0
        for entry in value.entries.dropFirst(previous?.entries.count ?? 0) {
            guard entry.canonicalMessageCount >= checkedBoundary,
                  entry.canonicalMessageCount <= value.lastBoundaryMessageCount else { throw AgentJournalError.invalidRecord }
            let boundary = formal.startIndex + entry.canonicalMessageCount - 1
            guard formal[boundary].role == .user || formal[boundary].role == .tool,
                  entry.boundaryDigest == ModelImageDigest.sha256Hex(try AgentConversationControlState.encode(formal[boundary])) else { throw AgentJournalError.invalidRecord }
            if entry.canonicalMessageCount > checkedBoundary {
                try AgentConversationControlState.requireClosed(Array(formal.dropFirst(checkedBoundary).prefix(entry.canonicalMessageCount - checkedBoundary)))
                checkedBoundary = entry.canonicalMessageCount
            }
            switch entry.control {
            case .toolAddition(let tool): tools[tool.name] = tool
            case .toolRemoval(let name): guard tools.removeValue(forKey: name) != nil else { throw AgentJournalError.invalidRecord }
            default: break
            }
        }
        try AgentConversationControlState.requireClosed(Array(formal.dropFirst(checkedBoundary).prefix(value.lastBoundaryMessageCount - checkedBoundary)))
        guard tools.values.sorted(by: { $0.name < $1.name }) == value.activeTools else { throw AgentJournalError.invalidRecord }
    }

    package func publishConversationControls(_ value: ModelConversationControlState, history: [ModelMessage],
                                             sessionID: UUID, runID: UUID, steeringIDs: [UUID],
                                             expectedHistory: AgentJournalHistoryWitness, deadline: ContinuousClock.Instant?) throws {
        _ = try appendCheckpoint([.conversationControlState(value), .checkpoint(history: history, steeringIDs: steeringIDs)],
            sessionID: sessionID, runID: runID, timestamp: Date(), durability: storage == .durable ? .durable : .memory,
            allowMutationSettlement: false, admissionDeadline: deadline, checkAdmissionCancellation: true,
            expectedHistory: expectedHistory, admitsNewWork: false)
    }
}
