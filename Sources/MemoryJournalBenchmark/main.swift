import AgentCore
import AgentModels
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func residentBytes() -> UInt64 {
    #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
    #else
    guard let stat = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
          let pages = UInt64(stat.split(separator: " ").dropFirst().first ?? "") else { return 0 }
    return pages * UInt64(sysconf(Int32(_SC_PAGESIZE)))
    #endif
}

private enum BenchmarkError: Error { case invalidCount }

@main struct MemoryJournalBenchmark {
    static func main() async throws {
        let count = Int(CommandLine.arguments.dropFirst().first ?? "1000") ?? 1000
        guard (1...10_000).contains(count) else { throw BenchmarkError.invalidCount }
        let journal = AgentJournal(), sessionID = UUID()
        let before = residentBytes(), start = ContinuousClock.now
        var history: [ModelMessage] = []
        let body = String(repeating: "h", count: 1_000)
        for index in 0..<count {
            history.append(.user([.text("m\(index) " + body)]))
            _ = try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])],
                sessionID: sessionID, runID: UUID(), durability: .memory)
        }
        let retained = await journal.memoryRetentionStatistics()
        let after = residentBytes()
        let row: [String: Any] = ["checkpoints": count, "checkpointArrays": retained.checkpointArrays,
            "messageSlots": retained.messageSlots, "otherRecords": retained.otherRecords,
            "sessionStates": retained.sessionStates, "runIdentities": retained.runIdentities,
            "rssBeforeBytes": before, "rssAfterBytes": after,
            "rssDeltaBytes": Int64(after) - Int64(before), "elapsed": String(describing: start.duration(to: .now)),
            "note": "Real AgentJournal, 1KB bodies; COW snapshots share message content; slots/arrays are structural counts, RSS is environment-dependent"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        _ = try await journal.latestCheckpoint(sessionID: sessionID)
    }
}
