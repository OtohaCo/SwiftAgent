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

/// The writer lock belongs to the handle that opened the store. A child process the Host starts while
/// the store is open must not keep the lock after that handle closes.
@Suite(.serialized) struct WriterLockLifetimeTests {
    enum SpawnPath: String, Sendable, CaseIterable { case foundationProcess, posixSpawn }

    #if os(Linux)
    static let platform = "linux"
    #else
    static let platform = "darwin"
    #endif

    @Test(arguments: SpawnPath.allCases)
    func closedStoreReopensWhileAnUnrelatedChildIsAlive(_ path: SpawnPath) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("writer-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "writer-lock")
        _ = try await journal.appendCheckpoint([.checkpoint(history: [.user([.text("held")])], steeringIDs: [])],
                                               sessionID: UUID(), runID: UUID(), durability: .durable)

        // The Host starts an unrelated, long-lived child while it owns the store.
        let child = try LongLivedChild(path)
        defer { child.stop() }
        let inherited = LockDescriptors.held(by: child.pid, store: directory)
        try await journal.close()

        let reopen = try ChildRun.probe(directory)
        print("writer-lock-evidence platform=\(Self.platform) path=\(path.rawValue) child-lock-descriptor=\(inherited.description) reopen-status=\(reopen.status)")
        #expect(reopen.status == 0,
                "\(path): an independent process could not reopen the closed store: \(reopen.summary); child inherited the lock: \(inherited.description)")
        #expect(inherited != .held, "\(path): the unrelated child holds the writer lock descriptor")
    }
}

/// Whether a process has the store's writer lock open, from its descriptor table.
enum LockDescriptors: Equatable, CustomStringConvertible {
    case held, notHeld, unknown(String)

    var description: String {
        switch self {
        case .held: "held"
        case .notHeld: "not held"
        case .unknown(let reason): "unknown (\(reason))"
        }
    }

    static func held(by pid: pid_t, store directory: URL) -> LockDescriptors {
        let suffix = directory.lastPathComponent + "/.writer.lock"
        #if os(Linux)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(pid)/fd") else {
            return .unknown("/proc/\(pid)/fd is unreadable")
        }
        let paths = entries.compactMap { try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/fd/\($0)") }
        return paths.contains { $0.hasSuffix(suffix) } ? .held : .notHeld
        #else
        guard let listing = try? ChildRun.run(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-n", "-P", "-p", String(pid), "-Fn"]),
              listing.status == 0 || !listing.output.isEmpty else {
            return .unknown("lsof did not list pid \(pid)")
        }
        let paths = listing.output.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        return paths.contains { $0.hasSuffix(suffix) } ? .held : .notHeld
        #endif
    }
}

/// `/bin/sleep`, started through one launch path and reaped only by that path's owner.
final class LongLivedChild: @unchecked Sendable {
    let pid: pid_t
    private let process: Process?
    private let exited = DispatchSemaphore(value: 0)

    init(_ path: WriterLockLifetimeTests.SpawnPath) throws {
        switch path {
        case .foundationProcess:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            let exited = self.exited
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            self.process = process
            pid = process.processIdentifier
        case .posixSpawn:
            var spawned: pid_t = 0
            let arguments = ["/bin/sleep", "60"].map { (argument: String) in strdup(argument) }
            defer { arguments.forEach { free($0) } }
            var argv: [UnsafeMutablePointer<CChar>?] = arguments + [nil]
            var envp: [UnsafeMutablePointer<CChar>?] = [nil]
            let result = posix_spawn(&spawned, "/bin/sleep", nil, nil, &argv, &envp)
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
            process = nil
            pid = spawned
        }
    }

    /// Kills and reaps the child within a bound; Foundation reaps its own, the test reaps a posix_spawn child.
    func stop() {
        _ = kill(pid, SIGKILL)
        if process != nil {
            _ = exited.wait(timeout: .now() + 10)
        } else {
            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(10)
            while waitpid(pid, &status, WNOHANG) == 0, Date() < deadline { usleep(10_000) }
        }
    }
}

/// A bounded child run: output is captured, and a child that outlives its bound is killed.
struct ChildRun {
    let status: Int32
    let output: String
    let timedOut: Bool
    var summary: String { "status=\(status) timedOut=\(timedOut) output=\(output.prefix(400))" }

    static func probe(_ store: URL) throws -> ChildRun {
        try run(try journalTestProcess(), ["probe", store.path])
    }

    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 30) throws -> ChildRun {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let collected = OutputBuffer()
        let reader = Thread { collected.set(output.fileHandleForReading.readDataToEndOfFile()) }
        reader.start()
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            _ = kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 10)
        }
        let text = collected.wait(timeout: 10)
        return ChildRun(status: timedOut ? -1 : process.terminationStatus, output: text, timedOut: timedOut)
    }

    static func journalTestProcess() throws -> URL {
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

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value }; done.signal() }
    func wait(timeout: TimeInterval) -> String {
        _ = done.wait(timeout: .now() + timeout)
        return lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
