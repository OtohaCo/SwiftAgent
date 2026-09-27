import AgentCore
import AgentModels
import AgentTools
import Foundation

@main struct LegacyJournalBenchmark {
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "measure" {
            let start = DispatchTime.now().uptimeNanoseconds
            let journal = try AgentJournal(persistenceURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            let openMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let restored = DispatchTime.now().uptimeNanoseconds
            let session = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let history = await journal.latestCheckpoint(sessionID: session)?.history ?? []
            let recoveryMs = Double(DispatchTime.now().uptimeNanoseconds - restored) / 1_000_000
            print("{\"openMs\":\(openMs),\"recoveryMs\":\(recoveryMs),\"messages\":\(history.count),\"records\":\(await journal.snapshot().count)}")
            return
        }
        guard CommandLine.arguments.count == 5,
              let count = Int(CommandLine.arguments[2]) else { exit(64) }
        let scenario = CommandLine.arguments[1]
        let file = URL(fileURLWithPath: CommandLine.arguments[3])
        let seed = CommandLine.arguments[4]
        let journal = try AgentJournal(persistenceURL: file)
        let current = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var history: [ModelMessage] = [.user([.text("fixed current state")])]
        var timings: [Double] = []
        for i in 0..<count {
            let session: UUID
            switch scenario {
            case "repeated": session = current
            case "growing":
                session = current
                history.append(.assistant(content: [.text("\(seed)-\(i)-" + String(repeating: "x", count: 256))], toolCalls: []))
            case "unrelated":
                session = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", i + 2))!
                history = [.user([.text("other session \(i)")])]
            default: exit(64)
            }
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])],
                                                    sessionID: session, runID: UUID(), durability: .durable)
            if scenario == "unrelated" {
                let operation = "\(seed)-operation-\(i)"
                let target = EvidenceReference(namespace: "benchmark", id: "resource-\(i)")
                let call = ToolCallID(rawValue: "call-\(i)")
                let run = UUID(), arguments = "{\"id\":\(i)}"
                _ = try await journal.admit(.init(sessionID: session, runID: run, callID: call,
                                                  name: "write", argumentsJSON: arguments,
                                                  resources: [.named(target)], idempotencyKey: operation,
                                                  receiptExpectation: .init(targets: [target], revision: .present)))
                try await journal.commitMutation(sessionID: session, runID: run, callID: call,
                    receipt: .init(operationID: operation, status: .succeeded,
                                   confirmedTargets: [target], revision: "done"),
                    output: .string("done"), history: history + [
                        .tool(.init(callID: call, content: [.text("done")], isError: false))
                    ], steeringIDs: [])
            }
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        if scenario == "unrelated" {
            _ = try await journal.appendCheckpoint([.checkpoint(history: [.user([.text("fixed current state")])], steeringIDs: [])],
                                                   sessionID: current, runID: UUID(), durability: .durable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["measure", file.path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let child = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { exit(1) }
        timings.sort()
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        let json: [String: Any] = ["scenario": scenario, "count": count, "seed": seed,
                                   "p50CommitMs": timings[count / 2],
                                   "p95CommitMs": timings[min(count - 1, count * 95 / 100)],
                                   "fileBytes": size?.uint64Value ?? 0, "child": child]
        print(String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self))
    }
}
