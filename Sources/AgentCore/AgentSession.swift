import AgentModels
import AgentTools
import Foundation

/// One isolated conversation. Canonical history lives here. Only one Run may
/// be active; overlapping `run` calls fail with `runInProgress`.
///
/// History is readable and not assignable. Restoration uses the journal
/// checkpoint for conversation state. Runtime instructions always come from
/// the Agent that created this Session. Share the Agent's scheduler
/// when another Session can mutate the same host resources.
public actor AgentSession {
    public nonisolated let id: UUID
    public private(set) var history: [ModelMessage]
    public private(set) var activeRunID: UUID?
    private let defaultBinding: AgentModelBinding
    private let tools: ToolRegistry
    private let scheduler: ToolScheduler
    private let evidenceLedger = EvidenceLedger()
    private let structuredOutput: StructuredOutputSchema?
    private let maxModelTurns: Int
    private let maxToolCalls: Int
    private let runTimeout: Duration
    private let instructions: String
    private let contextPolicy: AgentContextPolicy
    private let journal: AgentJournal?
    private let checkpointDidExit: (@Sendable (UUID) -> Void)?
    private let drainWaitDidBegin: (@Sendable (UUID) -> Void)?
    private let drainReleaseDidBegin: (@Sendable (UUID) async -> Void)?
    private let startupReleaseDidFinish: (@Sendable (UUID) async -> Void)?
    private let mutationQuarantineDidBegin: (@Sendable (UUID, ToolCallID) async -> Void)?
    private var appliedSteeringIDs: Set<UUID> = []
    private var restoredJournalState = false
    private var pendingDrainTask: Task<Void, Never>?
    private var drainingRunID: UUID?
    private var drainHandles: [UUID: AgentRunDrain] = [:]
    private var loopsByRunID: [UUID: AgentLoop] = [:]
    private var startingRun = false
    private var preflightOperations: Set<UUID> = []
    private var deferredStartupReleases: Set<UUID> = []
    private var startupReservations: [UUID: StartupReservation] = [:]
    private var conversationRevision: UInt64 = 0

    private struct StartupReservation {
        let journalLeaseAcquired: Bool
    }

    init(id: UUID = UUID(), defaultBinding: AgentModelBinding, tools: ToolRegistry, scheduler: ToolScheduler,
         instructions: String, structuredOutput: StructuredOutputSchema?, maxModelTurns: Int,
         maxToolCalls: Int, runTimeout: Duration, contextPolicy: AgentContextPolicy, journal: AgentJournal? = nil,
         checkpointDidExit: (@Sendable (UUID) -> Void)? = nil,
         drainWaitDidBegin: (@Sendable (UUID) -> Void)? = nil,
         drainReleaseDidBegin: (@Sendable (UUID) async -> Void)? = nil,
        startupReleaseDidFinish: (@Sendable (UUID) async -> Void)? = nil,
        mutationQuarantineDidBegin: (@Sendable (UUID, ToolCallID) async -> Void)? = nil) {
        self.id = id
        self.defaultBinding = defaultBinding
        self.tools = tools
        self.scheduler = scheduler
        self.structuredOutput = structuredOutput
        self.instructions = instructions
        self.contextPolicy = contextPolicy
        history = AgentContextWindow.applyingCurrentInstructions([], instructions: instructions)
        self.maxModelTurns = maxModelTurns
        self.maxToolCalls = maxToolCalls
        self.runTimeout = runTimeout
        self.journal = journal
        self.checkpointDidExit = checkpointDidExit
        self.drainWaitDidBegin = drainWaitDidBegin
        self.drainReleaseDidBegin = drainReleaseDidBegin
        self.startupReleaseDidFinish = startupReleaseDidFinish
        self.mutationQuarantineDidBegin = mutationQuarantineDidBegin
    }

    /// Starts one Run. Empty input, an already-active Run, a cancelled caller
    /// and an expired budget do not append history. Mutation tools require a
    /// durable journal supplied at Session creation.
    public func run(
        _ text: String,
        budget: AgentBudget? = nil,
        operationID: String? = nil
    ) async throws -> AgentRun {
        try await run(
            text,
            using: defaultBinding,
            expectedConversationRevision: nil,
            budget: budget,
            operationID: operationID
        )
    }

    /// Starts a Run with an immutable execution target. Selection affects this
    /// Run only; the Session's canonical conversation and trusted state remain.
    public func run(
        _ text: String,
        using binding: AgentModelBinding,
        expectedConversationRevision: UInt64? = nil,
        budget: AgentBudget? = nil,
        operationID: String? = nil
    ) async throws -> AgentRun {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentSessionError.emptyInput }
        try contextPolicy.checkInput(text)
        let runBudget = try budget ?? AgentBudget(
            maxModelTurns: maxModelTurns,
            maxToolCalls: maxToolCalls,
            deadline: .now.advanced(by: runTimeout)
        )
        guard activeRunID == nil, !startingRun else { throw AgentSessionError.runInProgress }
        try runBudget.checkActive()
        startingRun = true
        let startupID = UUID()
        var identityAcquired = false
        var journalLeaseAcquired = false
        do {
            if let pendingDrainTask {
                if let drainingRunID { drainWaitDidBegin?(drainingRunID) }
                await pendingDrainTask.value
                try runBudget.checkActive()
            }
            try await AgentSessionIdentityRegistry.shared.acquire(id)
            identityAcquired = true
            do {
                if let journal {
                    do {
                        try await journal.acquireSessionLease(sessionID: id)
                    } catch AgentJournalError.sessionLeaseUnavailable {
                        throw AgentSessionError.runInProgress
                    }
                    journalLeaseAcquired = true
                }
                startupReservations[startupID] = .init(journalLeaseAcquired: journalLeaseAcquired)
                do {
                    let run = try await startRun(
                        text,
                        binding: binding,
                        expectedConversationRevision: expectedConversationRevision,
                        budget: runBudget,
                        operationID: operationID,
                        startupID: startupID
                    )
                    startupReservations.removeValue(forKey: startupID)
                    startingRun = false
                    return run
                } catch {
                    if !deferredStartupReleases.contains(startupID) {
                        await releaseStartupReservation(startupID)
                        identityAcquired = false
                        journalLeaseAcquired = false
                        startingRun = false
                    }
                    throw error
                }
            } catch {
                if !deferredStartupReleases.contains(startupID) {
                    if journalLeaseAcquired {
                        await journal?.releaseSessionLease(sessionID: id)
                        journalLeaseAcquired = false
                    }
                    if identityAcquired {
                        await AgentSessionIdentityRegistry.shared.release(id)
                        identityAcquired = false
                    }
                    startupReservations.removeValue(forKey: startupID)
                    startingRun = false
                }
                throw error
            }
        } catch {
            if !deferredStartupReleases.contains(startupID) {
                startingRun = false
            }
            throw error
        }
    }

    private func preflightDidFinish(_ startupID: UUID) async {
        preflightOperations.remove(startupID)
        guard deferredStartupReleases.contains(startupID) else { return }
        await releaseStartupReservation(startupID)
    }

    private func releaseStartupReservation(_ startupID: UUID) async {
        guard let reservation = startupReservations.removeValue(forKey: startupID) else { return }
        deferredStartupReleases.remove(startupID)
        if reservation.journalLeaseAcquired {
            await journal?.releaseSessionLease(sessionID: id)
        }
        await AgentSessionIdentityRegistry.shared.release(id)
        startingRun = false
        await startupReleaseDidFinish?(startupID)
    }

    public func conversationSnapshot() async -> AgentConversationSnapshot {
        await restoreJournalStateIfNeeded()
        return .init(revision: conversationRevision, messages: history)
    }

    /// Waits until provider/tool work for `runID` has exited and this Session
    /// identity is released. Same owner as `AgentRun.waitForDrain()`.
    public func waitForRunToDrain(runID: UUID) async {
        if let drain = drainHandles[runID] {
            _ = try? await Task { try await drain.wait() }.value
            return
        }
        if let loop = loopsByRunID[runID] {
            await loop.waitForRunToDrain(sessionID: id, runID: runID)
        }
        await finishDraining(runID: runID)
    }

    private func startRun(
        _ text: String,
        binding: AgentModelBinding,
        expectedConversationRevision: UInt64?,
        budget: AgentBudget,
        operationID: String?,
        startupID: UUID
    ) async throws -> AgentRun {
        try budget.checkActive()
        await restoreJournalStateIfNeeded()
        if let expectedConversationRevision, expectedConversationRevision != conversationRevision {
            throw AgentModelBindingError.staleConversationRevision
        }
        let prepared = try await withStartupDeadline(budget.deadline, startupID: startupID) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.prepareCheckpoint(self.history)
        }
        try budget.checkActive()
        if prepared.history != history, expectedConversationRevision != nil {
            throw AgentModelBindingError.staleConversationRevision
        }
        if let expectedConversationRevision, expectedConversationRevision != conversationRevision {
            throw AgentModelBindingError.staleConversationRevision
        }
        let candidateRevision: UInt64?
        if history == prepared.history {
            candidateRevision = nextConversationRevision
        } else if conversationRevision < .max {
            candidateRevision = conversationRevision + 1
        } else {
            candidateRevision = nil
        }
        guard let candidateRevision else {
            throw AgentModelBindingError.staleConversationRevision
        }
        let runID = UUID()
        let loop = AgentLoop(binding: binding, tools: tools, scheduler: scheduler)
        let candidateMessages = prepared.history + [.user([.text(text)])]
        let preparedRequest: AgentPreparedModelRequest
        preparedRequest = try await withStartupDeadline(budget.deadline, startupID: startupID) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await loop.preflight(
                messages: candidateMessages,
                sessionID: self.id,
                runID: runID,
                conversationRevision: candidateRevision,
                structuredOutput: self.structuredOutput
            )
        }
        try Task.checkCancellation()
        try budget.checkActive()
        if let journal {
            _ = try await journal.recoverPendingMutations(sessionID: id)
            try Task.checkCancellation()
            try budget.checkActive()
            let hasSessionRecord = await journal.snapshot().contains { record in
                guard record.sessionID == id else { return false }
                if case .sessionCreated = record.event { return true }
                return false
            }
            var lifecycleEvents: [AgentJournalEvent] = hasSessionRecord ? [] : [.sessionCreated]
            if let summary = prepared.summary {
                lifecycleEvents.append(.compaction(summary))
                lifecycleEvents.append(.checkpoint(history: prepared.history, steeringIDs: Array(appliedSteeringIDs)))
            }
            lifecycleEvents.append(.userMessage(text))
            try Task.checkCancellation()
            try budget.checkActive()
            try await journal.appendCheckpoint(
                lifecycleEvents,
                sessionID: id,
                runID: runID,
                durability: journal.storage == .durable ? .durable : .memory
            )
            // The durable startup frame is the admission boundary. Once the
            // append begins, cancellation/deadline cannot roll back an
            // atomic journal commit; continue creating the corresponding Run
            // rather than leaving a durable user event without an owner.
        }
        let control = AgentRunControl()
        let channel = AsyncStream<AgentEvent>.makeStream()
        let emitter = AgentEventEmitter(channel.continuation, requiresConsumer: false)
        if history != prepared.history { history = prepared.history }
        history.append(.user([.text(text)]))
        conversationRevision = candidateRevision
        activeRunID = runID
        appliedSteeringIDs.removeAll()
        let drain = AgentRunDrain()
        drainHandles[runID] = drain
        loopsByRunID[runID] = loop
        let messages = history
        Task {
            await control.start {
                await self.perform(
                    messages,
                    loop: loop,
                    initialRequest: preparedRequest,
                    runID: runID,
                    operationID: operationID,
                    budget: budget,
                    emitter: emitter,
                    control: control
                )
            }
        }
        return AgentRun(
            id: runID,
            sessionID: id,
            binding: binding.info,
            events: channel.stream,
            control: control,
            drain: drain
        )
    }
    private func perform(_ messages: [ModelMessage], loop: AgentLoop, initialRequest: AgentPreparedModelRequest,
                         runID: UUID, operationID: String?, budget: AgentBudget,
                         emitter: AgentEventEmitter, control: AgentRunControl) async -> Result<AgentLoopResult, Error> {
        let journal = self.journal
        let lifecycle = AgentLoopLifecycle(
            control: control,
            evidenceLedger: evidenceLedger,
            mutationAdmission: journal,
            checkpoint: { messages, steering in try await self.record(messages, steering: steering, runID: runID, budget: budget) },
            recordMutationReceipt: { callID, receipt, output in
                try await journal?.settleMutation(
                    sessionID: self.id, runID: runID, callID: callID, receipt: receipt, output: output
                )
            },
            commitMutation: { callID, receipt, output, messages, steering in
                guard let journal else {
                    throw AgentJournalError.persistenceUnavailable("mutation history cannot be committed without a journal")
                }
                let prepared = try await self.prepareCheckpoint(messages)
                if let summary = prepared.summary {
                    try await journal.append(
                        .compaction(summary),
                        sessionID: self.id,
                        runID: runID,
                        durability: journal.storage == .durable ? .durable : .memory
                    )
                }
                try await journal.commitMutation(
                    sessionID: self.id,
                    runID: runID,
                    callID: callID,
                    receipt: receipt,
                    output: output,
                    history: prepared.history,
                    steeringIDs: steering.map(\.id)
                )
                _ = try? await journal.compactIfNeeded()
                await self.applyCommittedHistory(prepared.history, steering: steering, runID: runID)
                return prepared.history
            },
            markMutationNeedsReconciliation: { callID in
                await self.mutationQuarantineDidBegin?(runID, callID)
                try await journal?.markMutationNeedsReconciliation(sessionID: self.id, runID: runID, callID: callID)
            },
            beforeFinish: {
                let pending = await control.beginFinish()
                await self.finish(runID: runID, pending: pending, control: control)
            }
        )
        do {
            let result = try await loop.execute(messages: messages, sessionID: id, runID: runID, budget: budget,
                                                structuredOutput: structuredOutput, operationID: operationID,
                                                emitter: emitter, lifecycle: lifecycle,
                                                initialRequest: initialRequest)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func record(_ messages: [ModelMessage], steering: [AgentSteeringInput], runID: UUID, budget: AgentBudget) async throws -> [ModelMessage] {
        do {
            try budget.checkActive()
            guard activeRunID == runID else { throw CancellationError() }
            let prepared = try await prepareCheckpoint(messages)
            try budget.checkActive()
            guard activeRunID == runID else { throw CancellationError() }
            if let journal {
                var events: [AgentJournalEvent] = []
                if let summary = prepared.summary {
                    events.append(.compaction(summary))
                }
                events.append(.checkpoint(history: prepared.history, steeringIDs: steering.map(\.id)))
                try await journal.appendCheckpointForCurrentRun(
                    events,
                    sessionID: id,
                    runID: runID,
                    durability: journal.storage == .durable ? .durable : .memory
                )
                _ = try? await journal.compactIfNeeded()
            }
            try budget.checkActive()
            guard activeRunID == runID else { throw CancellationError() }
            if history != prepared.history { advanceConversationRevision() }
            history = prepared.history
            appliedSteeringIDs.formUnion(steering.map(\.id))
            checkpointDidExit?(runID)
            return prepared.history
        } catch {
            checkpointDidExit?(runID)
            throw error
        }
    }

    private func applyCommittedHistory(_ messages: [ModelMessage], steering: [AgentSteeringInput], runID: UUID) {
        guard activeRunID == runID else { return }
        if history != messages { advanceConversationRevision() }
        history = messages
        appliedSteeringIDs.formUnion(steering.map(\.id))
    }

    private func finish(runID: UUID, pending: [AgentSteeringInput], control: AgentRunControl) async {
        guard activeRunID == runID else { return }
        for input in pending where !appliedSteeringIDs.contains(input.id) {
            history.append(.user([.text(input.text)]))
            advanceConversationRevision()
        }
        activeRunID = nil
        appliedSteeringIDs.removeAll()
        drainingRunID = runID
        let sessionID = id
        let loop = loopsByRunID[runID]
        let journal = self.journal
        let drain = drainHandles[runID]
        pendingDrainTask = Task { [weak self] in
            async let logicalCompletion: Void = control.waitUntilCompleted()
            async let physicalCompletion: Void = loop?.waitForRunToDrain(sessionID: sessionID, runID: runID) ?? ()
            await logicalCompletion
            await physicalCompletion
            if let self {
                await self.finishDraining(runID: runID)
            } else {
                await drain?.complete()
                await journal?.releaseSessionLease(sessionID: sessionID)
                await AgentSessionIdentityRegistry.shared.release(sessionID)
            }
        }
    }

    private func finishDraining(runID: UUID) async {
        guard drainingRunID == runID else { return }
        await drainReleaseDidBegin?(runID)
        await journal?.releaseSessionLease(sessionID: id)
        await AgentSessionIdentityRegistry.shared.release(id)
        if let drain = drainHandles[runID] {
            await drain.complete()
        }
        drainHandles.removeValue(forKey: runID)
        loopsByRunID.removeValue(forKey: runID)
        drainingRunID = nil
        pendingDrainTask = nil
    }

    private func restoreJournalStateIfNeeded() async {
        guard !restoredJournalState else { return }
        restoredJournalState = true
        guard let journal,
              let checkpoint = await journal.latestCheckpoint(sessionID: id) else { return }
        // Checkpoint system/developer messages are a historical record of the
        // runtime configuration that was sent, not the active configuration.
        let restored = AgentContextWindow.applyingCurrentInstructions(checkpoint.history, instructions: instructions)
        if restored != history { advanceConversationRevision() }
        history = restored
    }

    private func withStartupDeadline<Value: Sendable>(
        _ deadline: ContinuousClock.Instant,
        startupID: UUID,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        preflightOperations.insert(startupID)
        do {
            return try await withAgentDeadline(
                deadline,
                operation: operation,
                onOperationFinished: { [self] in
                    await self.preflightDidFinish(startupID)
                }
            )
        } catch {
            if preflightOperations.contains(startupID) {
                deferredStartupReleases.insert(startupID)
            }
            throw error
        }
    }

    private var nextConversationRevision: UInt64? {
        conversationRevision == .max ? nil : conversationRevision + 1
    }

    private func advanceConversationRevision() {
        if conversationRevision < .max { conversationRevision += 1 }
    }

    private func prepareCheckpoint(_ messages: [ModelMessage]) async throws -> (history: [ModelMessage], summary: AgentCompactionSummary?) {
        let aligned = AgentContextWindow.applyingCurrentInstructions(messages, instructions: instructions)
        let bytes = try AgentContextWindow.encodedByteCount(aligned)
        let limit = min(contextPolicy.maxActiveHistoryUTF8Bytes, AgentJournal.maximumFrameSize)
        if bytes <= limit {
            return (aligned, nil)
        }
        guard let compactor = contextPolicy.compactor else {
            throw AgentContextError.historyTooLarge(bytes: bytes, limit: limit)
        }
        let split = AgentContextWindow.split(aligned, retainingRecentTurns: contextPolicy.retainedRecentTurnCount)
        guard !split.dropped.isEmpty else {
            throw AgentContextError.historyTooLarge(bytes: bytes, limit: limit)
        }
        let summary = try await compactor.summarize(droppedConversation: split.dropped)
        var compacted = split.runtime
        compacted.append(AgentContextWindow.summaryMessage(summary))
        compacted.append(contentsOf: split.retained)
        compacted = AgentContextWindow.applyingCurrentInstructions(compacted, instructions: instructions)
        let compactedBytes = try AgentContextWindow.encodedByteCount(compacted)
        guard compactedBytes <= limit else {
            throw AgentContextError.historyTooLarge(bytes: compactedBytes, limit: limit)
        }
        return (compacted, summary)
    }
}

private actor AgentSessionIdentityRegistry {
    static let shared = AgentSessionIdentityRegistry()
    private var activeSessionIDs: Set<UUID> = []

    func acquire(_ id: UUID) throws {
        guard activeSessionIDs.insert(id).inserted else { throw AgentSessionError.runInProgress }
    }

    func release(_ id: UUID) {
        activeSessionIDs.remove(id)
    }
}

public enum AgentSessionError: Error, Equatable, Sendable {
    case emptyInput
    case runInProgress
    case durableJournalRequired
}
