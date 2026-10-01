import AgentCore
import AgentJournalFileStore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ConfirmedNoEffectProcessTests {
    @Test(arguments: [false, true])
    func sigkillBeforeAndAfterPublicationReopensAllOrNoTypedFacts(_ committed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("no-effect-process-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "process", supportsConfirmedNoEffect: true)
        try await journal.close()
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = try executable()
        process.arguments = [committed ? "no-effect-after-publication" : "no-effect-before-publication", directory.path]
        process.standardOutput = output; process.standardError = errors
        let child = BoundedChild(process, errors: errors)
        try process.run(); defer { child.stopIfRunning() }
        let prepared = try child.firstOutput(from: output, within: 15)
        #expect(prepared.contains("NO-EFFECT-PREPARED"))
        let components = prepared.split(whereSeparator: { $0.isWhitespace })
        let sessionID = try #require(components.first { $0.hasPrefix("session=") }).dropFirst(8)
        let runID = try #require(components.first { $0.hasPrefix("run=") }).dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        if committed && !prepared.contains("NO-EFFECT-COMMITTED") {
            #expect(try child.firstOutput(from: output, within: 15).contains("NO-EFFECT-COMMITTED"))
        }
        _ = kill(process.processIdentifier, SIGKILL); try child.waitForExit(within: 15)
        #expect(process.terminationStatus == SIGKILL)
        let reader = Process(), readOutput = Pipe(), readErrors = Pipe()
        reader.executableURL = try executable(); reader.arguments = ["read-no-effect", directory.path, String(sessionID), runID]
        reader.standardOutput = readOutput; reader.standardError = readErrors
        let readChild = BoundedChild(reader, errors: readErrors)
        try reader.run(); defer { readChild.stopIfRunning() }
        let line = try readChild.firstOutput(from: readOutput, within: 15)
        try readChild.waitForExit(within: 15)
        #expect(reader.terminationStatus == 0)
        #expect(line.contains(committed ? "proof=1 paired=true executor=1 pending=0" : "proof=0 paired=false executor=0 pending=1"))
    }
    private func executable() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let url = [root.appendingPathComponent(".build/out/Products/Debug/JournalTestProcess"), root.appendingPathComponent(".build/debug/JournalTestProcess")].first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw AgentJournalError.invalidRecord }
        return url
    }
}
