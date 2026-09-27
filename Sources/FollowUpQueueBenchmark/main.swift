import AgentCore
import AgentJournalFileStore
import AgentModels
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main struct FollowUpQueueBenchmark {
    static func main() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "measure" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[3])
            let id = UUID(uuidString: CommandLine.arguments[2])!
            let start = ContinuousClock.now
            let journal = try AgentIncrementalJournal.open(at: directory)
            let records = try await journal.followUps(sessionID: id, after: nil, limit: 1)
            let elapsed = milliseconds(start.duration(to: .now))
            guard let counters = await journal.storageMetrics() else { throw AgentFollowUpError.durableJournalRequired }
            try await journal.close()
            print(json(["openAndPageMs": elapsed, "pageCount": records.count,
                        "readBytes": counters.bytesRead, "decodedBatches": counters.decodedBatches]))
            return
        }
        guard CommandLine.arguments.count == 5,
              let count = Int(CommandLine.arguments[2]), count > 0, count <= 1000 else {
            FileHandle.standardError.write(Data("Usage: FollowUpQueueBenchmark target|unrelated|active COUNT DIRECTORY SEED\n".utf8))
            exit(64)
        }
        let scenario = CommandLine.arguments[1]
        guard ["target", "unrelated", "active"].contains(scenario) else { exit(64) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let seed = CommandLine.arguments[4]
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "queue-bench-\(seed)")
        let targetID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let model = ModelID(provider: "queue-bench", name: "fixed")
        let provider = BenchmarkProvider()
        let agent = try Agent(model: model, provider: provider)
        let target = try agent.makeSession(id: targetID, journal: journal)
        for i in 0..<count {
            let id = scenario == "unrelated" ? otherSessionID(i) : targetID
            let session = id == targetID ? target : try agent.makeSession(id: id, journal: journal)
            let input = AgentFollowUpInput(inputID: "seed-\(seed)-\(i)", text: "x",
                                           operationID: "op-\(seed)-\(i)", configurationRef: "v1")
            _ = try await session.enqueueFollowUp(input)
            _ = try await session.withdrawFollowUp(inputID: input.inputID)
        }
        let active: AgentRun?
        if scenario == "active" {
            active = try await target.run("hold")
            await provider.waitUntilHeld()
        } else { active = nil }

        guard let before = await journal.storageMetrics() else { throw AgentFollowUpError.durableJournalRequired }
        var times: [Double] = []
        for i in 0..<20 {
            let input = AgentFollowUpInput(inputID: "sample-\(seed)-\(i)", text: "small delta",
                                           operationID: "sample-op-\(seed)-\(i)", configurationRef: "v1")
            let start = ContinuousClock.now
            _ = try await target.enqueueFollowUp(input)
            times.append(milliseconds(start.duration(to: .now)))
            _ = try await target.withdrawFollowUp(inputID: input.inputID)
        }
        guard let after = await journal.storageMetrics() else { throw AgentFollowUpError.durableJournalRequired }
        if let active {
            await provider.release()
            _ = try await active.wait()
            try await active.waitForDrain()
        }
        let maintenanceStart = ContinuousClock.now
        for _ in 0..<100 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        let maintenanceMs = milliseconds(maintenanceStart.duration(to: .now))
        let reclaimed = try await journal.maintenanceStatus()?.reclaimedBytes ?? 0
        guard let metrics = await journal.storageMetrics() else { throw AgentFollowUpError.durableJournalRequired }
        try await journal.close()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["measure", targetID.uuidString, directory.path]
        let pipe = Pipe(); child.standardOutput = pipe
        try child.run()
        let recovered = pipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        guard child.terminationStatus == 0 else { throw AgentJournalError.persistenceUnavailable("benchmark child failed") }
        times.sort()
        print(json(["scenario": scenario, "seed": seed, "growthCount": count,
                    "p50EnqueueMs": times[times.count / 2],
                    "p95EnqueueMs": times[min(times.count - 1, times.count * 95 / 100)],
                    "smallCommitReadBytes": after.bytesRead - before.bytesRead,
                    "smallCommitDecodedBatches": after.decodedBatches - before.decodedBatches,
                    "smallCommitWriteBytes": after.bytesWritten - before.bytesWritten,
                    "maintenanceMs": maintenanceMs, "reclaimedBytes": reclaimed,
                    "writeLockMs": Double(metrics.writeLockNanoseconds) / 1_000_000,
                    "peakResidentBytes": peakResidentBytes(),
                    "newProcess": String(decoding: recovered, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)]))
    }

    private static func otherSessionID(_ i: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", i + 2))!
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
    private static func json(_ fields: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }
    private static func peakResidentBytes() -> UInt64 {
        var usage = rusage()
        #if os(Linux)
        let status = getrusage(Int32(RUSAGE_SELF.rawValue), &usage)
        return status == 0 ? UInt64(usage.ru_maxrss) * 1024 : 0
        #else
        let status = getrusage(RUSAGE_SELF, &usage)
        return status == 0 ? UInt64(usage.ru_maxrss) : 0
        #endif
    }
}

private actor BenchmarkGate {
    private var held = false, released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        held = true
        let current = observers; observers.removeAll(); current.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        released = true
        let current = waiters; waiters.removeAll(); current.forEach { $0.resume() }
    }
}

private struct BenchmarkProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "queue-bench", capabilities: [.streaming, .multiTurn])
    private let gate = BenchmarkGate()
    func waitUntilHeld() async { await gate.waitUntilHeld() }
    func release() async { await gate.release() }
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await gate.wait()
            let info = ResponseInfo(id: "bench", model: request.model)
            try emit(.responseStarted(info))
            try emit(.textDelta("done"))
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
        }
    }
}
