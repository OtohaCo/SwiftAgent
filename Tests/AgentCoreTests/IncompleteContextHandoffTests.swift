import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

@Suite struct IncompleteContextHandoffTests {
    @Test func drainedTruncatedTurnCanExplicitlyRetireWithoutInventingCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("incomplete-handoff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.createForIncompleteContextHandoff(at: directory, operationDomain: "incomplete")
        let provider = IncompleteHandoffProvider()
        let binding = try incompleteBinding(provider)
        let session = try Agent(binding: binding).makeSession(journal: journal)
        let run = try await session.run("original", contextControls: .init(reminder: "reply in Japanese"))
        #expect(try await run.wait().outcome == .incomplete(.maxOutputTokens))
        try await run.waitForDrain()
        let before = try await journal.readMessages(sessionID: session.id)
        let terminal = try await journal.runRecord(sessionID: session.id, runID: run.id)
        let operation = try await session.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
        let value = try await operation.wait(); try await operation.waitForDrain()
        #expect(value.completedRunID == nil)
        #expect(value.closedTurnProof?.terminal == .incomplete(.maxOutputTokens))
        #expect(try await journal.readMessages(sessionID: session.id) == before)
        #expect(try await journal.runRecord(sessionID: session.id, runID: run.id) == terminal)
        #expect(await provider.requests == 1)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.readMessages(sessionID: session.id) == before)
        #expect(try await reopened.runRecord(sessionID: session.id, runID: run.id) == terminal)
        #expect(try await reopened.contextHandoff(sessionID: session.id) == value)
        let fresh = try Agent(binding: binding).makeSession(id: session.id, journal: reopened)
        let next = try await fresh.run("next", contextControls: .init(reminder: "new reminder"))
        _ = try await next.wait(); try await next.waitForDrain()
        #expect(await provider.requests == 2)
        #expect(try await reopened.runRecord(sessionID: session.id, runID: run.id) == terminal)
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func userOnlyFailedOrCancelledTurnCanHandoffAfterDrainAndReopen(_ cancel: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.createForIncompleteContextHandoff(at: directory, operationDomain: "user-tail")
        let gate = IncompleteGate(), provider = IncompleteHandoffProvider(fail: true, gate: cancel ? gate : nil)
        let binding = try incompleteBinding(provider), id = UUID()
        let session = try Agent(binding: binding).makeSession(id: id, journal: journal)
        let run = try await session.run("admitted no answer", contextControls: .init(reminder: "required reminder"))
        if cancel {
            await gate.waitEntered(); await run.cancel()
            await #expect(throws: CancellationError.self) { try await run.wait() }
            let other = try Agent(binding: binding).makeSession(id: id, journal: journal)
            await #expect(throws: AgentSessionError.runInProgress) {
                try await other.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
            }
            await gate.release()
        } else { await #expect(throws: ModelProviderError.self) { try await run.wait() } }
        try await run.waitForDrain()
        let before = try await journal.readMessages(sessionID: id)
        #expect(before.map(\.message.role) == [.user])
        let controls = try #require(try await journal.conversationControlState(sessionID: id))
        #expect(controls.entries.count == 1)
        let terminal = try await journal.runRecord(sessionID: id, runID: run.id)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.conversationControlState(sessionID: id) == controls)
        let fresh = try Agent(binding: binding).makeSession(id: id, journal: reopened)
        let refused = try await fresh.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true)
        await #expect(throws: ModelProviderError.self) { try await refused.wait() }; try await refused.waitForDrain()
        let exit = try await fresh.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
        let value = try await exit.wait(); try await exit.waitForDrain()
        #expect(value.closedTurnProof?.terminal == (cancel ? .cancelled : .failed(.provider)))
        #expect(try await reopened.readMessages(sessionID: id) == before)
        #expect(try await reopened.runRecord(sessionID: id, runID: run.id) == terminal)
        #expect(try await reopened.conversationControlState(sessionID: id)?.entries.isEmpty == true)
        #expect(await provider.requests == 1)
        try await reopened.close()
    }

    @Test func incompleteConsentRequiresNewFormatAndExplicitOmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "legacy", supportsContextHandoff: true)
        let provider = IncompleteHandoffProvider(), binding = try incompleteBinding(provider)
        let session = try Agent(binding: binding).makeSession(journal: journal)
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            try await session.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
        }
        await #expect(throws: ModelProviderError.self) {
            try await session.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: false, allowingIncompleteTurn: true)
        }
        #expect(await provider.requests == 0)
        try await journal.close()
    }

    @Test func verifiedReconciliationAllowsToolTailExitWithoutReexecutingMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.createForIncompleteContextHandoff(at: directory, operationDomain: "mutation-exit")
        let gate = IncompleteGate(), calls = IncompleteExecutionCount(), file = directory.appendingPathComponent("effect.txt")
        let provider = ScriptedProvider { request, _ in toolResponse(request, [.init(id: .init(rawValue: "write"), name: IncompleteWriteTool.name, argumentsJSON: "{}", completeness: .complete)]) }
        let binding = try AgentModelBinding(profileID: "mutation", profileRevision: "1", model: fixtureModel, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"))
        let agent = try Agent(binding: binding, tools: [IncompleteWriteTool(file: file, gate: gate, calls: calls)])
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("write once")
        await gate.waitEntered(); await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        await gate.release(); try await run.waitForDrain()
        let terminal = try await journal.runRecord(sessionID: session.id, runID: run.id)
        let pending = try #require(try await journal.recoverPendingMutations(sessionID: session.id).first)
        let refused = try await session.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
        await #expect(throws: (any Error).self) { try await refused.wait() }; try await refused.waitForDrain()
        #expect(await calls.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect")
        try await journal.reconcileMutation(pending, receipt: .init(operationID: pending.intent.idempotencyKey, status: .succeeded,
            confirmedTargets: [.init(namespace: "incomplete", id: "file")], revision: "1"), output: .string("written"))
        let settled = try await journal.readMessages(sessionID: session.id)
        #expect(settled.last?.message.role == .tool)
        let stale = try await session.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
        await #expect(throws: AgentJournalError.concurrentWriter) { try await stale.wait() }; try await stale.waitForDrain()
        let fresh = try agent.makeSession(id: session.id, journal: journal)
        let exit = try await fresh.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
        _ = try await exit.wait(); try await exit.waitForDrain()
        #expect(await calls.count == 1)
        #expect(try await journal.readMessages(sessionID: session.id) == settled)
        #expect(try await journal.runRecord(sessionID: session.id, runID: run.id) == terminal)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.readMessages(sessionID: session.id) == settled)
        #expect(try await reopened.runRecord(sessionID: session.id, runID: run.id) == terminal)
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func metadataRaceAtUnchangedHistoryHeadCannotPublish(_ pending: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.createForIncompleteContextHandoff(at: directory, operationDomain: "race")
        let provider = IncompleteHandoffProvider(), binding = try incompleteBinding(provider)
        let session = try Agent(binding: binding).makeSession(journal: journal)
        let run = try await session.run("unfinished"); _ = try await run.wait(); try await run.waitForDrain()
        let witness = try await journal.historyWitness(sessionID: session.id)
        let gate = IncompleteProjector()
        let target = try incompleteBinding(provider, projector: gate)
        let exit = try await session.handoffToOrdinary(using: target, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
        await gate.gate.waitEntered()
        if pending {
            let reference = EvidenceReference(namespace: "fixture", id: "pending")
            let intent = try PendingMutationIntent(call: .init(id: .init(rawValue: "pending"), name: "write", argumentsJSON: "{}", completeness: .complete),
                resources: [.named(reference)], idempotencyKey: "pending", receiptExpectation: .init(targets: [reference], revision: .present))
            _ = try await journal.appendCheckpoint([.pendingMutation(intent)], sessionID: session.id, runID: run.id, durability: .durable)
        } else {
            _ = try await journal.appendCheckpoint([.modelAttempt(turn: 99, model: binding.model)], sessionID: session.id, runID: UUID(), durability: .durable)
        }
        #expect(try await journal.historyWitness(sessionID: session.id) == witness)
        await gate.gate.release()
        await #expect(throws: AgentJournalError.invalidRecord) { try await exit.wait() }; try await exit.waitForDrain()
        #expect(try await journal.contextHandoff(sessionID: session.id) == nil)
        #expect(await provider.requests == 1)
        try await journal.close()
    }

    @Test(arguments: [false, true])
    func incompletePublicationFailurePreservesActualDurableOutcome(_ unknown: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = IncompletePublicationFault(unknown: unknown)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "fault", supportsIncompleteContextHandoff: true, fault: { try fault.check($0) })
        let provider = IncompleteHandoffProvider(), binding = try incompleteBinding(provider)
        let session = try Agent(binding: binding).makeSession(journal: journal)
        let run = try await session.run("unfinished"); _ = try await run.wait(); try await run.waitForDrain()
        let messages = try await journal.readMessages(sessionID: session.id), terminal = try await journal.runRecord(sessionID: session.id, runID: run.id)
        fault.arm()
        let exit = try await session.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
        await #expect(throws: unknown ? AgentJournalError.commitUnknown : AgentJournalError.persistenceUnavailable("incomplete handoff fault")) { try await exit.wait() }
        try await exit.waitForDrain()
        if unknown { await #expect(throws: AgentJournalError.commitUnknown) { try await session.run("not admitted") } }
        #expect(await provider.requests == 1)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.readMessages(sessionID: session.id) == messages)
        #expect(try await reopened.runRecord(sessionID: session.id, runID: run.id) == terminal)
        #expect((try await reopened.contextHandoff(sessionID: session.id) != nil) == unknown)
        try await reopened.close()
    }

    @Test(arguments: ["cancel", "deadline", "revoke"])
    func cancelledOrExpiredProjectionCannotRetireAndOwnsDrain(_ action: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.createForIncompleteContextHandoff(at: directory, operationDomain: "late-projection")
        let provider = IncompleteHandoffProvider(), binding = try incompleteBinding(provider)
        let session = try Agent(binding: binding).makeSession(journal: journal)
        let run = try await session.run("unfinished"); _ = try await run.wait(); try await run.waitForDrain()
        let gate = IncompleteProjector(), target = try incompleteBinding(provider, projector: gate)
        let scope = try await session.bindCapabilities(identity: "scope", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [])
        let exit = try await session.handoffToOrdinary(using: target, capabilities: scope, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true,
            deadline: .now.advanced(by: .seconds(action == "deadline" ? 2 : 30)))
        await gate.gate.waitEntered()
        if action == "deadline" { await #expect(throws: AgentLoopError.deadlineExceeded) { try await exit.wait() } }
        else {
            if action == "revoke" { await scope.revoke() } else { await exit.cancel() }
            await #expect(throws: CancellationError.self) { try await exit.wait() }
        }
        let other = try Agent(binding: binding).makeSession(id: session.id, journal: journal)
        await #expect(throws: AgentSessionError.runInProgress) { try await other.run("not admitted") }
        await gate.gate.release(); try await exit.waitForDrain()
        #expect(await scope.status().activeRuns == 0)
        #expect(try await journal.contextHandoff(sessionID: session.id) == nil)
        #expect(await provider.requests == 1)
        try await journal.close()
    }

    @Test(arguments: ["imported", "missing-terminal", "unmatched", "persistent"])
    func incompleteConsentCannotReplaceMissingProofOrDiscardUnclosedAuthority(_ kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "refusal", supportsIncompleteContextHandoff: true, fault: { stage in
            if kind == "missing-terminal", stage == .beforeRunTerminalPublish { throw AgentJournalError.persistenceUnavailable("missing terminal") }
        })
        let provider = IncompleteHandoffProvider(), binding = try incompleteBinding(provider), id = UUID()
        if kind == "imported" {
            _ = try await journal.appendCheckpoint([.checkpoint(history: [.user([.text("imported")]), .assistant(content: [.text("unproven")], toolCalls: [])], steeringIDs: [])], sessionID: id, durability: .durable)
        } else {
            let session = try Agent(binding: binding).makeSession(id: id, journal: journal)
            let run = try await session.run("unfinished", contextControls: .init(instructions: kind == "persistent" ? ["keep trusted instruction"] : []))
            if kind == "missing-terminal" { await #expect(throws: AgentJournalError.persistenceUnavailable("missing terminal")) { try await run.wait() } }
            else { _ = try await run.wait() }
            try await run.waitForDrain()
            if kind == "unmatched" {
                let history = await session.history + [.assistant(content: [], toolCalls: [.init(id: .init(rawValue: "unanswered"), name: "unknown", argumentsJSON: "{}", completeness: .complete)])]
                _ = try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])], sessionID: id, runID: run.id, durability: .durable)
            }
        }
        let before = try await journal.readMessages(sessionID: id)
        let fresh = try Agent(binding: binding).makeSession(id: id, journal: journal)
        let exit = try await fresh.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
        await #expect(throws: (any Error).self) { try await exit.wait() }; try await exit.waitForDrain()
        #expect(try await journal.readMessages(sessionID: id) == before)
        #expect(try await journal.contextHandoff(sessionID: id) == nil)
        #expect(await provider.requests == (kind == "imported" ? 0 : 1))
        try await journal.close()
    }

    @Test func unrelatedSessionAndMaintenanceDoNotInvalidateProof() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.createForIncompleteContextHandoff(at: directory, operationDomain: "unrelated")
        let provider = IncompleteHandoffProvider(), binding = try incompleteBinding(provider), agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("unfinished"); _ = try await run.wait(); try await run.waitForDrain()
        let gate = IncompleteProjector(), target = try incompleteBinding(provider, projector: gate)
        let exit = try await session.handoffToOrdinary(using: target, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
        await gate.gate.waitEntered()
        let unrelated = try await agent.makeSession(journal: journal).run("another Session")
        _ = try await unrelated.wait(); try await unrelated.waitForDrain()
        _ = try await journal.requestMaintenance()
        await gate.gate.release(); _ = try await exit.wait(); try await exit.waitForDrain()
        #expect(await provider.requests == 2)
        #expect(try await journal.contextHandoff(sessionID: session.id)?.closedTurnProof?.runID == run.id)
        try await journal.close()
    }

    @Test(arguments: ["model", "origin", "registry", "root"])
    func reopenedTargetMismatchRefusesBeforeAdmission(_ changed: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AgentIncrementalJournal.createForIncompleteContextHandoff(at: directory, operationDomain: "target")
        let provider = IncompleteHandoffProvider(), binding = try incompleteBinding(provider)
        let session = try Agent(binding: binding).makeSession(journal: journal)
        let run = try await session.run("unfinished"); _ = try await run.wait(); try await run.waitForDrain()
        let exit = try await session.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
        _ = try await exit.wait(); try await exit.waitForDrain()
        let messages = try await journal.readMessages(sessionID: session.id)
        try await journal.close(); journal = try AgentIncrementalJournal.open(at: directory)
        let wrong = try AgentModelBinding(profileID: "incomplete", profileRevision: "1", model: .init(provider: "incomplete", name: changed == "model" ? "another" : "model"), provider: provider,
            deployment: .init(serviceInstanceID: changed == "origin" ? "another" : "fixture", endpointScope: "local", apiDialect: "fixture"))
        let tools: [any AgentTool] = changed == "registry" ? [IncompleteReadTool()] : []
        let fresh = try Agent(binding: wrong, tools: tools, configuration: .init(instructions: changed == "root" ? "changed root" : "")).makeSession(id: session.id, journal: journal)
        await #expect(throws: AgentModelBindingError.incompatibleContinuation) { try await fresh.run("not admitted") }
        #expect(try await journal.readMessages(sessionID: session.id) == messages)
        #expect(await provider.requests == 1)
        try await journal.close()
    }
}

