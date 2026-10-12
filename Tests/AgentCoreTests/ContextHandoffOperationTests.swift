import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

@Suite struct ContextHandoffOperationTests {
    @Test(arguments: [false, true])
    func publicationFailureNeverInstallsFictionalRetirement(_ unknown: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = HandoffPublicationFault(unknown: unknown)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "handoff-fault",
            supportsContextHandoff: true, fault: { try fault.check($0) })
        let provider = HandoffProvider()
        let binding = try handoffBinding(provider)
        let session = try Agent(binding: binding).makeSession(journal: journal)
        let run = try await session.run("original"); _ = try await run.wait(); try await run.waitForDrain()
        let history = await session.history
        fault.arm()
        let operation = try await session.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true)
        await #expect(throws: unknown ? AgentJournalError.commitUnknown : AgentJournalError.persistenceUnavailable("handoff fault")) { try await operation.wait() }
        try await operation.waitForDrain()
        #expect(await session.history == history)
        #expect(await provider.requests == 1)
        if unknown {
            await #expect(throws: AgentJournalError.commitUnknown) { try await session.run("must not admit") }
        } else {
            #expect(try await journal.historySnapshot(sessionID: session.id).contextHandoff == nil)
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.history == history)
        #expect((try await reopened.historySnapshot(sessionID: session.id).contextHandoff != nil) == unknown)
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func lateProjectionCannotPublishAfterCancellationOrDeadline(_ deadline: Bool) async throws {
        let provider = HandoffProvider(), old = try handoffBinding(provider)
        let journal = AgentJournal()
        let session = try Agent(binding: old).makeSession(journal: journal)
        let run = try await session.run("original"); _ = try await run.wait(); try await run.waitForDrain()
        let gate = HandoffProjectionGate()
        let target = try handoffBinding(provider, projector: gate)
        let operation = try await session.handoffToOrdinary(using: target, discardingRetiredProviderContinuations: true,
            deadline: .now.advanced(by: .milliseconds(deadline ? 150 : 5_000)))
        await gate.waitEntered()
        if deadline {
            await #expect(throws: AgentLoopError.deadlineExceeded) { try await operation.wait() }
        } else {
            await operation.cancel()
            await #expect(throws: CancellationError.self) { try await operation.wait() }
        }
        let another = try Agent(binding: old).makeSession(id: session.id, journal: journal)
        await #expect(throws: AgentSessionError.runInProgress) { try await another.run("no admission") }
        #expect(try await journal.historySnapshot(sessionID: session.id).contextHandoff == nil)
        #expect(await provider.requests == 1)
        await gate.release()
        try await operation.waitForDrain()
        #expect(try await journal.historySnapshot(sessionID: session.id).contextHandoff == nil)
        let fresh = try await another.run("after physical drain"); _ = try await fresh.wait(); try await fresh.waitForDrain()
        #expect(await provider.requests == 2)
    }

    @Test func revokedCapabilityCannotBecomeNewAuthorityAndDrainsLateProjection() async throws {
        let provider = HandoffProvider(), old = try handoffBinding(provider)
        let journal = AgentJournal()
        let session = try Agent(binding: old).makeSession(journal: journal)
        let run = try await session.run("original"); _ = try await run.wait(); try await run.waitForDrain()
        let gate = HandoffProjectionGate(), target = try handoffBinding(provider, projector: gate)
        let capabilities = try await session.bindCapabilities(identity: "handoff", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [])
        let operation = try await session.handoffToOrdinary(using: target, capabilities: capabilities, discardingRetiredProviderContinuations: true)
        await gate.waitEntered()
        await capabilities.revoke()
        await #expect(throws: CancellationError.self) { try await operation.wait() }
        #expect(await capabilities.status().activeRuns == 1)
        #expect(try await journal.contextHandoff(sessionID: session.id) == nil)
        await gate.release(); try await operation.waitForDrain()
        #expect(await capabilities.status().activeRuns == 0)
        #expect(await provider.requests == 1)
        #expect(try await journal.contextHandoff(sessionID: session.id) == nil)
    }

    @Test func staleActorAndQueueOwnershipCannotRetireConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "handoff-refusal", supportsContextHandoff: true)
        let provider = HandoffProvider(), binding = try handoffBinding(provider), agent = try Agent(binding: binding)
        let old = try agent.makeSession(journal: journal)
        let first = try await old.run("one"); _ = try await first.wait(); try await first.waitForDrain()
        let fresh = try agent.makeSession(id: old.id, journal: journal)
        let second = try await fresh.run("two"); _ = try await second.wait(); try await second.waitForDrain()
        let operation = try await old.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true)
        await #expect(throws: AgentJournalError.concurrentWriter) { try await operation.wait() }
        try await operation.waitForDrain()
        let dispatch = try await fresh.startFollowUpDispatch(policy: .init(), resolver: UnusedHandoffResolver())
        await #expect(throws: AgentFollowUpError.dispatchOwned) { try await fresh.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true) }
        await dispatch.stop(); try await dispatch.waitForDrain()
        #expect(await provider.requests == 2)
        #expect(try await journal.contextHandoff(sessionID: old.id) == nil)
        #expect(try await journal.readMessages(sessionID: old.id).count == 4)
        try await journal.close()
    }

    @Test(arguments: [false, true])
    func metadataOnlyCompletionOrPendingChangeIsRecheckedInPublication(_ pending: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "handoff-cas", supportsContextHandoff: true)
        let provider = HandoffProvider(), binding = try handoffBinding(provider)
        let session = try Agent(binding: binding).makeSession(journal: journal)
        let run = try await session.run("original"); _ = try await run.wait(); try await run.waitForDrain()
        let witness = try await journal.historyWitness(sessionID: session.id)
        let gate = HandoffProjectionGate(), target = try handoffBinding(provider, projector: gate)
        let operation = try await session.handoffToOrdinary(using: target, discardingRetiredProviderContinuations: true)
        await gate.waitEntered()
        if pending {
            let reference = EvidenceReference(namespace: "fixture", id: "pending")
            let intent = try PendingMutationIntent(call: .init(id: .init(rawValue: "pending"), name: "write", argumentsJSON: "{}", completeness: .complete),
                resources: [.named(reference)], idempotencyKey: "pending-race", receiptExpectation: .init(targets: [reference], revision: .present))
            _ = try await journal.appendCheckpoint([.pendingMutation(intent)], sessionID: session.id, runID: run.id, durability: .durable)
        } else {
            _ = try await journal.appendCheckpoint([.modelAttempt(turn: 99, model: binding.model)], sessionID: session.id, runID: UUID(), durability: .durable)
        }
        #expect(try await journal.historyWitness(sessionID: session.id) == witness)
        await gate.release()
        await #expect(throws: AgentJournalError.invalidRecord) { try await operation.wait() }
        try await operation.waitForDrain()
        #expect(try await journal.contextHandoff(sessionID: session.id) == nil)
        #expect(await provider.requests == 1)
        try await journal.close()
    }

    @Test(arguments: [false, true])
    func oldStoreCapabilityRefusesBeforeProjectionOrRequest(_ native: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "old-store", supportsNativeContext: native)
        let provider = HandoffProvider(), binding = try handoffBinding(provider)
        let session = try Agent(binding: binding).makeSession(journal: journal)
        let run = try await session.run("original"); _ = try await run.wait(); try await run.waitForDrain()
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            try await session.handoffToOrdinary(using: binding, discardingRetiredProviderContinuations: true)
        }
        #expect(await provider.requests == 1)
        #expect(try await journal.contextHandoff(sessionID: session.id) == nil)
        try await journal.close()
    }

    @Test func targetBudgetFailureKeepsOriginalAuthorityAndHistory() async throws {
        let provider = HandoffProvider(), binding = try handoffBinding(provider), journal = AgentJournal()
        let session = try Agent(binding: binding).makeSession(journal: journal)
        let run = try await session.run("original"); _ = try await run.wait(); try await run.waitForDrain()
        let history = await session.history
        let target = try AgentModelBinding(profileID: "limited", profileRevision: "1", model: binding.model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            tokenBudget: .init(maximumContextTokens: 10, reservedOutputTokens: 1, estimator: HandoffOversizedEstimate()))
        let operation = try await session.handoffToOrdinary(using: target, discardingRetiredProviderContinuations: true)
        await #expect(throws: AgentModelBindingError.contextBudgetExceeded(estimatedInputTokens: 11, availableInputTokens: 9)) {
            try await operation.wait()
        }
        try await operation.waitForDrain()
        #expect(await session.history == history)
        #expect(try await journal.contextHandoff(sessionID: session.id) == nil)
        #expect(await provider.requests == 1)
    }

    @Test func retirementRejectsReencodedUnknownPayloadAndKeepsFutureThinking() throws {
        let origin = ModelProviderContinuationOrigin(providerID: "fixture", serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture", configurationRevision: "1")
        let model = ModelID(provider: "fixture", name: "model")
        let old = ModelProviderContinuation(model: model, format: "fixture", payload: Data(#"{"signature":"old"}"#.utf8), origin: origin)
        let future = ModelProviderContinuation(model: model, format: "fixture", payload: Data(#"{"signature":"future"}"#.utf8), origin: origin)
        let value = try AgentContextHandoff(generation: 1, previousHandoffID: nil, canonicalMessageCount: 2, lastMessageID: nil,
            retiredNativeCheckpointID: nil, retiredControlsDigest: "none", completedRunID: nil, targetOrigin: origin, targetRootDigest: "root", targetControls: nil)
        let canonical: [ModelMessage] = [.user([.text("old")]), .assistant(content: [.providerContinuation(old)], toolCalls: []),
            .user([.text("new")]), .assistant(content: [.providerContinuation(future)], toolCalls: [])]
        let ordinary = try value.ordinaryView(canonical)
        try value.rejectReinjection(ordinary, canonical: canonical)
        let reencoded = ModelProviderContinuation(model: model, format: old.format, payload: Data((" \n" + String(decoding: old.payload, as: UTF8.self)).utf8), origin: origin)
        #expect(throws: AgentModelBindingError.invalidProjection) {
            try value.rejectReinjection(ordinary + [.assistant(content: [.providerContinuation(reencoded)], toolCalls: [])], canonical: canonical)
        }
        #expect(throws: AgentModelBindingError.invalidProjection) {
            try value.rejectReinjection(ordinary + [.assistant(content: [.providerContinuation(future)], toolCalls: [])], canonical: canonical)
        }
        #expect(try value.ordinaryView(canonical)[3] == canonical[3])
    }
}

private actor HandoffProvider: ModelProvider {
    nonisolated let descriptor = ModelProviderDescriptor(id: "handoff", capabilities: [.streaming, .multiTurn])
    private(set) var requests = 0
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await count()
                let info = ResponseInfo(id: UUID().uuidString, model: request.model)
                continuation.yield(.responseStarted(info))
                continuation.yield(.textDelta("answer"))
                continuation.yield(.responseCompleted(.init(info: info, content: [.text("answer")], stopReason: .endTurn)))
                continuation.finish()
            }
        }
    }
    func count() { requests += 1 }
}
private func handoffBinding(_ provider: HandoffProvider, projector: any AgentContextProjector = AgentIdentityContextProjector()) throws -> AgentModelBinding {
    try .init(profileID: "handoff", profileRevision: "1", model: .init(provider: "handoff", name: "model"), provider: provider,
        deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"), projector: projector)
}
private actor HandoffProjectionGate: AgentContextProjector {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        entered = true; observers.forEach { $0.resume() }; observers.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
        return try await AgentIdentityContextProjector().project(input)
    }
    func waitEntered() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
private final class HandoffPublicationFault: @unchecked Sendable {
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
        if fire { throw AgentJournalError.persistenceUnavailable("handoff fault") }
    }
}

private struct UnusedHandoffResolver: AgentFollowUpResolver {
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration { throw AgentCapabilityError.revoked }
}

private struct HandoffOversizedEstimate: AgentContextTokenEstimator {
    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        .init(inputTokens: 11, accuracy: .exact)
    }
}
