import Testing
import Foundation
import AgentCore
@testable import AgentJournalFileStore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite(.serialized) struct JournalWriterLockWaitTests {
    @Test func explicitWaitExpiresWhileRealIndependentWriterKeepsOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lock-wait-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentIncrementalJournal.create(at: directory, operationDomain: "lock-wait")
        try await store.close()
        let writer = try LockWriter(directory: directory)
        defer { writer.stop() }
        #expect(throws: AgentJournalError.storeInUse) { try AgentIncrementalJournal.open(at: directory) }
        await #expect(throws: AgentJournalError.deadlineExceeded) {
            try await AgentIncrementalJournal.openAsync(at: directory, writerLockWait: .until(.now.advanced(by: .seconds(1))))
        }
        #expect(try ChildRun.probe(directory).status == 42)
        writer.stop()
        #expect(try ChildRun.probe(directory).status == 0)
    }
    @Test func controlledPreExecWindowAndExecReleaseUseActualJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fork-window-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentIncrementalJournal.create(at: directory, operationDomain: "fork-window")
        try await store.close()
        let process = Process()
        process.executableURL = try ChildRun.journalTestProcess()
        process.arguments = ["fork-window", directory.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        defer { if process.isRunning { input.fileHandleForWriting.closeFile(); process.waitUntilExit() } }
        let ready = try line(output.fileHandleForReading)
        #expect(ready.hasPrefix("WINDOW "))
        let pid = try #require(Int32(ready.dropFirst(7)))
        #expect(try ChildRun.probe(directory).status == 42)
        #expect(LockDescriptors.held(by: pid, store: directory) != .notHeld)
        input.fileHandleForWriting.write(Data([1]))
        #expect(try line(output.fileHandleForReading) == "EXECUTED")
        #expect(kill(pid, 0) == 0)
        #expect(try ChildRun.probe(directory).status == 0)
        #expect(LockDescriptors.held(by: pid, store: directory) != .held)
        input.fileHandleForWriting.write(Data([1]))
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        print("writer-lock-window platform=\(WriterLockLifetimeTests.platform) preExec=contended postExec=independentReopen childAlive=true")
    }

    @Test func waitSuccessAndCancellationUseContendedBarrier() async throws {
        for cancel in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lock-barrier-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let initial = try AgentIncrementalJournal.create(at: directory, operationDomain: "barrier")
            try await initial.close()
            let writer = try LockWriter(directory: directory)
            defer { writer.stop() }
            let observer = OpeningObserver()
            let task = Task { try await AgentIncrementalJournal.openAsyncForTesting(at: directory,
                writerLockWait: .until(.now.advanced(by: .seconds(30))), observer: observer.observe) }
            await observer.waitForContention()
            #expect(observer.acquisitions == 0)
            #expect(try ChildRun.probe(directory).status == 42)
            if cancel {
                task.cancel()
                await #expect(throws: CancellationError.self) { try await task.value }
                #expect(try ChildRun.probe(directory).status == 42)
                writer.stop()
            } else {
                writer.stop()
                let opened = try await task.value
                #expect(observer.acquisitions == 1)
                #expect(observer.formatReads == 1)
                #expect(try ChildRun.probe(directory).status == 42)
                try await opened.close()
            }
            #expect(try ChildRun.probe(directory).status == 0)
        }
    }

    @Test func cancellationAtAcquisitionWaitsForActualIOAndReleasesOwnDescriptor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acquire-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try AgentIncrementalJournal.create(at: directory, operationDomain: "race")
        try await initial.close()
        let observer = OpeningObserver(blockAcquired: true)
        let task = Task { try await AgentIncrementalJournal.openAsyncForTesting(at: directory,
            writerLockWait: .until(.now.advanced(by: .seconds(30))), observer: observer.observe) }
        await observer.waitForAcquisition()
        #expect(try ChildRun.probe(directory).status == 42)
        task.cancel()
        observer.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try ChildRun.probe(directory).status == 0)
    }

    @Test func malformedFormatAndOriginalDeadlineAreNotRetried() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lock-bad-format-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try AgentIncrementalJournal.create(at: directory, operationDomain: "invalid")
        try await initial.close()
        let original = try Data(contentsOf: directory.appendingPathComponent("format.json"))
        try Data("bad format".utf8).write(to: directory.appendingPathComponent("format.json"))
        let observer = OpeningObserver()
        await #expect(throws: AgentJournalError.invalidHeader) {
            try await AgentIncrementalJournal.openAsyncForTesting(at: directory,
                writerLockWait: .until(.now.advanced(by: .seconds(30))), observer: observer.observe)
        }
        #expect(observer.formatReads == 0 && observer.acquisitions == 0)
        try original.write(to: directory.appendingPathComponent("format.json"))
        let writer = try LockWriter(directory: directory)
        defer { writer.stop() }
        await #expect(throws: AgentJournalError.deadlineExceeded) {
            try await AgentIncrementalJournal.openAsync(at: directory,
                writerLockWait: .until(.now.advanced(by: .seconds(30))), deadline: .now.advanced(by: .seconds(1)))
        }
        #expect(try ChildRun.probe(directory).status == 42)
    }

    private func line(_ handle: FileHandle) throws -> String {
        var bytes = Data()
        while let part = try handle.read(upToCount: 1), !part.isEmpty {
            if part == Data([10]) { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(part)
            guard bytes.count <= 128 else { throw AgentJournalError.invalidRecord }
        }
        throw AgentJournalError.invalidRecord
    }

}

private final class LockWriter {
    let child: Process
    private let exited = DispatchSemaphore(value: 0)
    private var stopped = false
    init(directory: URL) throws {
        child = Process()
        child.executableURL = try ChildRun.journalTestProcess()
        child.arguments = ["hold", directory.path]
        child.standardOutput = Pipe()
        child.standardError = Pipe()
        let exited = self.exited
        child.terminationHandler = { _ in exited.signal() }
        try child.run()
        let pipe = child.standardOutput as! Pipe
        guard pipe.fileHandleForReading.readData(ofLength: 6) == Data("READY\n".utf8) else { throw AgentJournalError.invalidRecord }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        #expect(exited.wait(timeout: .now() + 10) == .success, "Foundation owner must report actual child exit")
    }
}

private final class OpeningObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0, acquiredCount = 0
    private let (contended, contentionSignal) = AsyncStream<Void>.makeStream()
    private let (acquired, acquisitionSignal) = AsyncStream<Void>.makeStream()
    private let hold = DispatchSemaphore(value: 0)
    private let blockAcquired: Bool
    init(blockAcquired: Bool = false) { self.blockAcquired = blockAcquired }
    var acquisitions: Int { lock.withLock { acquiredCount } }
    var formatReads: Int { lock.withLock { readCount } }
    @Sendable func observe(_ stage: JournalOpeningStage) {
        switch stage {
        case .formatValidated: lock.withLock { readCount += 1 }
        case .lockContended: contentionSignal.yield()
        case .lockAcquired:
            lock.withLock { acquiredCount += 1 }
            acquisitionSignal.yield()
            if blockAcquired { hold.wait() }
        }
    }
    func waitForContention() async { for await _ in contended { return } }
    func waitForAcquisition() async { for await _ in acquired { return } }
    func release() { hold.signal() }
}
