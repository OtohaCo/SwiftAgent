import AgentModels
import Foundation

public protocol AgentFollowUpResolver: Sendable {
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration
}

public struct AgentFollowUpResolution: Sendable {
    public let record: AgentFollowUpRecord
    public let text: String
    public let attemptID: UUID
    public let deadline: ContinuousClock.Instant

    public init(record: AgentFollowUpRecord, text: String, attemptID: UUID,
                deadline: ContinuousClock.Instant) {
        self.record = record; self.text = text; self.attemptID = attemptID; self.deadline = deadline
    }
}

public struct AgentFollowUpConfiguration: Sendable {
    public let model: AgentModelBinding
    public let capabilities: AgentCapabilityBinding?
    public let expectedConversationRevision: UInt64?

    public init(model: AgentModelBinding, capabilities: AgentCapabilityBinding?,
                expectedConversationRevision: UInt64? = nil) {
        self.model = model; self.capabilities = capabilities
        self.expectedConversationRevision = expectedConversationRevision
    }
}

public struct AgentFollowUpDispatchPolicy: Sendable {
    public let maxModelTurns: Int
    public let maxToolCalls: Int
    public let runTimeout: Duration

    public init(maxModelTurns: Int = 8, maxToolCalls: Int = 16, runTimeout: Duration = .seconds(30)) {
        self.maxModelTurns = maxModelTurns; self.maxToolCalls = maxToolCalls; self.runTimeout = runTimeout
    }

    package func validate() throws {
        guard maxModelTurns > 0, maxToolCalls >= 0, runTimeout > .zero else {
            throw AgentLoopError.invalidBudget
        }
    }
}

public struct AgentFollowUpDispatchStatus: Sendable {
    public enum Mode: String, Sendable { case running, paused, stopped }
    public let mode: Mode
    public let currentInputID: String?
    public let interruptedInputID: String?
    public let lastFailureKind: String?
    public let physicallyDrained: Bool
}

