import AgentCore
import AgentJournalFileStore
import Foundation
import Testing
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct RunRecordProcessTests {
    @Test(arguments: ["run-record-start-crash", "run-record-checkpoint-crash", "run-record-terminal-crash"])
    func crashPreservesExactPublishedRunFacts(_ mode: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-crash-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executables = [root.appendingPathComponent(".build/out/Products/Debug/JournalTestProcess"), root.appendingPathComponent(".build/debug/JournalTestProcess")]
        let executable = try #require(executables.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = [mode, directory.path]
        process.standardOutput = output; process.standardError = errors
        let exitObserved = XCTestExpectation(description: "child exited")
        process.terminationHandler = { _ in exitObserved.fulfill() }
        let markerObserved = XCTestExpectation(description: "durable boundary marker")
        let marker = RecordProcessMarker()
        try process.run()
        defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
        // Blocking pipe I/O has its own thread; the test's cooperative task only awaits a bounded expectation.
        Thread { marker.set(output.fileHandleForReading.availableData); markerObserved.fulfill() }.start()
        let observed = await XCTWaiter.fulfillment(of: [markerObserved], timeout: 15)
        _ = kill(process.processIdentifier, SIGKILL)
        #expect(await XCTWaiter.fulfillment(of: [exitObserved], timeout: 15) == .completed)
        #expect(observed == .completed)
        #expect(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
        #expect(marker.value.contains(mode == "run-record-start-crash" ? "ADMITTED-BEFORE-HOST-HANDOFF" : mode == "run-record-checkpoint-crash" ? "FINAL-CHECKPOINT-WRITTEN" : "TERMINAL-ROOT-PUBLISHED"))
        let journal = try AgentIncrementalJournal.open(at: directory)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        let lookup = try await journal.runRecord(sessionID: id, correlationKey: "attempt/1")
        let record: AgentRunRecord
        switch lookup {
        case .admitted(let value) where mode != "run-record-terminal-crash": record = value
        case .terminal(let value, .completed) where mode == "run-record-terminal-crash": record = value
        default: Issue.record("admission/terminal state wrong after crash"); return
        }
        #expect(try await journal.runRecord(sessionID: id, runID: record.runID) == lookup)
        let messages = try await journal.readMessages(sessionID: id)
        #expect(messages.first?.id == record.formalMessageID)
        #expect(messages.first?.message == .user([.text("exact process input")]))
        #expect(messages.count == (mode == "run-record-start-crash" ? 1 : 2))
        #expect(try await journal.pendingMutations().isEmpty)
        _ = try await journal.requestMaintenance()
        #expect(try await journal.runRecord(sessionID: id, correlationKey: "attempt/1") == lookup)
        try await journal.close()
    }
}

private final class RecordProcessMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    var value: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
