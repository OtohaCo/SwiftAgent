import AgentModels
import AgentTools
import Foundation

/// One isolated conversation. Canonical history lives here. Only one Run may
/// be active; overlapping `run` calls fail with `runInProgress`.
///
/// History is readable and not assignable. Restoration uses the journal
/// checkpoint, never a caller-supplied array. Share the Agent's scheduler
/// when another Session can mutate the same host resources.
public actor AgentSession {
    public nonisolated let id: UUID
    public private(set) var history: [ModelMessage]
    public private(set) var activeRunID: UUID?
    private let loop: AgentLoop
    private let evidenceLedger = EvidenceLedger()
    private let structuredOutput: StructuredOutputSchema?
    private let maxModelTurns: Int
    private let maxToolCalls: Int
    private let runTimeout: Duration
    private let journal: AgentJournal?
    private var appliedSteeringIDs: Set<UUID> = []
    private var restoredJournalState = false
    private var pendingDrainTask: Task<Void, Never>?
    private var drainingRunID: UUID?

    init(id: UUID = UUID(), loop: AgentLoop, instructions: String, structuredOutput: StructuredOutputSchema?, maxModelTurns: Int,
         maxToolCalls: Int, runTimeout: Duration, journal: AgentJournal? = nil) {
        self.id = id
        self.loop = loop
        self.structuredOutput = structuredOutput
        history = instructions.isEmpty ? [] : [.system(instructions)]
        self.maxModelTurns = maxModelTurns
        self.maxToolCalls = maxToolCalls
        self.runTimeout = runTimeout
        self.journal = journal
    }

    /// Starts one Run. Empty input, an already-active Run, a cancelled caller
    /// and an expired budget do not append history. Mutation tools require a
    /// journal supplied at Session creation.
    public func run(
        _ text: String,
        budget: AgentBudget? = nil,
        operationID: String? = nil
    ) async throws -> AgentRun {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentSessionError.emptyInput }
        guard activeRunID == nil else { throw AgentSessionError.runInProgress }
        if let pendingDrainTask {
            await pendingDrainTask.value
            try Task.checkCancellation()
        }
        try await AgentSessionIdentityRegistry.shared.acquire(id)
        do {
            do {
                if let journal {
                    do {
                        try await journal.acquireSessionLease(sessionID: id)
                    } catch AgentJournalError.sessionLeaseUnavailable {
                        throw AgentSessionError.runInProgress
                    }
                }
                do {
                    return try await startRun(text, budget: budget, operationID: operationID)
                } catch {
                    await journal?.releaseSessionLease(sessionID: id)
                    throw error
                }
            } catch {
                await AgentSessionIdentityRegistry.shared.release(id)
                throw error
            }
        }
    }

    public func waitForRunToDrain(runID: UUID) async {
        await loop.waitForRunToDrain(sessionID: id, runID: runID)
        await finishDraining(runID: runID)
    }

    private func startRun(_ text: String, budget: AgentBudget?, operationID: String?) async throws -> AgentRun {
        let budget = try budget ?? AgentBudget(maxModelTurns: maxModelTurns, maxToolCalls: maxToolCalls,
                                               deadline: .now.advanced(by: runTimeout))
        try budget.checkActive()
        await restoreJournalStateIfNeeded()
        let runID = UUID()
        if let journal {
            _ = try await journal.recoverPendingMutations(sessionID: id)
            let hasSessionRecord = await journal.snapshot().contains { record in
                guard record.sessionID == id else { return false }
                if case .sessionCreated = record.event { return true }
                return false
            }
            var lifecycleEvents: [AgentJournalEvent] = hasSessionRecord ? [] : [.sessionCreated]
            lifecycleEvents.append(.userMessage(text))
            try await journal.appendCheckpoint(lifecycleEvents, sessionID: id, runID: runID, durability: .durable)
        }
        let control = AgentRunControl()
        let channel = AsyncStream<AgentEvent>.makeStream()
        let emitter = AgentEventEmitter(channel.continuation, requiresConsumer: false)
        history.append(.user([.text(text)]))
        activeRunID = runID
        appliedSteeringIDs.removeAll()
        let messages = history
        Task {
            await control.start {
                await self.perform(
                    messages,
                    runID: runID,
                    operationID: operationID,
                    budget: budget,
                    emitter: emitter,
                    control: control
                )
            }
        }
        return AgentRun(id: runID, sessionID: id, events: channel.stream, control: control)
    }
    private func perform(_ messages: [ModelMessage], runID: UUID, operationID: String?, budget: AgentBudget,
                         emitter: AgentEventEmitter, control: AgentRunControl) async -> Result<AgentLoopResult, Error> {
        let journal = self.journal
        let lifecycle = AgentLoopLifecycle(
            control: control,
            evidenceLedger: evidenceLedger,
            mutationAdmission: journal,
            checkpoint: { messages, steering in try await self.record(messages, steering: steering, runID: runID, budget: budget) },
            recordMutationReceipt: { callID, receipt in
                try await journal?.settleMutation(sessionID: self.id, runID: runID, callID: callID, receipt: receipt)
            },
            commitMutation: { callID, receipt, messages, steering in
                guard let journal else {
                    throw AgentJournalError.persistenceUnavailable("mutation history cannot be committed without a journal")
                }
                try await journal.commitMutation(
                    sessionID: self.id,
                    runID: runID,
                    callID: callID,
                    receipt: receipt,
                    history: messages,
                    steeringIDs: steering.map(\.id)
                )
                await self.applyCommittedHistory(messages, steering: steering, runID: runID)
            },
            markMutationNeedsReconciliation: { callID in
                try await journal?.markMutationNeedsReconciliation(sessionID: self.id, runID: runID, callID: callID)
            },
            beforeFinish: {
                let pending = await control.beginFinish()
                await self.finish(runID: runID, pending: pending)
            }
        )
        do {
            let result = try await loop.execute(messages: messages, sessionID: id, runID: runID, budget: budget,
                                                structuredOutput: structuredOutput, operationID: operationID,
                                                emitter: emitter, lifecycle: lifecycle)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func record(_ messages: [ModelMessage], steering: [AgentSteeringInput], runID: UUID, budget: AgentBudget) async throws {
        try budget.checkActive()
        guard activeRunID == runID else { throw CancellationError() }
        if let journal {
            try await journal.append(.checkpoint(history: messages, steeringIDs: steering.map(\.id)),
                                     sessionID: id, runID: runID, durability: .durable)
        }
        history = messages
        appliedSteeringIDs.formUnion(steering.map(\.id))
    }

    private func applyCommittedHistory(_ messages: [ModelMessage], steering: [AgentSteeringInput], runID: UUID) {
        guard activeRunID == runID else { return }
        history = messages
        appliedSteeringIDs.formUnion(steering.map(\.id))
    }

    private func finish(runID: UUID, pending: [AgentSteeringInput]) async {
        guard activeRunID == runID else { return }
        for input in pending where !appliedSteeringIDs.contains(input.id) {
            history.append(.user([.text(input.text)]))
        }
        activeRunID = nil
        appliedSteeringIDs.removeAll()
        drainingRunID = runID
        let sessionID = id
        let loop = self.loop
        let journal = self.journal
        pendingDrainTask = Task { [weak self] in
            await loop.waitForRunToDrain(sessionID: sessionID, runID: runID)
            if let self {
                await self.finishDraining(runID: runID)
            } else {
                await journal?.releaseSessionLease(sessionID: sessionID)
                await AgentSessionIdentityRegistry.shared.release(sessionID)
            }
        }
    }

    private func finishDraining(runID: UUID) async {
        guard drainingRunID == runID else { return }
        drainingRunID = nil
        pendingDrainTask = nil
        await journal?.releaseSessionLease(sessionID: id)
        await AgentSessionIdentityRegistry.shared.release(id)
    }

    private func restoreJournalStateIfNeeded() async {
        guard !restoredJournalState else { return }
        restoredJournalState = true
        guard let journal,
              let checkpoint = await journal.latestCheckpoint(sessionID: id) else { return }
        history = checkpoint.history
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
