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
    private let instanceID = UUID()
    private let scheduler: ToolScheduler
    private let evidenceLedger = EvidenceLedger()
    private let contextEffects = AgentContextEffectLedger()
    private let structuredOutput: StructuredOutputSchema?
    private let maxModelTurns: Int
    private let maxToolCalls: Int
    private let runTimeout: Duration
    private let instructions: String
    private let contextPolicy: AgentContextPolicy
    private let preAdmissionReplanning: AgentPreAdmissionReplanning
    private let journal: AgentJournal?
    private let checkpointDidExit: (@Sendable (UUID) -> Void)?
    private let drainWaitDidBegin: (@Sendable (UUID) -> Void)?
    private let drainReleaseDidBegin: (@Sendable (UUID) async -> Void)?
    private let scopeReleaseDidFinish: (@Sendable (UUID) async -> Void)?
    private let startupCommitWillBegin: (@Sendable (UUID) async -> Void)?
    private let runWorkerWillStart: (@Sendable (UUID) async -> Void)?
    private let startupReleaseDidFinish: (@Sendable (UUID) async -> Void)?
    private let mutationQuarantineDidBegin: (@Sendable (UUID, ToolCallID) async -> Void)?
    private var appliedSteeringIDs: Set<UUID> = []
    private var restoredJournalState = false
    private var pendingDrainTask: Task<Void, Never>?
    private var drainingRunID: UUID?
    private var drainHandles: [UUID: AgentRunDrain] = [:]
    private var runsByRunID: [UUID: AgentRun] = [:]
    private var loopsByRunID: [UUID: AgentLoop] = [:]
    private var startingRun = false
    private var dispatchStarting = false
    private var dispatcherID: UUID?
    private var dispatcher: AgentFollowUpDispatcher?
    private var startupWaiters: [CheckedContinuation<Void, Never>] = []
    private var preflightOperations: Set<UUID> = []
    private var deferredStartupReleases: Set<UUID> = []
    private var startupReservations: [UUID: StartupReservation] = [:]
    private var scopesByRunID: [UUID: AgentCapabilityScope] = [:]
    private var conversationRevision: UInt64 = 0

    private struct StartupReservation {
        let journalLeaseAcquired: Bool
        var capabilityScope: AgentCapabilityScope? = nil
        var runID: UUID? = nil
    }

    init(id: UUID = UUID(), defaultBinding: AgentModelBinding, tools: ToolRegistry, scheduler: ToolScheduler,
         instructions: String, structuredOutput: StructuredOutputSchema?, maxModelTurns: Int,
         maxToolCalls: Int, runTimeout: Duration, contextPolicy: AgentContextPolicy, journal: AgentJournal? = nil,
         preAdmissionReplanning: AgentPreAdmissionReplanning = .disabled,
         checkpointDidExit: (@Sendable (UUID) -> Void)? = nil,
         drainWaitDidBegin: (@Sendable (UUID) -> Void)? = nil,
         drainReleaseDidBegin: (@Sendable (UUID) async -> Void)? = nil,
         scopeReleaseDidFinish: (@Sendable (UUID) async -> Void)? = nil,
         startupCommitWillBegin: (@Sendable (UUID) async -> Void)? = nil,
         runWorkerWillStart: (@Sendable (UUID) async -> Void)? = nil,
        startupReleaseDidFinish: (@Sendable (UUID) async -> Void)? = nil,
        mutationQuarantineDidBegin: (@Sendable (UUID, ToolCallID) async -> Void)? = nil) {
        self.id = id
        self.defaultBinding = defaultBinding
        self.tools = tools
        self.scheduler = scheduler
        self.structuredOutput = structuredOutput
        self.instructions = instructions
        self.contextPolicy = contextPolicy
        self.preAdmissionReplanning = preAdmissionReplanning
        history = AgentContextWindow.applyingCurrentInstructions([], instructions: instructions)
        self.maxModelTurns = maxModelTurns
        self.maxToolCalls = maxToolCalls
        self.runTimeout = runTimeout
        self.journal = journal
        self.checkpointDidExit = checkpointDidExit
        self.drainWaitDidBegin = drainWaitDidBegin
        self.drainReleaseDidBegin = drainReleaseDidBegin
        self.scopeReleaseDidFinish = scopeReleaseDidFinish
        self.startupCommitWillBegin = startupCommitWillBegin
        self.runWorkerWillStart = runWorkerWillStart
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
        try await runInternal(text, using: binding, capabilities: nil,
                              expectedConversationRevision: expectedConversationRevision,
                              budget: budget, operationID: operationID)
    }

    /// Runs with a fixed tool/backend/resource snapshot. An explicit binding
    /// may select a model, but it cannot replace this Run's tool registry.
    public func run(
        _ text: String,
        capabilities: AgentCapabilityBinding,
        using binding: AgentModelBinding? = nil,
        expectedConversationRevision: UInt64? = nil,
        budget: AgentBudget? = nil,
        operationID: String? = nil
    ) async throws -> AgentRun {
        try await runInternal(text, using: binding ?? defaultBinding, capabilities: capabilities,
                              expectedConversationRevision: expectedConversationRevision,
                              budget: budget, operationID: operationID)
    }

    public func bindCapabilities(identity: String, version: String,
                                 scopeID: String? = nil, backendInstanceID: String,
                                 backendVersion: String, allowedResources: [ToolResource],
                                 tools: [AgentCapabilityTool]) throws -> AgentCapabilityBinding {
        try AgentCapabilityBinding(sessionID: id, sessionInstanceID: instanceID,
                                   identity: identity, version: version, scopeID: scopeID,
                                   backendInstanceID: backendInstanceID,
                                   backendVersion: backendVersion, allowedResources: allowedResources,
                                   tools: tools)
    }

    private func runInternal(
        _ text: String,
        using binding: AgentModelBinding,
        capabilities: AgentCapabilityBinding?,
        expectedConversationRevision: UInt64?,
        budget: AgentBudget?,
        operationID: String?,
        dispatchOwnerID: UUID? = nil,
        followUpInputID: String? = nil
    ) async throws -> AgentRun {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentSessionError.emptyInput }
        try contextPolicy.checkInput(text)
        let runBudget = try budget ?? AgentBudget(
            maxModelTurns: maxModelTurns,
            maxToolCalls: maxToolCalls,
            deadline: .now.advanced(by: runTimeout)
        )
        if dispatchStarting || (dispatcherID != nil && dispatcherID != dispatchOwnerID) {
            throw AgentFollowUpError.dispatchOwned
        }
        guard activeRunID == nil, !startingRun else { throw AgentSessionError.runInProgress }
        try runBudget.checkActive()
        startingRun = true
        let startupID = UUID()
        var identityAcquired = false
        var journalLeaseAcquired = false
        do {
            if let pendingDrainTask {
                if let drainingRunID { drainWaitDidBegin?(drainingRunID) }
                try await withAgentDeadline(
                    runBudget.deadline,
                    operation: { await pendingDrainTask.value }
                )
                try runBudget.checkActive()
            }
            try await AgentSessionIdentityRegistry.shared.acquire(id, storeID: await journal?.storeIdentity()?.storeID)
            identityAcquired = true
            do {
                if let journal {
                    do {
                        try await journal.acquireSessionLease(sessionID: id, dispatcherID: dispatchOwnerID)
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
                        capabilities: capabilities,
                        expectedConversationRevision: expectedConversationRevision,
                        budget: runBudget,
                        operationID: operationID,
                        startupID: startupID,
                        followUpInputID: followUpInputID
                    )
                    startupReservations.removeValue(forKey: startupID)
                    startupFinished()
                    return run
                } catch {
                    if !deferredStartupReleases.contains(startupID) {
                        await releaseStartupReservation(startupID)
                        identityAcquired = false
                        journalLeaseAcquired = false
                        startupFinished()
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
                        await AgentSessionIdentityRegistry.shared.release(id, storeID: await journal?.storeIdentity()?.storeID)
                        identityAcquired = false
                    }
                    startupReservations.removeValue(forKey: startupID)
                    startupFinished()
                }
                throw error
            }
        } catch {
            if !deferredStartupReleases.contains(startupID) {
                startupFinished()
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
        await AgentSessionIdentityRegistry.shared.release(id, storeID: await journal?.storeIdentity()?.storeID)
        startupFinished()
        await startupReleaseDidFinish?(startupID)
        if let scope = reservation.capabilityScope, let runID = reservation.runID {
            await scope.releaseRun(runID)
            await scopeReleaseDidFinish?(runID)
        }
    }

    public func conversationSnapshot() async throws -> AgentConversationSnapshot {
        try await restoreJournalStateIfNeeded()
        return .init(revision: conversationRevision, messages: history)
    }

    /// Receives a future input without changing the current Run or formal
    /// conversation. The durable store, not this actor's memory, confirms it.
    public func enqueueFollowUp(_ input: AgentFollowUpInput) async throws -> AgentFollowUpRecord {
        guard let journal, journal.storage == .durable else { throw AgentFollowUpError.durableJournalRequired }
        return try await journal.enqueueFollowUp(input, sessionID: id)
    }

    public func followUp(inputID: String) async throws -> AgentFollowUpRecord? {
        guard let journal, journal.storage == .durable else { throw AgentFollowUpError.durableJournalRequired }
        return try await journal.followUp(sessionID: id, inputID: inputID)
    }

    public func followUpText(inputID: String) async throws -> String {
        guard let journal, journal.storage == .durable else { throw AgentFollowUpError.durableJournalRequired }
        return try await journal.followUpText(sessionID: id, inputID: inputID)
    }

    public func followUps(after ordinal: UInt64? = nil, limit: Int = 100) async throws -> [AgentFollowUpRecord] {
        guard let journal, journal.storage == .durable else { throw AgentFollowUpError.durableJournalRequired }
        return try await journal.followUps(sessionID: id, after: ordinal, limit: limit)
    }

    public func withdrawFollowUp(inputID: String) async throws -> AgentFollowUpWithdrawal {
        guard let journal, journal.storage == .durable else { throw AgentFollowUpError.durableJournalRequired }
        return try await journal.withdrawFollowUp(sessionID: id, inputID: inputID)
    }

    /// Starts one explicit FIFO consumer. A paused consumer still owns this
    /// Session; stopping and physical drain release that ownership.
    public func startFollowUpDispatch(policy: AgentFollowUpDispatchPolicy,
                                      resolver: any AgentFollowUpResolver,
                                      onRun: (@Sendable (AgentFollowUpRecord, AgentRun) async -> Void)? = nil
    ) async throws -> AgentFollowUpDispatcher {
        guard let journal, journal.storage == .durable else { throw AgentFollowUpError.durableJournalRequired }
        guard !dispatchStarting, dispatcherID == nil else { throw AgentFollowUpError.alreadyDispatching }
        guard !startingRun else { throw AgentSessionError.runInProgress }
        try policy.validate()
        dispatchStarting = true
        defer { dispatchStarting = false }
        let ownerID = UUID()
        let priorRun = (activeRunID ?? drainingRunID).flatMap { runsByRunID[$0] }
        let handle = AgentFollowUpDispatcher(session: self, journal: journal, sessionID: id,
                                             ownerID: ownerID, policy: policy, resolver: resolver,
                                             initialRun: priorRun, onRun: onRun)
        try await journal.acquireDispatcherLease(sessionID: id, owner: ownerID,
                                                 allowExistingRun: priorRun != nil,
                                                 notify: { await handle.signal() })
        dispatcherID = ownerID
        dispatcher = handle
        await handle.start()
        return handle
    }

    package func startQueuedFollowUp(_ input: JournalStoredFollowUp,
                                     using configuration: AgentFollowUpConfiguration,
                                     ownerID: UUID, budget: AgentBudget) async throws -> AgentRun {
        guard dispatcherID == ownerID else { throw AgentFollowUpError.staleDispatch }
        return try await runInternal(input.input.text, using: configuration.model,
            capabilities: configuration.capabilities,
            expectedConversationRevision: configuration.expectedConversationRevision,
            budget: budget, operationID: input.input.operationID,
            dispatchOwnerID: ownerID, followUpInputID: input.input.inputID)
    }

    package func waitForQueuedStartupExit(ownerID: UUID) async {
        guard dispatcherID == ownerID, startingRun else { return }
        await withCheckedContinuation { startupWaiters.append($0) }
    }

    package func followUpDispatcherDidStop(ownerID: UUID) {
        guard dispatcherID == ownerID else { return }
        dispatcherID = nil
        dispatcher = nil
    }

    private func startupFinished() {
        startingRun = false
        let waiters = startupWaiters
        startupWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Anchors a closed range to actual Journal message IDs. The caller can
    /// derive a request-only summary; no conversation or ledger write occurs.
    public func contextHistorySpan(start: Int, count: Int) async throws -> AgentContextHistorySpan {
        try await restoreJournalStateIfNeeded()
        guard let journal, start >= 0, count > 0, count <= 256,
              start <= Int.max - count else { throw AgentContextPipelineError.unsafeSummary }
        let formal = history.filter { $0.role != .system && $0.role != .developer }
        guard start + count <= formal.count else { throw AgentContextPipelineError.unsafeSummary }
        let page = try await journal.readMessages(sessionID: id, after: UInt64(start), limit: count)
        let expected = Array(formal[start..<(start + count)])
        guard page.count == count, page.map(\.message) == expected else {
            throw AgentContextPipelineError.staleSummary
        }
        return .init(sessionID: id, start: start, messageIDs: page.map(\.id),
                     sourceDigest: try AgentContextProjectionSource.digest(messages: expected))
    }

    /// Selects a committed successful result from a registered read-only tool.
    /// A projection may shorten its model view; the Journal result stays whole.
    public func contextToolExcerpt(callID: ToolCallID, text: String) async throws -> AgentContextToolExcerpt {
        try await restoreJournalStateIfNeeded()
        let formal = history.filter { $0.role != .system && $0.role != .developer }
        guard let index = formal.firstIndex(where: {
            if case .tool(let result) = $0 { return result.callID == callID }
            return false
        }), case .tool(let result) = formal[index], !result.isError,
              let assistant = formal[..<index].lastIndex(where: { $0.role == .assistant }),
              case .assistant(_, let calls) = formal[assistant],
              let call = calls.first(where: { $0.id == callID }),
              let journal else {
            throw AgentContextPipelineError.unsafeToolExcerpt
        }
        let page = try await journal.readMessages(sessionID: id, after: UInt64(index), limit: 1)
        guard page.count == 1, page[0].message == formal[index] else {
            throw AgentContextPipelineError.staleToolExcerpt
        }
        let digest = try AgentContextProjectionSource.digest(messages: [formal[index]])
        guard await contextEffects.proof(for: callID) == .init(toolName: call.name, sourceDigest: digest) else {
            throw AgentContextPipelineError.unsafeToolExcerpt
        }
        return .init(callID: callID, messageID: page[0].id,
                     sourceDigest: digest, text: text)
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
        capabilities: AgentCapabilityBinding?,
        expectedConversationRevision: UInt64?,
        budget: AgentBudget,
        operationID: String?,
        startupID: UUID,
        followUpInputID: String? = nil
    ) async throws -> AgentRun {
        try budget.checkActive()
        let restoredCheckpoint: (history: [ModelMessage], steeringIDs: [UUID])?
        if restoredJournalState {
            restoredCheckpoint = nil
        } else {
            let journal = self.journal
            let sessionID = id
            restoredCheckpoint = try await withStartupDeadline(budget.deadline, startupID: startupID) {
                try await journal?.latestCheckpoint(sessionID: sessionID)
            }
            try budget.checkActive()
            applyRestoredJournalState(restoredCheckpoint)
        }
        if let expectedConversationRevision, expectedConversationRevision != conversationRevision {
            throw AgentModelBindingError.staleConversationRevision
        }
        let prepared = try await withStartupDeadline(budget.deadline, startupID: startupID) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.prepareCheckpoint(self.history)
        }
        try budget.checkActive()
        if prepared != history, expectedConversationRevision != nil {
            throw AgentModelBindingError.staleConversationRevision
        }
        if let expectedConversationRevision, expectedConversationRevision != conversationRevision {
            throw AgentModelBindingError.staleConversationRevision
        }
        let candidateRevision: UInt64?
        if history == prepared {
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
        let control = AgentRunControl()
        let selectedTools = capabilities?.registry ?? tools
        if selectedTools.hasMutation, journal?.storage != .durable {
            throw AgentSessionError.durableJournalRequired
        }
        if case .evidenceRejection(let names) = preAdmissionReplanning,
           selectedTools.hasMutation(named: names),
           journal?.supportsAdmissionRejections != true {
            throw AgentSessionError.admissionRejectionJournalRequired
        }
        if let capabilities {
            try await capabilities.scope.register(runID: runID, sessionID: id,
                                                   sessionInstanceID: instanceID,
                                                   cancel: { await control.cancel() })
            startupReservations[startupID]?.capabilityScope = capabilities.scope
            startupReservations[startupID]?.runID = runID
        }
        let loop = AgentLoop(binding: binding, tools: selectedTools, scheduler: scheduler,
                             modelContextByteLimit: contextPolicy.maxModelContextUTF8Bytes,
                             journal: journal, contextEffects: contextEffects,
                             capabilityScope: capabilities?.scope,
                             allowedResources: capabilities?.allowedResources,
                             preAdmissionReplanning: preAdmissionReplanning)
        let candidateMessages = prepared + [.user([.text(text)])]
        let preparedRequest: AgentPreparedModelRequest
        preparedRequest = try await withStartupDeadline(budget.deadline, startupID: startupID,
                                                         control: control) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await loop.preflight(
                messages: candidateMessages,
                sessionID: self.id,
                runID: runID,
                conversationRevision: candidateRevision,
                structuredOutput: self.structuredOutput
            )
        }
        try await capabilities?.scope.checkRun(runID)
        try Task.checkCancellation()
        try budget.checkActive()
        var uncertainStartup = false
        if let journal {
            let sessionID = id
            _ = try await withStartupDeadline(budget.deadline, startupID: startupID,
                                               control: control) {
                try await journal.recoverPendingMutations(sessionID: sessionID)
            }
            try await capabilities?.scope.checkRun(runID)
            try Task.checkCancellation()
            try budget.checkActive()
            let hasSessionRecord = try await journal.hasSessionCreated(id)
            var lifecycleEvents: [AgentJournalEvent] = hasSessionRecord ? [] : [.sessionCreated]
            // The startup frame is also the first recoverable checkpoint. If
            // the admitted Run fails before its first loop checkpoint, a
            // replacement Session must still recover the committed input.
            lifecycleEvents.append(.checkpoint(
                history: candidateMessages,
                steeringIDs: Array(appliedSteeringIDs)
            ))
            lifecycleEvents.append(.userMessage(text))
            await startupCommitWillBegin?(runID)
            try Task.checkCancellation()
            try budget.checkActive()
            try await capabilities?.scope.checkRun(runID)
            do {
                try await journal.appendStartupCheckpoint(
                    lifecycleEvents,
                    sessionID: id,
                    runID: runID,
                    deadline: budget.deadline,
                    durability: journal.storage == .durable ? .durable : .memory,
                    followUpInputID: followUpInputID
                )
            } catch AgentJournalStartupAdmissionError.deadlineExceeded {
                throw AgentLoopError.deadlineExceeded
            } catch AgentJournalError.commitUnknown {
                // The frame may be visible. Retain a Run owner through drain,
                // but never enter the provider or a mutation executor.
                uncertainStartup = true
            } catch {
                throw error
            }
            // The durable startup frame is the admission boundary. Once the
            // append begins, cancellation/deadline cannot roll back an
            // atomic journal commit; continue creating the corresponding Run
            // rather than leaving a durable user event without an owner.
        }
        // A slow Host observer must not accumulate an unbounded queue of
        // transient progress while the durable conversation continues.
        let channel = AsyncStream<AgentEvent>.makeStream(bufferingPolicy:
            followUpInputID == nil ? .unbounded : .bufferingNewest(256))
        let emitter = AgentEventEmitter(channel.continuation, requiresConsumer: false)
        if history != prepared { history = prepared }
        history.append(.user([.text(text)]))
        conversationRevision = candidateRevision
        activeRunID = runID
        appliedSteeringIDs.removeAll()
        let drain = AgentRunDrain()
        drainHandles[runID] = drain
        loopsByRunID[runID] = loop
        if let capabilities { scopesByRunID[runID] = capabilities.scope }
        let messages = history
        let startupIsUncertain = uncertainStartup
        await runWorkerWillStart?(runID)
        Task {
            await control.start {
                if startupIsUncertain {
                    await emitter.start(.init(sessionID: self.id, runID: runID, model: binding.model))
                    await self.finish(runID: runID, pending: [], control: control)
                    await emitter.finish(.failed(.journal(.commitUnknown)))
                    return .failure(AgentJournalError.commitUnknown)
                }
                return await self.perform(
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
        let run = AgentRun(
            id: runID,
            sessionID: id,
            binding: binding.info,
            capabilities: capabilities?.info.forRun(runID),
            events: channel.stream,
            control: control,
            drain: drain
        )
        runsByRunID[runID] = run
        return run
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
            checkReplanningSafety: { operationID in
                guard let journal, journal.storage == .durable else { return false }
                return try await !journal.hasRelatedPendingMutation(sessionID: self.id, operationID: operationID)
            },
            recordAdmissionRejection: { rejection, messages in
                try await self.record(messages, steering: [], runID: runID, budget: budget,
                                      rejection: rejection)
            },
            recordMutationReceipt: { _, _, _ in
                throw AgentJournalError.mutationSettlementRequiresReconciliation
            },
            commitMutation: { callID, receipt, output, messages, steering in
                guard let journal else {
                    throw AgentJournalError.persistenceUnavailable("mutation history cannot be committed without a journal")
                }
                let prepared = try await self.prepareCheckpoint(messages)
                try await journal.commitMutation(
                    sessionID: self.id,
                    runID: runID,
                    callID: callID,
                    receipt: receipt,
                    output: output,
                    history: prepared,
                    steeringIDs: steering.map(\.id)
                )
                await self.applyCommittedHistory(prepared, steering: steering, runID: runID)
                return prepared
            },
            markMutationNeedsReconciliation: { callID in
                await self.mutationQuarantineDidBegin?(runID, callID)
                try await journal?.markMutationNeedsReconciliation(sessionID: self.id, runID: runID, callID: callID)
            },
            recordReadOnlyResult: { call, result in
                guard await self.activeRunID == runID else { return }
                await self.contextEffects.record(call: call, result: result)
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

    private func record(_ messages: [ModelMessage], steering: [AgentSteeringInput], runID: UUID,
                        budget: AgentBudget, rejection: ToolPreAdmissionRejection? = nil) async throws -> [ModelMessage] {
        do {
            try budget.checkActive()
            guard activeRunID == runID else { throw CancellationError() }
            let prepared = try await prepareCheckpoint(messages)
            try budget.checkActive()
            guard activeRunID == runID else { throw CancellationError() }
            if let journal {
                var events: [AgentJournalEvent] = []
                if let rejection {
                    guard rejection.sessionID == id, rejection.runID == runID else { throw CancellationError() }
                    events.append(.toolAdmissionRejected(callID: rejection.callID,
                        name: rejection.toolName))
                }
                events.append(.checkpoint(history: prepared, steeringIDs: steering.map(\.id)))
                try await journal.appendCheckpointForCurrentRun(
                    events,
                    sessionID: id,
                    runID: runID,
                    durability: journal.storage == .durable ? .durable : .memory
                )
            }
            try budget.checkActive()
            guard activeRunID == runID else { throw CancellationError() }
            if history != prepared { advanceConversationRevision() }
            history = prepared
            appliedSteeringIDs.formUnion(steering.map(\.id))
            checkpointDidExit?(runID)
            return prepared
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
        let scope = scopesByRunID[runID]
        let drainReleaseDidBegin = self.drainReleaseDidBegin
        let scopeReleaseDidFinish = self.scopeReleaseDidFinish
        pendingDrainTask = Task { [weak self] in
            async let logicalCompletion: Void = control.waitUntilCompleted()
            async let physicalCompletion: Void = loop?.waitForRunToDrain(sessionID: sessionID, runID: runID) ?? ()
            await logicalCompletion
            await physicalCompletion
            if let self {
                await self.finishDraining(runID: runID)
            } else {
                await drainReleaseDidBegin?(runID)
                await journal?.releaseSessionLease(sessionID: sessionID)
                await AgentSessionIdentityRegistry.shared.release(sessionID, storeID: await journal?.storeIdentity()?.storeID)
                await drain?.complete()
                await scope?.releaseRun(runID)
                if scope != nil { await scopeReleaseDidFinish?(runID) }
            }
        }
    }

    private func finishDraining(runID: UUID) async {
        guard drainingRunID == runID else { return }
        await drainReleaseDidBegin?(runID)
        await journal?.releaseSessionLease(sessionID: id)
        await AgentSessionIdentityRegistry.shared.release(id, storeID: await journal?.storeIdentity()?.storeID)
        if let drain = drainHandles[runID] {
            await drain.complete()
        }
        drainHandles.removeValue(forKey: runID)
        runsByRunID.removeValue(forKey: runID)
        loopsByRunID.removeValue(forKey: runID)
        drainingRunID = nil
        pendingDrainTask = nil
        if let scope = scopesByRunID.removeValue(forKey: runID) {
            await scope.releaseRun(runID)
            await scopeReleaseDidFinish?(runID)
        }
    }

    private func restoreJournalStateIfNeeded() async throws {
        guard !restoredJournalState else { return }
        let checkpoint = try await journal?.latestCheckpoint(sessionID: id)
        applyRestoredJournalState(checkpoint)
    }

    private func applyRestoredJournalState(
        _ checkpoint: (history: [ModelMessage], steeringIDs: [UUID])?
    ) {
        guard !restoredJournalState else { return }
        restoredJournalState = true
        guard let checkpoint else { return }
        // Checkpoint system/developer messages are a historical record of the
        // runtime configuration that was sent, not the active configuration.
        let restored = AgentContextWindow.applyingCurrentInstructions(checkpoint.history, instructions: instructions)
        if restored != history { advanceConversationRevision() }
        history = restored
    }

    private func withStartupDeadline<Value: Sendable>(
        _ deadline: ContinuousClock.Instant,
        startupID: UUID,
        control: AgentRunControl? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        preflightOperations.insert(startupID)
        let work = Task {
            try await withAgentDeadline(
                deadline,
                operation: operation,
                onOperationFinished: { [self] in
                    await self.preflightDidFinish(startupID)
                }
            )
        }
        let workerID = await control?.registerStartupWorker(cancelStartup: { work.cancel() })
        do {
            let value = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            if let workerID { await control?.unregisterStartupWorker(workerID) }
            return value
        } catch {
            if let workerID { await control?.unregisterStartupWorker(workerID) }
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

    private func prepareCheckpoint(_ messages: [ModelMessage]) async throws -> [ModelMessage] {
        AgentContextWindow.applyingCurrentInstructions(messages, instructions: instructions)
    }
}

private actor AgentSessionIdentityRegistry {
    static let shared = AgentSessionIdentityRegistry()
    private struct Key: Hashable {
        let storeID: UUID?
        let sessionID: UUID
    }
    private var activeSessionIDs: Set<Key> = []

    func acquire(_ id: UUID, storeID: UUID?) throws {
        guard activeSessionIDs.insert(Key(storeID: storeID, sessionID: id)).inserted else {
            throw AgentSessionError.runInProgress
        }
    }

    func release(_ id: UUID, storeID: UUID?) {
        activeSessionIDs.remove(Key(storeID: storeID, sessionID: id))
    }
}

public enum AgentSessionError: Error, Equatable, Sendable {
    case emptyInput
    case runInProgress
    case durableJournalRequired
    case admissionRejectionJournalRequired
}