/// An explicitly started single-Session consumer. It does not own a second
/// AgentRun.events listener or a new tool/Journal execution state machine.
public actor AgentFollowUpDispatcher {
    private let session: AgentSession
    private let journal: AgentJournal
    private let sessionID: UUID
    private let ownerID: UUID
    private let policy: AgentFollowUpDispatchPolicy
    private let resolver: any AgentFollowUpResolver
    private let initialDrain: AgentRunDrain?
    private var mode: AgentFollowUpDispatchStatus.Mode = .running
    private var worker: Task<Void, Never>?
    private var resolverTask: Task<AgentFollowUpConfiguration, Error>?
    private var startupTask: Task<AgentRun, Error>?
    private var resolverWorkers = 0
    private var currentRun: AgentRun?
    private var currentInputID: String?
    private var interruptedInputID: String?
    private var lastFailureKind: String?
    private var attemptGeneration: UInt64 = 0
    private var signalVersion: UInt64 = 0
    private var signals: [CheckedContinuation<Void, Never>] = []
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var drained = false
    private var drainWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(session: AgentSession, journal: AgentJournal, sessionID: UUID, ownerID: UUID,
                 policy: AgentFollowUpDispatchPolicy, resolver: any AgentFollowUpResolver,
                 initialDrain: AgentRunDrain?) {
        self.session = session; self.journal = journal; self.sessionID = sessionID
        self.ownerID = ownerID; self.policy = policy; self.resolver = resolver
        self.initialDrain = initialDrain
    }

    package func start() {
        guard worker == nil else { return }
        worker = Task { await runLoop() }
    }

    package func signal() {
        signalVersion &+= 1
        let pending = signals
        signals.removeAll()
        pending.forEach { $0.resume() }
    }

    public func status() -> AgentFollowUpDispatchStatus {
        .init(mode: mode, currentInputID: currentInputID,
              interruptedInputID: interruptedInputID,
              lastFailureKind: lastFailureKind, physicallyDrained: drained)
    }

    public func pause() {
        guard mode == .running else { return }
        mode = .paused
        notifyPaused()
        attemptGeneration &+= 1
        resolverTask?.cancel()
        startupTask?.cancel()
        signal()
    }

    public func resume() throws {
        guard mode != .stopped else { throw AgentFollowUpError.dispatcherStopped }
        guard interruptedInputID == nil else { throw AgentFollowUpError.needsInspection }
        mode = .running
        signal()
    }

    /// Explicit Host decision to continue *later* queued inputs after
    /// inspecting an interrupted admitted Run. This never retries that Run,
    /// marks it successful or clears an unresolved mutation.
    public func resumeAfterInspection(inputID: String) async throws {
        guard mode == .paused else { throw AgentFollowUpError.staleDispatch }
        if let interruptedInputID,
           !interruptedInputID.utf8.elementsEqual(inputID.utf8) {
            throw AgentFollowUpError.staleDispatch
        }
        try await journal.releaseInspectedFollowUp(sessionID: sessionID, inputID: inputID)
        interruptedInputID = nil
        lastFailureKind = nil
        mode = .running
        signal()
    }

    public func stop() {
        guard mode != .stopped else { return }
        mode = .stopped
        attemptGeneration &+= 1
        resolverTask?.cancel()
        startupTask?.cancel()
        signal()
    }

    public func cancelCurrent() async { await currentRun?.cancel() }

    public func waitForDrain() async throws {
        try Task.checkCancellation()
        guard !drained else { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if drained { continuation.resume() }
                else { drainWaiters[id] = continuation }
            }
        }, onCancel: {
            Task { await self.cancelDrainWaiter(id) }
        })
        try Task.checkCancellation()
    }

    private func cancelDrainWaiter(_ id: UUID) {
        drainWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    package func waitUntilPaused() async {
        guard mode != .paused else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    private func notifyPaused() {
        let pending = pauseWaiters
        pauseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func waitForSignal(since observed: UInt64) async {
        guard mode != .stopped, observed == signalVersion else { return }
        await withCheckedContinuation { continuation in
            if mode == .stopped || observed != signalVersion { continuation.resume() }
            else { signals.append(continuation) }
        }
    }

    private func waitForPhysicalSignal(since observed: UInt64) async {
        guard observed == signalVersion else { return }
        await withCheckedContinuation { continuation in
            if observed != signalVersion { continuation.resume() }
            else { signals.append(continuation) }
        }
    }

    private func resolverDidExit() {
        resolverWorkers -= 1
        signal()
    }

    private func runLoop() async {
        if let initialDrain { try? await initialDrain.wait() }
        while mode != .stopped {
            let observed = signalVersion
            if mode == .paused || resolverWorkers > 0 {
                await waitForSignal(since: observed)
                continue
            }
            do {
                if let interrupted = try await journal.interruptedFollowUp(sessionID: sessionID) {
                    interruptedInputID = interrupted.input.inputID
                    mode = .paused
                    notifyPaused()
                    continue
                }
                guard let head = try await journal.firstQueuedFollowUp(sessionID: sessionID) else {
                    await waitForSignal(since: observed)
                    continue
                }
                try await dispatch(head)
            } catch {
                lastFailureKind = Self.failureKind(error)
                if mode != .stopped { mode = .paused; notifyPaused() }
            }
        }
        // A cancelled deadline race may have returned before a Host resolver
        // actually exits. Its onOperationFinished callback owns that cleanup.
        while resolverWorkers > 0 {
            let observed = signalVersion
            await waitForPhysicalSignal(since: observed)
        }
        await session.waitForQueuedStartupExit(ownerID: ownerID)
        if let run = currentRun {
            _ = try? await run.wait()
            try? await run.waitForDrain()
            currentRun = nil
        }
        await journal.releaseDispatcherLease(sessionID: sessionID, owner: ownerID)
        await session.followUpDispatcherDidStop(ownerID: ownerID)
        drained = true
        worker = nil
        let observers = drainWaiters
        drainWaiters.removeAll()
        observers.values.forEach { $0.resume() }
    }

    private func dispatch(_ head: JournalStoredFollowUp) async throws {
        guard attemptGeneration < .max else { throw AgentFollowUpError.staleDispatch }
        attemptGeneration += 1
        let generation = attemptGeneration
        let deadline = ContinuousClock.now.advanced(by: policy.runTimeout)
        let budget = try AgentBudget(maxModelTurns: policy.maxModelTurns,
                                      maxToolCalls: policy.maxToolCalls, deadline: deadline)
        guard let identity = await journal.storeIdentity() else {
            throw AgentFollowUpError.durableJournalRequired
        }
        currentInputID = head.input.inputID
        resolverWorkers += 1
        let resolver = self.resolver
        let request = AgentFollowUpResolution(record: head.publicRecord(
            storeID: identity.storeID),
            text: head.input.text, attemptID: UUID(), deadline: deadline)
        let resolution = Task { [self] in
            try await withAgentDeadline(deadline, operation: {
                try await resolver.resolve(request)
            }, onOperationFinished: {
                await self.resolverDidExit()
            })
        }
        resolverTask = resolution
        let configuration: AgentFollowUpConfiguration
        do { configuration = try await resolution.value }
        catch {
            resolverTask = nil
            currentInputID = nil
            throw error
        }
        resolverTask = nil
        guard mode == .running, attemptGeneration == generation else {
            currentInputID = nil
            return
        }
        // The store checks head identity and state again in the combined
        // startup publication, so withdrawal can win after resolution.
        let startup = Task { [session, ownerID] in
            try await session.startQueuedFollowUp(head, using: configuration,
                                                  ownerID: ownerID, budget: budget)
        }
        startupTask = startup
        let run: AgentRun
        do { run = try await startup.value }
        catch {
            startupTask = nil
            currentInputID = nil
            await session.waitForQueuedStartupExit(ownerID: ownerID)
            throw error
        }
        startupTask = nil
        currentRun = run
        let outcome: AgentLoopOutcome?
        do {
            outcome = try await run.wait().outcome
        } catch {
            outcome = nil
            lastFailureKind = Self.failureKind(error)
        }
        try await run.waitForDrain()
        currentRun = nil
        currentInputID = nil
        guard outcome == .completed else {
            if mode != .stopped { mode = .paused; notifyPaused() }
            return
        }
        // This records that the existing Run actually completed and drained,
        // not that a Host business objective was fulfilled.
        try await journal.releaseCompletedFollowUp(sessionID: sessionID,
                                                   inputID: head.input.inputID, runID: run.id)
    }

    private static func failureKind(_ error: any Error) -> String {
        if error is AgentJournalError { return "journal" }
        if error is AgentFollowUpError { return "follow_up" }
        if error is AgentContextError { return "context" }
        if error is CancellationError { return "cancelled" }
        return "resolver_or_run"
    }
}
