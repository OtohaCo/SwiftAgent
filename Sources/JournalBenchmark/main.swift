import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main struct JournalBenchmark {
    static func main() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "measure" {
            let values = try await reopen(URL(fileURLWithPath: CommandLine.arguments[3]),
                                          sessionID: UUID(uuidString: CommandLine.arguments[2])!)
            print(String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self))
            return
        }
        guard CommandLine.arguments.count >= 4,
              let count = Int(CommandLine.arguments[2]), count > 0 else {
            FileHandle.standardError.write(Data("Usage: JournalBenchmark repeated|growing|unrelated COUNT DIRECTORY [seed]\n".utf8))
            exit(64)
        }
        let scenario = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let seed = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "20260927"
        let policyName = CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : "default"
        let policy: JournalMaintenancePolicy
        switch policyName {
        case "default": policy = .default
        case "small": policy = try JournalMaintenancePolicy(segmentBytes: 64 * 1024,
                                                              maxWorkBytes: 256 * 1024,
                                                              maxUnreclaimedBytes: 4 * 1024 * 1024)
        default: throw AgentJournalError.invalidRecord
        }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "benchmark-\(seed)", policy: policy)
        let current = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var history: [ModelMessage] = [.user([.text("fixed current state")])]
        var latencies: [Double] = []
        for i in 0..<count {
            let id: UUID
            let runID = UUID()
            switch scenario {
            case "repeated": id = current
            case "growing":
                id = current
                history.append(.assistant(content: [.text("\(seed)-\(i)-" + String(repeating: "x", count: 256))], toolCalls: []))
            case "unrelated":
                id = deterministicUUID(i + 2)
                history = [.user([.text("other session \(i)")])]
            default: throw AgentJournalError.invalidRecord
            }
            let began = DispatchTime.now().uptimeNanoseconds
            _ = try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])],
                                                    sessionID: id, runID: runID, durability: .durable)
            if scenario == "unrelated" {
                let operation = "\(seed)-operation-\(i)"
                let target = EvidenceReference(namespace: "benchmark", id: "resource-\(i)")
                let call = ToolCallID(rawValue: "call-\(i)")
                let arguments = "{\"id\":\(i)}"
                _ = try await journal.admit(.init(sessionID: id, runID: runID, callID: call,
                                                  name: "write", argumentsJSON: arguments,
                                                  resources: [.named(target)], idempotencyKey: operation,
                                                  receiptExpectation: .init(targets: [target], revision: .present)))
                let receipt = ToolReceipt(operationID: operation, status: .succeeded,
                                          confirmedTargets: [target], revision: "done")
                let result = ModelMessage.tool(.init(callID: call, content: [.text("done")], isError: false))
                try await journal.commitMutation(sessionID: id, runID: runID, callID: call,
                                                 receipt: receipt, output: .string("done"),
                                                 history: history + [result], steeringIDs: [])
            }
            latencies.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
        }
        if scenario == "unrelated" {
            _ = try await journal.appendCheckpoint([.checkpoint(history: [.user([.text("fixed current state")])], steeringIDs: [])],
                                                   sessionID: current, runID: UUID(), durability: .durable)
        }
        let steady = await journal.storageMetrics()!
        let maintenanceBegan = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<count {
            guard let status = try await journal.requestMaintenance(), status.sealedSegments > 0 else { break }
        }
        let maintenanceMs = Double(DispatchTime.now().uptimeNanoseconds - maintenanceBegan) / 1_000_000
        let total = await journal.storageMetrics()!
        let status = try await journal.maintenanceStatus()
        var usage = rusage()
        let peakBytes: UInt64
        #if os(Linux)
        let usageResult = getrusage(Int32(RUSAGE_SELF.rawValue), &usage)
        #else
        let usageResult = getrusage(RUSAGE_SELF, &usage)
        #endif
        if usageResult == 0 {
            #if os(Linux)
            peakBytes = UInt64(usage.ru_maxrss) * 1024
            #else
            peakBytes = UInt64(usage.ru_maxrss)
            #endif
        } else { peakBytes = 0 }
        try await journal.close()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["measure", current.uuidString, directory.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let reopened = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AgentJournalError.persistenceUnavailable("child reopen failed") }
        let child = String(decoding: reopened, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        latencies.sort()
        let result: [String: Any] = [
            "scenario": scenario, "count": count, "seed": seed, "policy": policyName,
            "p50CommitMs": latencies[latencies.count / 2],
            "p95CommitMs": latencies[min(latencies.count - 1, latencies.count * 95 / 100)],
            "steadyReadBytes": steady.bytesRead, "steadyDecodedBatches": steady.decodedBatches,
            "steadyWriteBytes": steady.bytesWritten, "totalWriteBytes": total.bytesWritten,
            "maintenanceMs": maintenanceMs, "reclaimedBytes": status?.reclaimedBytes ?? 0,
            "writeLockMs": Double(total.writeLockNanoseconds) / 1_000_000,
            "maintenanceCoreMs": Double(total.maintenanceNanoseconds) / 1_000_000,
            "peakMemoryBytes": peakBytes,
            "child": child,
        ]
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
    }

    private static func deterministicUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }

    private static func reopen(_ url: URL, sessionID: UUID) async throws -> [String: Any] {
        let started = DispatchTime.now().uptimeNanoseconds
        let journal = try AgentIncrementalJournal.open(at: url)
        let openMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let restored = DispatchTime.now().uptimeNanoseconds
        let history = try await journal.latestCheckpoint(sessionID: sessionID)?.history ?? []
        let recoveryMs = Double(DispatchTime.now().uptimeNanoseconds - restored) / 1_000_000
        let metrics = await journal.storageMetrics()!
        try await journal.close()
        return ["openMs": openMs, "recoveryMs": recoveryMs,
                "messages": history.count, "readBytes": metrics.bytesRead,
                "decodedBatches": metrics.decodedBatches]
    }
}
