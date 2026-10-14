import Foundation
import Testing
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import AgentModels
@testable import AgentCore
@testable import AgentJournalFileStore

@Suite struct IncompleteHandoffFormatTests {
    private func createSource(_ directory: URL, schema: Int) throws -> AgentJournal {
        if schema == 13 { return try AgentIncrementalJournal.create(at: directory, operationDomain: "incomplete-upgrade", supportsFileContent: true) }
        return try AgentIncrementalJournal.create(at: directory, operationDomain: "incomplete-upgrade", supportsContextHandoff: true)
    }

    @Test(arguments: [12, 13])
    func exclusiveUpgradePreservesFactsAndFiles(_ schema: Int) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try createSource(directory, schema: schema)
        let id = UUID(), identity = await journal.storeIdentity()
        let file = try ModelFileReference(uri: URL(string: "https://example.com/immutable")!, mediaType: .plainText, description: "notes", estimatedInputTokens: 7)
        let history: [ModelMessage] = [.user(schema == 13 ? [.text("constraint"), .file(file)] : [.text("constraint")])]
        try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])], sessionID: id, durability: .durable)
        let messages = try await journal.readMessages(sessionID: id)
        #expect(throws: AgentJournalError.storeInUse) { try AgentIncrementalJournal.upgradeForIncompleteContextHandoff(at: directory) }
        try await journal.close()
        let upgraded = try AgentIncrementalJournal.upgradeForIncompleteContextHandoff(at: directory)
        #expect(upgraded.supportsIncompleteContextHandoff && upgraded.supportsFileContent)
        #expect(await upgraded.storeIdentity() == identity)
        #expect(try await upgraded.readMessages(sessionID: id) == messages)
        _ = try await upgraded.requestMaintenance(); try await upgraded.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: id)?.history == history)
        #expect(try self.schema(directory) == 14)
        try await reopened.close()
    }

    @Test func priorElevenToTwelveBridgeDoesNotRequireAncestralFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try AgentIncrementalJournal.create(at: directory, operationDomain: "nested", supportsNativeContext: true)
        try await old.close()
        let twelve = try AgentIncrementalJournal.upgradeForContextHandoff(at: directory)
        let id = UUID(), history: [ModelMessage] = [.user([.text("later publication")])]
        try await twelve.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])], sessionID: id, durability: .durable)
        _ = try await twelve.requestMaintenance(); try await twelve.close()
        let format = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("format.json"))) as? [String: Any])
        let bridge = try #require(format["upgrade"] as? [String: Any])
        let prior = try #require(bridge["oldCurrent"] as? [String: Any])
        let current = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("CURRENT"))) as? [String: Any])
        for rootID in [try #require(prior["root"] as? String), try #require(bridge["targetRootID"] as? String)] {
            #expect(rootID != current["root"] as? String)
            let ancestor = directory.appendingPathComponent("roots/\(format["storeID"]!)_\(rootID).json")
            if FileManager.default.fileExists(atPath: ancestor.path) { try FileManager.default.removeItem(at: ancestor) }
        }
        #expect(throws: AgentJournalError.commitUnknown) {
            try AgentIncrementalJournal.upgradeForIncompleteContextHandoffForTesting(at: directory, fault: { stage in
                if stage == .afterFormatReplace { throw AgentJournalError.persistenceUnavailable("gate") }
            })
        }
        let recovered = try AgentIncrementalJournal.open(at: directory)
        #expect(recovered.supportsIncompleteContextHandoff)
        #expect(try await recovered.latestCheckpoint(sessionID: id)?.history == history)
        try await recovered.close()
    }

    @Test(arguments: [12, 13], [JournalFileFaultStage.beforeFormatReplace, .afterFormatReplace, .beforeCurrentReplace, .afterCurrentReplace])
    func publicationFailureRecoversOnlyActualFormat(_ schema: Int, _ boundary: JournalFileFaultStage) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try createSource(directory, schema: schema); try await old.close()
        let definite = AgentJournalError.persistenceUnavailable("upgrade-fault")
        #expect(throws: boundary == .beforeFormatReplace ? definite : AgentJournalError.commitUnknown) {
            try AgentIncrementalJournal.upgradeForIncompleteContextHandoffForTesting(at: directory, fault: { stage in if stage == boundary { throw definite } })
        }
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(reopened.supportsIncompleteContextHandoff == (boundary != .beforeFormatReplace))
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func missingOrAlteredRecoveryTargetRefusesWithoutWrites(_ altered: Bool) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try createSource(directory, schema: 13); try await old.close()
        #expect(throws: AgentJournalError.commitUnknown) {
            try AgentIncrementalJournal.upgradeForIncompleteContextHandoffForTesting(at: directory, fault: { stage in
                if stage == .afterFormatReplace { throw AgentJournalError.persistenceUnavailable("gate") }
            })
        }
        let format = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("format.json"))) as? [String: Any])
        let bridge = try #require(format["upgrade"] as? [String: Any])
        let target = directory.appendingPathComponent("roots/\(format["storeID"]!)_\(bridge["targetRootID"]!).json")
        if altered {
            var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
            root["sequence"] = 123
            try JSONSerialization.data(withJSONObject: root).write(to: target)
        } else { try FileManager.default.removeItem(at: target) }
        let before = try snapshot(directory)
        #expect(throws: (any Error).self) { try AgentIncrementalJournal.open(at: directory) }
        #expect(try snapshot(directory) == before)
    }

    @Test(arguments: [12, 13], ["incomplete-upgrade-gate", "incomplete-upgrade-current"])
    func processCrashRecoversPublishedUpgrade(_ schema: Int, _ mode: String) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try createSource(directory, schema: schema)
        let id = UUID()
        let history: [ModelMessage] = [.user([.text("durable source")]), .assistant(content: [.text("saved answer")], toolCalls: [])]
        try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])], sessionID: id, durability: .durable)
        let messages = try await journal.readMessages(sessionID: id)
        try await journal.close()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executables = [root.appendingPathComponent(".build/out/Products/Debug/JournalTestProcess"), root.appendingPathComponent(".build/debug/JournalTestProcess")]
        let executable = try #require(executables.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = [mode, directory.path]
        process.standardOutput = output; process.standardError = errors
        let exited = XCTestExpectation(description: "upgrade child exited")
        process.terminationHandler = { _ in exited.fulfill() }
        let published = XCTestExpectation(description: "upgrade publication boundary")
        let marker = IncompleteUpgradeProcessMarker()
        try process.run()
        defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
        Thread { marker.set(output.fileHandleForReading.availableData); published.fulfill() }.start()
        let observed = await XCTWaiter.fulfillment(of: [published], timeout: 15)
        _ = kill(process.processIdentifier, SIGKILL)
        #expect(await XCTWaiter.fulfillment(of: [exited], timeout: 15) == .completed)
        try #require(observed == .completed && marker.value.contains("UPGRADE-PUBLISHED"))
        #expect(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(reopened.supportsIncompleteContextHandoff)
        #expect(try await reopened.readMessages(sessionID: id) == messages)
        _ = try await reopened.requestMaintenance()
        try await reopened.close()
        let again = try AgentIncrementalJournal.open(at: directory)
        #expect(try await again.latestCheckpoint(sessionID: id)?.history == history)
        try await again.close()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("handoff-format-\(UUID())")
    }
    private func schema(_ directory: URL) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("format.json"))) as! [String: Any]
        return object["schema"] as! Int
    }
    private func snapshot(_ directory: URL) throws -> [String: Data] {
        var values: [String: Data] = [:]
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        let files = FileManager.default.enumerator(atPath: canonical.path)!
        for case let path as String in files {
            let url = canonical.appendingPathComponent(path)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                values[path] = try Data(contentsOf: url)
            }
        }
        return values
    }
}

private final class IncompleteUpgradeProcessMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    var value: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
