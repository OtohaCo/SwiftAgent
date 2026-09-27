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
        try process.run()
        defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        // A failed child must not leave the test blocked forever waiting for
        // a marker it never wrote. This watchdog is not the ordering signal:
        // only the child's post-sync marker establishes the effect boundary.
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(10))
                if !Task.isCancelled && process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                }
            } catch { /* The observed effect marker cancelled the watchdog. */ }
        }
        let marker = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        watchdog.cancel()
        await watchdog.value
        #expect(marker.contains("EFFECT-WRITTEN"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
        _ = kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
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
