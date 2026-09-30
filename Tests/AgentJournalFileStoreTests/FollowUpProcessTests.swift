import AgentCore
import AgentJournalFileStore
import AgentModels
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct FollowUpProcessTests {
    @Test func processKilledAfterQueuedMutationEffectRetainsAdmissionAndNeverReplays() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-process-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("journal")
        let file = root.appendingPathComponent("effect.txt")
        try Data().write(to: file)
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        let journal = try AgentIncrementalJournal.create(at: store, operationDomain: "queue-child")
        let model = ModelID(provider: "queue-process", name: "fixed")
        let agent = try Agent(model: model, provider: QueueProbeProvider())
        let session = try agent.makeSession(id: sessionID, journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "one", text: "write B",
            operationID: "stable-write", configurationRef: "child-fixture"))
        try await journal.close()

        let process = Process()
        process.executableURL = try executable()
        process.arguments = ["queue-write-and-wait", store.path, file.path]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        // Foundation reaps the child and reports its exit through this handler; the test never
        // waits on the pid itself, and every wait below is bounded.
        let child = BoundedChild(process, errors: errors)
        try process.run()
        defer { child.stopIfRunning() }
        // Only the child's post-sync marker establishes the effect boundary.
        let marker = try child.firstOutput(from: output, within: 10)
        #expect(marker.contains("EFFECT-WRITTEN"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
        _ = kill(process.processIdentifier, SIGKILL)
        try child.waitForExit(within: 10)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)

        let reopened = try AgentIncrementalJournal.open(at: store)
        let restored = try agent.makeSession(id: sessionID, journal: reopened)
        guard case .admitted(let runID, let messageID)? = try await restored.followUp(inputID: "one")?.state else {
            Issue.record("queued admission was forgotten after process termination"); return
        }
        #expect(try await reopened.readMessages(sessionID: sessionID).map(\.id) == [messageID])
        #expect(try await reopened.recoverPendingMutations(sessionID: sessionID).map(\.state) == [.needsReconciliation])
        #expect(try await restored.enqueueFollowUp(.init(inputID: "one", text: "write B",
            operationID: "stable-write", configurationRef: "child-fixture")).state ==
            .admitted(runID: runID, formalMessageID: messageID))
        let denied = QueueProbeResolver()
        let dispatch = try await restored.startFollowUpDispatch(policy: .init(), resolver: denied)
        await dispatch.waitUntilPaused()
        #expect(await denied.calls == 0)
        await #expect(throws: AgentFollowUpError.needsInspection) {
            try await dispatch.resumeAfterInspection(inputID: "one")
        }
        await dispatch.stop()
        try await dispatch.waitForDrain()
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
        try await reopened.close()
    }

    private func executable() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var search = root.appendingPathComponent(".build/out/Products/Debug")
        let candidates = [search.appendingPathComponent("JournalTestProcess"),
                          root.appendingPathComponent(".build/debug/JournalTestProcess")]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return found }
        if let bundle = ProcessInfo.processInfo.arguments.first(where: { $0.hasSuffix(".xctest") }) {
            search = URL(fileURLWithPath: bundle).deletingLastPathComponent()
        }
        for _ in 0..<6 {
            let candidate = search.appendingPathComponent("JournalTestProcess")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            search.deleteLastPathComponent()
        }
        throw AgentJournalError.persistenceUnavailable("JournalTestProcess executable is missing")
    }
}

private struct QueueProbeProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "queue-process", capabilities: [.streaming, .multiTurn])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "should-not-run", model: request.model)
            try emit(.responseStarted(info))
            try emit(.responseCompleted(.init(info: info, content: [], stopReason: .endTurn)))
        }
    }
}

private actor QueueProbeResolver: AgentFollowUpResolver {
    private(set) var calls = 0
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        calls += 1
        throw AgentFollowUpError.needsInspection
    }
}

/// A child process whose waits are all bounded. A wait that runs out collects the child's state,
/// kills the child and fails the test instead of blocking it.
final class BoundedChild: @unchecked Sendable {
    private let process: Process
    private let errors: Pipe
    private let exited = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasExited = false

    init(_ process: Process, errors: Pipe) {
        self.process = process
        self.errors = errors
        let exited = self.exited
        process.terminationHandler = { [weak self] _ in
            self?.lock.withLock { self?.hasExited = true }
            exited.signal()
        }
    }

    /// The first output the child writes; empty if it exits without writing.
    func firstOutput(from pipe: Pipe, within seconds: TimeInterval) throws -> String {
        guard let data = Self.read(within: seconds, { pipe.fileHandleForReading.availableData }) else {
            throw failure("no output within \(seconds)s")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func waitForExit(within seconds: TimeInterval) throws {
        if lock.withLock({ hasExited }) { return }
        guard exited.wait(timeout: .now() + seconds) == .success else {
            throw failure("no exit reported within \(seconds)s")
        }
    }

    func stopIfRunning() {
        guard !lock.withLock({ hasExited }) else { return }
        _ = kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 10)
    }

    private func failure(_ reason: String) -> BoundedChildError {
        let pid = process.processIdentifier
        let exists = kill(pid, 0) == 0 ? "exists" : "kill(0) errno \(errno)"
        #if os(Linux)
        let status = (try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8))?
            .split(separator: "\n").first { $0.hasPrefix("State:") }.map(String.init) ?? "no /proc status"
        #else
        let status = "no /proc on this platform"
        #endif
        let state = "pid=\(pid) isRunning=\(process.isRunning) exitReported=\(lock.withLock { hasExited }) \(exists) \(status)"
        _ = kill(pid, SIGKILL)
        let stderr = Self.read(within: 2) { self.errors.fileHandleForReading.readDataToEndOfFile() }
            .map { String(decoding: $0, as: UTF8.self) } ?? "stderr not closed within 2s"
        return BoundedChildError(reason: reason, state: state, stderr: String(stderr.suffix(2000)))
    }

    /// Runs a blocking read on its own thread and gives up waiting after `seconds`.
    private static func read(within seconds: TimeInterval, _ body: @escaping @Sendable () -> Data) -> Data? {
        let done = DispatchSemaphore(value: 0)
        let box = DataBox()
        Thread { box.value = body(); done.signal() }.start()
        return done.wait(timeout: .now() + seconds) == .success ? box.value : nil
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var value: Data? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private struct BoundedChildError: Error, CustomStringConvertible {
    let reason: String
    let state: String
    let stderr: String
    var description: String { "child process: \(reason); \(state); stderr: \(stderr)" }
}
