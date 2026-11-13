import AgentModels
import Foundation

extension AgentJournal {
    /// Gives a Session that has no history in this Journal the earlier part of its conversation, as the Host kept it:
    /// for example after the Host moved the conversation to a new store and the old one is no longer read.
    ///
    /// Only what the user and the model said is taken: user messages of text, and assistant messages of text with no
    /// tool calls, starting with a user message. Tool calls and results, reasoning, provider continuations, images and
    /// files are not; a Host that wants them known says so in words. Nothing is replayed and no Run is admitted: the
    /// seeded messages are history, and the Session's first Run starts after them.
    ///
    /// It is one commit, and only into an empty Session: a Session that already has history (seeded before, or written
    /// by a Run) is refused with `concurrentWriter` and left as it is, so a Host may call it again after a crash.
    public func seedHistory(_ history: [ModelMessage], sessionID: UUID) throws {
        guard case .user? = history.first else { throw AgentJournalError.invalidRecord }
        for message in history {
            switch message {
            case .user(let content), .assistant(let content, toolCalls: []):
                guard !content.isEmpty, content.allSatisfy({ if case .text = $0 { true } else { false } }) else {
                    throw AgentJournalError.invalidRecord
                }
            default:
                throw AgentJournalError.invalidRecord
            }
        }
        try appendCheckpoint(
            [.checkpoint(history: history, steeringIDs: [])],
            sessionID: sessionID,
            runID: nil,
            timestamp: Date(),
            durability: storage == .durable ? .durable : .memory,
            allowMutationSettlement: false,
            expectedHistory: AgentJournalHistoryWitness(head: nil)
        )
    }
}
