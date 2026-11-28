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
        let window = try ForkWindowProcess(directory: directory)
        defer { window.cleanupIfStillRunning() }
        let ready = try window.readLine()
        #expect(ready.hasPrefix("WINDOW "))
        let pid = try #require(Int32(ready.dropFirst(7)))
        #expect(try ChildRun.probe(directory).status == 42)
        #expect(LockDescriptors.held(by: pid, store: directory) != .notHeld)
        try window.signalExec()
        #expect(try window.readLine() == "EXECUTED")
        #expect(kill(pid, 0) == 0)
        #expect(try ChildRun.probe(directory).status == 0)
        #expect(LockDescriptors.held(by: pid, store: directory) != .held)
        let exit = await window.finishAndWaitForExit()
        #expect(!exit.timedOut)
        #expect(exit.reason == .exit)
        #expect(exit.status == 0)
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

    /// A holder that lets go while a fail-fast open is contending (as a child that is
    /// still starting does) does not make the open report another writer.
    @Test func failFastOpenRidesOutAHolderThatReleasesAtContention() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lock-brief-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try AgentIncrementalJournal.create(at: directory, operationDomain: "brief")
        try await initial.close()
        let holder = BriefHolder(try JournalWriterLock(file: directory.appendingPathComponent(".writer.lock")))
        let observer = OpeningObserver(onContention: { holder.release() })
        let opened = try await AgentIncrementalJournal.openAsyncForTesting(at: directory,
            writerLockWait: .failFast, observer: observer.observe)
        #expect(observer.contentions >= 1)
        #expect(observer.acquisitions == 1)
        #expect(try ChildRun.probe(directory).status == 42)
        try await opened.close()
        #expect(try ChildRun.probe(directory).status == 0)
    }

    /// A holder that keeps the lock is still reported promptly as another writer.
    @Test func failFastOpenStillRefusesAHolderThatKeepsTheLock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lock-kept-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try AgentIncrementalJournal.create(at: directory, operationDomain: "kept")
        try await initial.close()
        let holder = try JournalWriterLock(file: directory.appendingPathComponent(".writer.lock"))
        defer { try? holder.close() }
        let observer = OpeningObserver()
        let started = ContinuousClock.now
        await #expect(throws: AgentJournalError.storeInUse) {
            try await AgentIncrementalJournal.openAsyncForTesting(at: directory,
                writerLockWait: .failFast, observer: observer.observe)
        }
        #expect(observer.contentions >= 1 && observer.acquisitions == 0)
        #expect(started.duration(to: .now) < .seconds(5))
    }

    /// The real cause: a forked child that has not yet exec'd shares the lock description.
    /// An in-process fail-fast open that starts inside that window succeeds once it execs.
    @Test func failFastOpenRidesOutARealPreExecWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fork-brief-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentIncrementalJournal.create(at: directory, operationDomain: "fork-window")
        try await store.close()
        let window = try ForkWindowProcess(directory: directory)
        defer { window.cleanupIfStillRunning() }
        #expect(try window.readLine().hasPrefix("WINDOW "))
        let observer = OpeningObserver(onContention: {
            do {
                try window.signalExec()
            } catch {
                Issue.record("Failed to signal fork-window helper to exec: \(error)")
            }
        })
        let opened = try await AgentIncrementalJournal.openAsyncForTesting(at: directory,
            writerLockWait: .failFast, observer: observer.observe)
        #expect(observer.contentions >= 1)
        #expect(try window.readLine() == "EXECUTED")
        try await opened.close()
        let exit = await window.finishAndWaitForExit()
        #expect(!exit.timedOut)
        #expect(exit.reason == .exit)
        #expect(exit.status == 0)
    }
}

/// Manages a `JournalTestProcess fork-window` helper using `terminationHandler` rather than
/// `Process.waitUntilExit()`, awaiting exit asynchronously with a bounded timeout and providing
/// bounded synchronous cleanup if a test exits early.
private final class ForkWindowProcess: @unchecked Sendable {
    struct ExitResult: Sendable {
        let status: Int32
        let reason: Process.TerminationReason
        let timedOut: Bool
    }

    private final class ExitState: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var info: (status: Int32, reason: Process.TerminationReason)?
        private var waiters: [UUID: CheckedContinuation<(status: Int32, reason: Process.TerminationReason)?, Never>] = [:]
        private var expiredTokens: Set<UUID> = []

        var hasExited: Bool { lock.withLock { info != nil } }

        func recordExit(status: Int32, reason: Process.TerminationReason) {
            let value = (status: status, reason: reason)
            let pending = lock.withLock { () -> [CheckedContinuation<(status: Int32, reason: Process.TerminationReason)?, Never>] in
                if info == nil { info = value }
                let continuations = Array(waiters.values)
                waiters.removeAll()
                expiredTokens.removeAll()
                return continuations
            }
            semaphore.signal()
            for continuation in pending {
                continuation.resume(returning: value)
            }
        }

