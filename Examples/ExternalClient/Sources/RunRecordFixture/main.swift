import AgentCore
import AgentJournalFileStore
import AgentModels
import Foundation

/// Offline Host example: look up the past, then choose a distinct new Run.
@main struct RunRecordFixture {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-run-record-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID(), model = ModelID(provider: "run-record-fixture", name: "fixed")
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "host-fixture", supportsRunRecords: true)
        let first = try Agent(model: model, provider: FixtureProvider(hold: true)).makeSession(id: sessionID, journal: journal)
        let correlation = try AgentRunCorrelation(key: "attempt/1", payloadDigest: "readonly-config-v1")
        guard try await first.runRecord(correlationKey: correlation.key) == .notAdmitted else { throw FixtureError.unexpectedState }
        let run = try await first.run("read-only research", correlation: correlation)
        guard case .admitted = try await first.runRecord(correlationKey: correlation.key) else { throw FixtureError.unexpectedState }
        await run.cancel()
        do { _ = try await run.wait(); throw FixtureError.unexpectedState } catch is CancellationError { }
        try await run.waitForDrain(); try await journal.close()
        do { _ = try await first.runRecord(correlationKey: correlation.key); throw FixtureError.unexpectedState }
        catch AgentJournalError.storeClosed { print("closed store: error, never notAdmitted") }

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try Agent(model: model, provider: FixtureProvider(hold: false)).makeSession(id: sessionID, journal: reopened)
        let original = try await restored.runRecord(correlationKey: correlation.key)
        guard case .terminal(let record, .cancelled) = original,
              try await reopened.pendingMutations(sessionID: sessionID).isEmpty else { throw FixtureError.unexpectedState }
        // Host checks its own evidence: this fixture has only read-only work, drained locally,
        // and no external jobs. This Host decision starts new work; it does not revive old permission.
        let next = try await restored.run("new research after Host inspection", correlation: .init(key: "attempt/2", payloadDigest: "readonly-config-v1"))
        guard try await next.wait().outcome == .completed, next.id != record.runID else { throw FixtureError.unexpectedState }
        try await next.waitForDrain()
        guard try await restored.runRecord(runID: record.runID) == original else { throw FixtureError.unexpectedState }
        print("notAdmitted -> admitted -> terminal(cancelled); Host chose a new completed Run; old fact unchanged")
        try await reopened.close()
    }
}

private enum FixtureError: Error { case unexpectedState }
private struct FixtureProvider: ModelProvider {
    let hold: Bool
    let descriptor = ModelProviderDescriptor(id: "run-record-fixture", capabilities: [.streaming, .multiTurn])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            if hold { try await Task.sleep(for: .seconds(60)) }
            let info = ResponseInfo(id: "fixture", model: request.model)
            try emit(.responseStarted(info)); try emit(.textDelta("done"))
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
        }
    }
}
