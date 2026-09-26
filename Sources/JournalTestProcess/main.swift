import AgentCore
import AgentJournalFileStore
import AgentModels
import Foundation

@main struct JournalTestProcess {
    static func main() async {
        guard CommandLine.arguments.count == 3 else { exit(64) }
        let mode = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        do {
            let journal = try AgentIncrementalJournal.open(at: directory)
            switch mode {
            case "probe":
                try await journal.close()
                exit(0)
            case "hold":
                FileHandle.standardOutput.write(Data("READY\n".utf8))
                while true { try await Task.sleep(for: .seconds(1)) }
            case "commit-and-exit":
                let session = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
                _ = try await journal.appendCheckpoint([
                    .checkpoint(history: [.user([.text("committed before process exit")])], steeringIDs: [])
                ], sessionID: session, runID: UUID(), durability: .durable)
                exit(0)
            default: exit(64)
            }
        } catch AgentJournalError.storeInUse {
            exit(42)
        } catch {
            FileHandle.standardError.write(Data(String(describing: error).utf8))
            exit(1)
        }
    }
}
