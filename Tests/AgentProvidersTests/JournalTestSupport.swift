import AgentCore
import AgentJournalFileStore
import Foundation

func makeTestJournal(at url: URL) throws -> AgentJournal {
    try AgentIncrementalJournal.create(at: url, operationDomain: "provider-tests")
}

func openTestJournal(at url: URL) throws -> AgentJournal {
    try AgentIncrementalJournal.open(at: url)
}