        func awaitExit(timeout: Duration) async -> (status: Int32, reason: Process.TerminationReason)? {
            let token = UUID()
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self else { return }
                let expired = self.lock.withLock { () -> CheckedContinuation<(status: Int32, reason: Process.TerminationReason)?, Never>? in
                    if let waiter = self.waiters.removeValue(forKey: token) {
                        return waiter
                    }
                    if self.info == nil {
                        self.expiredTokens.insert(token)
                    }
                    return nil
                }
                expired?.resume(returning: nil)
            }
            defer {
                timeoutTask.cancel()
                lock.withLock { _ = expiredTokens.remove(token) }
            }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let immediate: ((status: Int32, reason: Process.TerminationReason)?)? = lock.withLock {
                        let wasExpired = expiredTokens.remove(token) != nil
                        if let info { return .some(info) }
                        if Task.isCancelled || wasExpired { return .some(nil) }
                        waiters[token] = continuation
                        return nil
                    }
                    if let immediate {
                        continuation.resume(returning: immediate)
                    }
                }
            } onCancel: {
                let cancelled = lock.withLock { () -> CheckedContinuation<(status: Int32, reason: Process.TerminationReason)?, Never>? in
                    if let waiter = waiters.removeValue(forKey: token) {
                        return waiter
                    }
                    if info == nil {
                        expiredTokens.insert(token)
                    }
                    return nil
                }
                cancelled?.resume(returning: nil)
            }
        }

        func waitSynchronously(timeout: TimeInterval) -> Bool {
            if hasExited { return true }
            _ = semaphore.wait(timeout: .now() + timeout)
            return hasExited
        }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorPipe = Pipe()
    private let inputLock = NSLock()
    private var inputClosed = false
    private let exitState = ExitState()

    init(directory: URL) throws {
        process.executableURL = try ChildRun.journalTestProcess()
        process.arguments = ["fork-window", directory.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        let exitState = self.exitState
        process.terminationHandler = { terminated in
            exitState.recordExit(status: terminated.terminationStatus, reason: terminated.terminationReason)
        }
        try process.run()
    }

    func readLine() throws -> String {
        let handle = output.fileHandleForReading
        var bytes = Data()
        while let part = try handle.read(upToCount: 1), !part.isEmpty {
            if part == Data([10]) { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(part)
            guard bytes.count <= 128 else { throw AgentJournalError.invalidRecord }
        }
        throw AgentJournalError.invalidRecord
    }

    func signalExec() throws {
        let handle = inputLock.withLock { inputClosed ? nil : input.fileHandleForWriting }
        guard let handle else { throw AgentJournalError.invalidRecord }
        try handle.write(contentsOf: Data([1]))
    }

    func finishAndWaitForExit(
        timeout: Duration = .seconds(10),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> ExitResult {
        writeExitByteAndCloseInput()
        if let exited = await exitState.awaitExit(timeout: timeout) {
            return ExitResult(status: exited.status, reason: exited.reason, timedOut: false)
        }
        Issue.record(
            "fork-window helper process \(process.processIdentifier) did not exit within \(timeout)",
            sourceLocation: sourceLocation
        )
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        let killed = await exitState.awaitExit(timeout: .seconds(5))
        return ExitResult(
            status: killed?.status ?? -1,
            reason: killed?.reason ?? .uncaughtSignal,
            timedOut: true
        )
    }

    func cleanupIfStillRunning(sourceLocation: SourceLocation = #_sourceLocation) {
        defer {
            try? output.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
        }
        if exitState.hasExited {
            closeInputIfNeeded()
            return
        }
        closeInputIfNeeded()
        if exitState.waitSynchronously(timeout: 2) {
            return
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        if !exitState.waitSynchronously(timeout: 5) {
            Issue.record(
                "fork-window helper process \(process.processIdentifier) did not exit during cleanup",
                sourceLocation: sourceLocation
            )
        }
    }

    private func writeExitByteAndCloseInput() {
        let handle = inputLock.withLock { () -> FileHandle? in
            guard !inputClosed else { return nil }
            inputClosed = true
            return input.fileHandleForWriting
        }
        guard let handle else { return }
        try? handle.write(contentsOf: Data([1]))
        try? handle.close()
    }

    private func closeInputIfNeeded() {
        let handle = inputLock.withLock { () -> FileHandle? in
            guard !inputClosed else { return nil }
            inputClosed = true
            return input.fileHandleForWriting
        }
        try? handle?.close()
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
    private let onContention: (@Sendable () -> Void)?
    private var contendedCount = 0
    init(blockAcquired: Bool = false, onContention: (@Sendable () -> Void)? = nil) {
        self.blockAcquired = blockAcquired
        self.onContention = onContention
    }
    var acquisitions: Int { lock.withLock { acquiredCount } }
    var formatReads: Int { lock.withLock { readCount } }
    var contentions: Int { lock.withLock { contendedCount } }
    @Sendable func observe(_ stage: JournalOpeningStage) {
        switch stage {
        case .formatValidated: lock.withLock { readCount += 1 }
        case .lockContended:
            let first = lock.withLock { contendedCount += 1; return contendedCount == 1 }
            if first { onContention?() }
            contentionSignal.yield()
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

/// An in-process lock holder that lets go once, from any thread.
private final class BriefHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var held: JournalWriterLock?
    init(_ held: JournalWriterLock) { self.held = held }
    func release() { lock.withLock { try? held?.close(); held = nil } }
    deinit { release() }
}
