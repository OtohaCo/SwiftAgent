import AgentCore
import AgentModels
import AgentTools
import Foundation
import XCTest

private func sabotageStoreRoot(at directory: URL) throws {
    let root = directory.appendingPathComponent("CURRENT")
    let saved = directory.appendingPathComponent("sabotaged-current")
    try FileManager.default.moveItem(at: root, to: saved)
}

private func restoreStoreRoot(at directory: URL) throws {
    let saved = directory.appendingPathComponent("sabotaged-current")
    guard FileManager.default.fileExists(atPath: saved.path) else { return }
    try FileManager.default.moveItem(at: saved, to: directory.appendingPathComponent("CURRENT"))
}

final class AgentSessionHangTests: XCTestCase {
    func testExecutorAndQuarantineFailureUseOneTypedTerminalWithoutReplay() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-on-failed-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try makeTestJournal(at: url)
        let probe = FailingMutationProbe()
        let tool = try ThrowingSabotagingMutationTool(journalURL: url, journal: journal, probe: probe)
        let call = ToolCall(id: .init(rawValue: "call-fail"), name: ThrowingSabotagingMutationTool.name,
                            argumentsJSON: #"{"id":"listing-1"}"#, completeness: .complete)
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [tool],
                                configuration: .init(runTimeout: .seconds(3))).makeSession(journal: journal)
        let run = try await session.run("Update and fail")

        let waitOutcome = await firstCompleted(timeout: .seconds(8)) {
            do {
                _ = try await run.wait()
                return "completed"
            } catch is AgentMutationPersistenceError {
                return "persistence"
            } catch {
                return "other"
            }
        }
        XCTAssertEqual(waitOutcome, "persistence")
        let firstExecutorCount = await probe.executorCount
        let sawDurableIntent = await probe.sawDurableIntent
        let externalStateChanged = await probe.externalStateChanged
        XCTAssertEqual(firstExecutorCount, 1)
        XCTAssertTrue(sawDurableIntent)
        XCTAssertTrue(externalStateChanged)

        let events = await collectEvents(run.events)
        let terminals = events.compactMap { event -> AgentRunTermination? in
            if case .runFinished(let value) = event { return value }
            return nil
        }
        XCTAssertEqual(terminals.count, 1)
        guard case .failed(.mutationPersistence(let terminalError)) = terminals[0] else {
            return XCTFail("Expected typed mutation persistence terminal: \(terminals)")
        }
        guard case .journal(.persistenceUnavailable) = terminalError.quarantine else {
            return XCTFail("Expected typed quarantine persistence failure: \(terminalError.quarantine)")
        }
        XCTAssertFalse(events.contains { if case .toolCompleted = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .toolReceiptValidated = $0 { true } else { false } })
        try restoreStoreRoot(at: url)
        let mutationStates = try await journal.pendingMutations().map(\.state)
        XCTAssertEqual(mutationStates, [.intent])
        try await run.waitForDrain()
        try await journal.close()
        let finalExecutorCount = await probe.executorCount
        XCTAssertEqual(finalExecutorCount, 1)
    }

    func testMutationCommitAndQuarantineFailureStillFinishesTheRun() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-hang-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try makeTestJournal(at: url)
        let tool = try SabotagingMutationTool(journalURL: url)
        let call = ToolCall(
            id: .init(rawValue: "call-1"),
            name: SabotagingMutationTool.name,
            argumentsJSON: #"{"id":"listing-1"}"#,
            completeness: .complete
        )
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "Done")
        }
        let agent = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [tool],
            configuration: AgentConfiguration(runTimeout: .seconds(3))
        )
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("Update the listing")

        let waitOutcome = await firstCompleted(timeout: .seconds(8)) {
            do {
                _ = try await run.wait()
                return "completed" as String
            } catch is AgentMutationPersistenceError {
                return "persistence"
            } catch {
                return "failed"
            }
        }
        XCTAssertEqual(waitOutcome, "persistence", "run.wait() must return the combined persistence failure instead of hanging")
        guard waitOutcome == "persistence" else { return }

        let events = await collectEvents(run.events)
        let finished = events.compactMap { event -> AgentRunTermination? in
            if case .runFinished(let termination) = event { return termination }
            return nil
        }
        XCTAssertEqual(finished.count, 1)
        guard case .failed(let failure) = finished[0] else {
            return XCTFail("expected runFinished(.failed), got \(finished)")
        }
        if case .mutationPersistence(let persistence) = failure {
            guard case .journal(.persistenceUnavailable) = persistence.settlement,
                  case .journal(.persistenceUnavailable) = persistence.quarantine else {
                return XCTFail("Expected typed store persistence errors: \(persistence)")
            }
        } else {
            XCTFail("expected mutationPersistence failure, got \(failure)")
        }
        XCTAssertFalse(events.contains { if case .toolCompleted = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .toolReceiptValidated = $0 { true } else { false } })
        try restoreStoreRoot(at: url)
        let pending = try await journal.pendingMutations()
        XCTAssertEqual(pending.map(\.state), [.intent])
        try await run.waitForDrain()
        try await journal.close()
    }
}

private actor FailingMutationProbe {
    private(set) var executorCount = 0
    private(set) var sawDurableIntent = false
    private(set) var externalStateChanged = false

    func record(journal: AgentJournal, callID: ToolCallID) async {
        executorCount += 1
        sawDurableIntent = (try? await journal.pendingMutations().contains {
            $0.intent.call.id == callID && $0.state == .intent
        }) == true
        externalStateChanged = true
    }
}

private struct ThrowingSabotagingMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = "throwing_update_listing"
    static let description = "Update then fail"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let journalURL: URL
    let journal: AgentJournal
    let probe: FailingMutationProbe
    let policy: ToolPolicy

    init(journalURL: URL, journal: AgentJournal, probe: FailingMutationProbe) throws {
        self.journalURL = journalURL
        self.journal = journal
        self.probe = probe
        policy = try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
                                timeout: .seconds(2), authorization: .notRequired)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "property.listing", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "property.listing", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.record(journal: journal, callID: context.callID)
        try? sabotageStoreRoot(at: journalURL)
        throw FixtureError.invalidOperation
    }
}

private struct SabotagingMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }

    static let name = "update_listing"
    static let description = "Update a listing"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let journalURL: URL
    let policy: ToolPolicy

    init(journalURL: URL) throws {
        self.journalURL = journalURL
        policy = try ToolPolicy(
            effect: .mutation,
            execution: .exclusive,
            idempotency: .requiresReceipt,
            timeout: .seconds(2),
            authorization: .notRequired
        )
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "property.listing", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "property.listing", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        try? sabotageStoreRoot(at: journalURL)
        return ToolResult(
            output: .init(updated: true),
            receipt: ToolReceipt(
                operationID: context.idempotencyKey ?? "",
                status: .succeeded,
                confirmedTargets: [.init(namespace: "property.listing", id: input.id)],
                revision: "v2"
            )
        )
    }
}

private func firstCompleted(timeout: Duration, _ body: @escaping @Sendable () async -> String) async -> String {
    await withTaskGroup(of: String.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return "timeout"
        }
        let first = await group.next() ?? "timeout"
        group.cancelAll()
        return first
    }
}