private actor IncompleteHandoffProvider: ModelProviderConversationControls, ModelProviderRunDrain {
    nonisolated let descriptor = ModelProviderDescriptor(id: "incomplete", capabilities: [.streaming, .multiTurn])
    nonisolated let conversationControlCapabilities: ModelConversationControlCapabilities? = .init(inlineTools: true, reminders: true)
    private(set) var requests = 0
    nonisolated let fail: Bool
    nonisolated let gate: IncompleteGate?
    init(fail: Bool = false, gate: IncompleteGate? = nil) { self.fail = fail; self.gate = gate }
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await count()
                if let gate { await gate.pause() }
                if fail { continuation.finish(throwing: ModelProviderError(kind: .transport, message: "controlled provider failure")); return }
                let info = ResponseInfo(id: UUID().uuidString, model: request.model)
                continuation.yield(.responseStarted(info))
                continuation.yield(.textDelta("partial"))
                continuation.yield(.responseCompleted(.init(info: info, content: [.text("partial")], stopReason: .maxOutputTokens)))
                continuation.finish()
            }
        }
    }
    func count() { requests += 1 }
    func waitForRunToDrain(sessionID: UUID, runID: UUID) async { await gate?.waitReleased() }
}
private actor IncompleteGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    func pause() async { await withCheckedContinuation { waiter = $0; entered = true; observers.forEach { $0.resume() }; observers.removeAll() } }
    func waitEntered() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; waiter?.resume(); waiter = nil; drainWaiters.forEach { $0.resume() }; drainWaiters.removeAll() }
    func waitReleased() async { if !released { await withCheckedContinuation { drainWaiters.append($0) } } }
}
private func incompleteBinding(_ provider: IncompleteHandoffProvider, projector: any AgentContextProjector = AgentIdentityContextProjector()) throws -> AgentModelBinding {
    try .init(profileID: "incomplete", profileRevision: "1", model: .init(provider: "incomplete", name: "model"), provider: provider,
        deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"), projector: projector)
}

private actor IncompleteExecutionCount { var count = 0; func increment() { count += 1 } }
private struct IncompleteWriteTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "incomplete_write"
    static let description = "One verified file effect"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let file: URL
    let gate: IncompleteGate
    let calls: IncompleteExecutionCount
    let policy = try! ToolPolicy.mutation(authorization: .notRequired, evidence: .none)
    func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "incomplete", id: "file"))] }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "incomplete", id: "file")], revision: .present) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        await calls.increment(); await gate.pause(); try Data("effect".utf8).write(to: file)
        return .init(output: "written", receipt: .init(operationID: context.idempotencyKey!, status: .succeeded,
            confirmedTargets: [.init(namespace: "incomplete", id: "file")], revision: "1"))
    }
}
private struct IncompleteProjector: AgentContextProjector {
    let gate = IncompleteGate()
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        await gate.pause(); return try await AgentIdentityContextProjector().project(input)
    }
}
private struct IncompleteReadTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "incomplete_read"
    static let description = "Read fixture"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired)
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> { .init(output: "read") }
}
private final class IncompletePublicationFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let unknown: Bool
    init(unknown: Bool) { self.unknown = unknown }
    func arm() { lock.withLock { armed = true } }
    func check(_ stage: JournalFileFaultStage) throws {
        let fire = lock.withLock { () -> Bool in
            guard armed, stage == (unknown ? .afterCurrentReplace : .beforeAppend) else { return false }
            armed = false; return true
        }
        if fire { throw AgentJournalError.persistenceUnavailable("incomplete handoff fault") }
    }
}
