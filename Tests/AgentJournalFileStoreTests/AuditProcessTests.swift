import AgentCore
import AgentJournalFileStore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct AuditProcessTests {
    @Test(arguments: ["audit-deny-and-exit", "audit-write-and-settle", "audit-write-and-wait"])
    func independentProcessReopensTypedFactsAndUnknownEffects(_ mode: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audit-process-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathExtension("effect")
        defer { try? FileManager.default.removeItem(at: file) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "audit-process", supportsAuthorizationAudit: true)
        try await journal.close()
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = try executable()
        process.arguments = [mode, directory.path, file.path]
        process.standardOutput = output; process.standardError = errors
        let child = BoundedChild(process, errors: errors)
        try process.run(); defer { child.stopIfRunning() }
        if mode == "audit-write-and-wait" {
            #expect(try child.firstOutput(from: output, within: 10).contains("AUDIT-EFFECT-WRITTEN"))
            _ = kill(process.processIdentifier, SIGKILL)
        }
        try child.waitForExit(within: 10)
        #expect(process.terminationStatus == (mode == "audit-write-and-wait" ? SIGKILL : 0))
        let reader = Process(), readOutput = Pipe(), readErrors = Pipe()
        reader.executableURL = try executable(); reader.arguments = ["read-audit", directory.path]
        reader.standardOutput = readOutput; reader.standardError = readErrors
        let readerChild = BoundedChild(reader, errors: readErrors)
        try reader.run(); defer { readerChild.stopIfRunning() }
        let line = try readerChild.firstOutput(from: readOutput, within: 10)
        try readerChild.waitForExit(within: 10)
        #expect(reader.terminationStatus == 0)
        if mode == "audit-deny-and-exit" {
            #expect(line.contains("allowed=0 denied=1 applied=0 observed=0 results=0 pending=0"))
            #expect(!FileManager.default.fileExists(atPath: file.path))
        } else if mode == "audit-write-and-settle" {
            #expect(line.contains("allowed=1 denied=0 applied=1 observed=1 results=1 pending=0"))
            #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
        } else {
            #expect(line.contains("allowed=1 denied=0 applied=1 observed=0 results=0 pending=1"))
            #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
            let reopened = try AgentIncrementalJournal.open(at: directory)
            #expect(try await reopened.recoverPendingMutations().first?.state == .needsReconciliation)
            // No absent observation is taken as no-effect proof; nothing replays the file operation.
            #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
            try await reopened.close()
        }
    }

    private func executable() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let value = [root.appendingPathComponent(".build/out/Products/Debug/JournalTestProcess"),
                        root.appendingPathComponent(".build/debug/JournalTestProcess")].first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return value }
        throw AgentJournalError.persistenceUnavailable("missing JournalTestProcess")
    }
}
