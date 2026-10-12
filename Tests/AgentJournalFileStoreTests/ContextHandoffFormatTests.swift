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

@Suite struct ContextHandoffFormatTests {
    @Test func upgradeRequiresClosedStoreAndPreservesCanonicalAndNativeFacts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "handoff-upgrade", supportsNativeContext: true)
        let session = UUID()
        let history: [ModelMessage] = [.user([.text("important constraint")]), .assistant(content: [.text("answer")], toolCalls: [])]
        try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])], sessionID: session, durability: .durable)
        let messages = try await journal.readMessages(sessionID: session, limit: 10)
        let identity = try await journal.storeIdentity()
        let source = ModelNativeContextSource(sessionID: session, canonicalMessageCount: 2, lastMessageID: messages.last?.id,
            canonicalDigest: "canonical", requestDigest: "request", projectionID: "identity", projectionVersion: "1", previousCheckpointID: nil)
        let transition = ModelNativeContextTransition(mode: .openAIStandalone, source: source, replayPosition: 0,
            invocationID: UUID(), responseID: "response")
        let continuation = ModelProviderContinuation(model: .init(provider: "openai", name: "fixture"), format: "openai.compact.v1",
            payload: Data(#"{"output":[{"type":"compaction","encrypted_content":"opaque"}]}"#.utf8), contextTransition: transition)
        let native = ModelNativeContextCheckpoint(id: UUID(), generation: 1, continuation: continuation,
            transition: transition, rootConfigurationDigest: "root", toolBaseline: [], usage: .init(inputTokens: 11, outputTokens: 2))
        try await journal.publishNativeContext(native, history: history, sessionID: session, runID: nil,
            expectedHistory: journal.historyWitness(sessionID: session))
        #expect(!journal.supportsContextHandoff)
        #expect(throws: AgentJournalError.storeInUse) {
            try AgentIncrementalJournal.upgradeForContextHandoff(at: directory)
        }
        try await journal.close()
        let before = try snapshot(directory)
        let upgraded = try AgentIncrementalJournal.upgradeForContextHandoff(at: directory)
        #expect(upgraded.supportsContextHandoff)
        #expect(try schema(directory) == 12)
        #expect(try await upgraded.storeIdentity() == identity)
        #expect(try await upgraded.readMessages(sessionID: session, limit: 10) == messages)
        #expect(try await upgraded.nativeContextCheckpoint(sessionID: session) == native)
        for (path, bytes) in before where path != "format.json" && path != "CURRENT" {
            #expect(try Data(contentsOf: directory.appendingPathComponent(path)) == bytes)
        }
        _ = try await upgraded.requestMaintenance()
        try await upgraded.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(reopened.supportsContextHandoff)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == history)
        #expect(try await reopened.nativeContextCheckpoint(sessionID: session) == native)
        try await reopened.close()
    }

    @Test(arguments: [JournalFileFaultStage.beforeFormatReplace, .afterFormatReplace, .beforeCurrentReplace, .afterCurrentReplace])
    func upgradeFailureReopensOnlyTheActualDurableFormat(_ stage: JournalFileFaultStage) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "upgrade-fault", supportsNativeContext: true)
        let session = UUID(), history: [ModelMessage] = [.user([.text("keep")]), .assistant(content: [.text("saved")], toolCalls: [])]
        try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])], sessionID: session, durability: .durable)
        let messages = try await journal.readMessages(sessionID: session, limit: 10)
        try await journal.close()
        let formatBefore = try Data(contentsOf: directory.appendingPathComponent("format.json"))
        let currentBefore = try Data(contentsOf: directory.appendingPathComponent("CURRENT"))
        let definite = AgentJournalError.persistenceUnavailable("controlled upgrade fault")
        #expect(throws: stage == .beforeFormatReplace ? definite : AgentJournalError.commitUnknown) {
            try AgentIncrementalJournal.upgradeForContextHandoffForTesting(at: directory, fault: { observed in
                if observed == stage { throw definite }
            })
        }
        if stage == .beforeFormatReplace {
            #expect(try Data(contentsOf: directory.appendingPathComponent("format.json")) == formatBefore)
        } else {
            #expect(try schema(directory) == 12)
        }
        if stage != .afterCurrentReplace {
            #expect(try Data(contentsOf: directory.appendingPathComponent("CURRENT")) == currentBefore)
        }
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(reopened.supportsContextHandoff == (stage != .beforeFormatReplace))
        #expect(try await reopened.readMessages(sessionID: session, limit: 10) == messages)
        _ = try await reopened.requestMaintenance()
        try await reopened.close()
        let again = try AgentIncrementalJournal.open(at: directory)
        #expect(try await again.latestCheckpoint(sessionID: session)?.history == history)
        try await again.close()
    }

    @Test(arguments: [false, true])
    func aMissingOrChangedPreparedRootCannotTriggerRepairOrTruncation(_ changed: Bool) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "missing-upgrade-root", supportsNativeContext: true)
        try await journal.close()
        #expect(throws: AgentJournalError.commitUnknown) {
            try AgentIncrementalJournal.upgradeForContextHandoffForTesting(at: directory, fault: { stage in
                if stage == .afterFormatReplace { throw AgentJournalError.persistenceUnavailable("stop before CURRENT") }
            })
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("format.json"))) as? [String: Any])
        let bridge = try #require(object["upgrade"] as? [String: Any])
        let rootID = try #require(bridge["targetRootID"] as? String)
        let storeID = try #require(object["storeID"] as? String)
        let targetURL = directory.appendingPathComponent("roots/\(storeID)_\(rootID).json")
        if changed {
            var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: targetURL)) as? [String: Any])
            root["sequence"] = 99
            try JSONSerialization.data(withJSONObject: root).write(to: targetURL)
        } else {
            try FileManager.default.removeItem(at: targetURL)
        }
        let before = try snapshot(directory)
        #expect(throws: (any Error).self) { try AgentIncrementalJournal.open(at: directory) }
        #expect(try snapshot(directory) == before)
    }

    @Test func anOpenerThatReadTheOldFormatCannotWriteAfterUpgrade() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "stale-format", supportsNativeContext: true)
        try await journal.close()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let opener = Task {
            try await AgentIncrementalJournal.openAsyncForTesting(at: directory, writerLockWait: .failFast, observer: { stage in
                if case .formatValidated = stage { entered.signal(); release.wait() }
            })
        }
        let arrived = await Task.detached { waitForSignal(entered) }.value
        try #require(arrived)
        let upgraded = try AgentIncrementalJournal.upgradeForContextHandoff(at: directory)
        try await upgraded.close()
        let before = try snapshot(directory)
        release.signal()
        await #expect(throws: AgentJournalError.checksumMismatch) { try await opener.value }
        #expect(try snapshot(directory) == before)
    }

    @Test func defaultFormatsDoNotUpgradeImplicitlyAndSchema12CreationIsExplicit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try AgentIncrementalJournal.create(at: directory, operationDomain: "default")
        #expect(!old.supportsContextHandoff)
        try await old.close()
        let segments = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("segments"), includingPropertiesForKeys: nil)
        let active = try #require(segments.first { $0.pathExtension == "seg" })
        try Data("unpublished physical tail".utf8).write(to: active)
        let before = try snapshot(directory)
        #expect(throws: AgentJournalError.unsupportedFormat) { try AgentIncrementalJournal.upgradeForContextHandoff(at: directory) }
        #expect(try schema(directory) == 3)
        #expect(try snapshot(directory) == before)
        let optIn = directory.appendingPathComponent("explicit")
        let new = try AgentIncrementalJournal.create(at: optIn, operationDomain: "new", supportsContextHandoff: true)
        #expect(new.supportsContextHandoff && new.supportsNativeContext)
        #expect(try schema(optIn) == 12)
        try await new.close()
    }

    @Test(arguments: ["handoff-upgrade-gate", "handoff-upgrade-current"])
    func processCrashRecoversPublishedUpgrade(_ mode: String) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "upgrade-crash", supportsNativeContext: true)
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
        let marker = UpgradeProcessMarker()
        try process.run()
        defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
        Thread { marker.set(output.fileHandleForReading.availableData); published.fulfill() }.start()
        let observed = await XCTWaiter.fulfillment(of: [published], timeout: 15)
        _ = kill(process.processIdentifier, SIGKILL)
        #expect(await XCTWaiter.fulfillment(of: [exited], timeout: 15) == .completed)
        try #require(observed == .completed && marker.value.contains("UPGRADE-PUBLISHED"))
        #expect(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(reopened.supportsContextHandoff)
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

private func waitForSignal(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 10) == .success
}

private final class UpgradeProcessMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    var value: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
