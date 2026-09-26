import AgentCore
import AgentJournalFileStore
import Foundation

func makeTestJournal(at url: URL) throws -> AgentJournal {
    if FileManager.default.fileExists(atPath: url.path) {
        return try AgentIncrementalJournal.open(at: url)
    }
    return try AgentIncrementalJournal.create(at: url, operationDomain: "agent-core-tests")
}

func openTestJournal(at url: URL) throws -> AgentJournal {
    try AgentIncrementalJournal.open(at: url)
}
