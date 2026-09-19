import AgentCore
import AgentModels
import AgentTools
import Foundation

public enum ConversationControllerError: Error, Equatable, Sendable {
    case emptyInput
    case runInProgress
}

public enum ConversationRunResult: Equatable, Sendable {
    case completed
    case refused
    case incomplete(StopReason)
}

public struct ConversationRunHandle: Sendable {
    public let id: UUID
    public let events: AsyncStream<AgentEvent>
    private let cancelOperation: @Sendable () async -> Void
    private let waitOperation: @Sendable () async throws -> ConversationRunResult
    private let drainOperation: @Sendable () async throws -> Void

    init(
        id: UUID,
        events: AsyncStream<AgentEvent>,
        cancel: @escaping @Sendable () async -> Void,
        wait: @escaping @Sendable () async throws -> ConversationRunResult,
        waitForDrain: @escaping @Sendable () async throws -> Void
    ) {
        self.id = id
        self.events = events
        cancelOperation = cancel
        waitOperation = wait
        drainOperation = waitForDrain
    }

    public init(_ run: AgentRun) {
        self.init(
            id: run.id,
            events: run.events,
            cancel: { await run.cancel() },
            wait: {
                switch try await run.wait().outcome {
                case .completed: .completed
                case .refused: .refused
                case .incomplete(let reason): .incomplete(reason)
                }
            },
            waitForDrain: { try await run.waitForDrain() }
        )
    }

    public func cancel() async { await cancelOperation() }
    public func wait() async throws -> ConversationRunResult { try await waitOperation() }
    public func waitForDrain() async throws { try await drainOperation() }
}

public protocol ConversationSessionHandle: Sendable {
    func start(_ text: String) async throws -> ConversationRunHandle
}

public actor AgentConversationSessionHandle: ConversationSessionHandle {
    private let session: AgentSession

    public init(session: AgentSession) {
        self.session = session
    }

    public func start(_ text: String) async throws -> ConversationRunHandle {
        ConversationRunHandle(try await session.run(text))
    }
}

public actor ConversationController {
    public nonisolated let conversationID: UUID
    public nonisolated let snapshots: AsyncStream<ConversationSnapshot>

    private let session: any ConversationSessionHandle
    private let mailbox: ConversationSnapshotMailbox
    private let eventDeliveryHook: @Sendable (AgentEvent) async -> Void
    private var projection: ConversationProjection
    private var generation: UInt64 = 0
    private var startupTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var activeRun: ConversationRunHandle?
    private var abandonedCleanups: [UUID: Task<Void, Never>] = [:]

    public init(
        conversationID: UUID = UUID(),
        session: any ConversationSessionHandle,
        maxDisplayItems: Int = 100
    ) {
        self.init(
            conversationID: conversationID,
            session: session,
            maxDisplayItems: maxDisplayItems,
            eventDeliveryHook: { _ in }
        )
    }

    init(
        conversationID: UUID = UUID(),
        session: any ConversationSessionHandle,
        maxDisplayItems: Int = 100,
        eventDeliveryHook: @escaping @Sendable (AgentEvent) async -> Void
    ) {
        self.conversationID = conversationID
        self.session = session
        self.eventDeliveryHook = eventDeliveryHook
        let projection = ConversationProjection(conversationID: conversationID, maxItems: maxDisplayItems)
        self.projection = projection
        let mailbox = ConversationSnapshotMailbox(initial: projection.snapshot)
        self.mailbox = mailbox
        snapshots = mailbox.snapshots
    }

    deinit {
        startupTask?.cancel()
        observationTask?.cancel()
        cleanupTask?.cancel()
        abandonedCleanups.values.forEach { $0.cancel() }
        mailbox.finish()
    }

    @discardableResult
    public func send(_ text: String) throws -> UInt64 {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConversationControllerError.emptyInput }
        guard projection.snapshot.phase == .idle else { throw ConversationControllerError.runInProgress }

        generation &+= 1
        let reservedGeneration = generation
        projection.beginUserTurn(text, generation: reservedGeneration)
        publish()

        let session = self.session
        startupTask = Task { [weak self] in
            do {
                let run = try await session.start(text)
                await self?.attach(run, generation: reservedGeneration)
            } catch {
                await self?.startupFailed(error, generation: reservedGeneration)
            }
        }
        return reservedGeneration
    }

    public func stop() async {
        guard projection.snapshot.phase != .idle else { return }
        projection.setPhase(.stopRequested)
        publish()
        startupTask?.cancel()
        if let activeRun { await activeRun.cancel() }
    }

    public func snapshot() -> ConversationSnapshot {
        projection.snapshot
    }

    private func attach(_ run: ConversationRunHandle, generation: UInt64) async {
        guard generation == self.generation else {
            retainAbandonedCleanup(for: run)
            return
        }

        startupTask = nil
        activeRun = run
        let stopWasRequested = projection.snapshot.phase == .stopRequested
        projection.setPhase(stopWasRequested ? .stopRequested : .running)
        publish()

        let events = run.events
        let eventDeliveryHook = self.eventDeliveryHook
        let observationTask = Task { [weak self] in
            for await event in events {
                await eventDeliveryHook(event)
                await self?.receive(event, generation: generation, runID: run.id)
            }
        }
        self.observationTask = observationTask
        cleanupTask = Task { [weak self] in
            let result: Result<ConversationRunResult, Error>
            do {
                result = .success(try await run.wait())
            } catch {
                result = .failure(error)
            }
            await self?.logicalCompletion(result, generation: generation, runID: run.id)
            do {
                try await run.waitForDrain()
            } catch is CancellationError {
                return
            } catch {
                await self?.logicalCompletion(.failure(error), generation: generation, runID: run.id)
            }
            _ = await observationTask.result
            await self?.drainCompleted(generation: generation, runID: run.id)
        }

        if stopWasRequested { await run.cancel() }
    }

    private func startupFailed(_ error: any Error, generation: UInt64) {
        guard generation == self.generation else { return }
        startupTask = nil
        if error is CancellationError, projection.snapshot.phase == .stopRequested {
            projection.setTerminal(.cancelled)
        } else {
            projection.setTerminal(.failed(Self.agentFailure(error)))
        }
        projection.clearRunAfterDrain()
        publish()
    }

    private func receive(_ event: AgentEvent, generation: UInt64, runID: UUID) {
        guard generation == self.generation, activeRun?.id == runID else { return }
        projection.apply(event)
        publish()
    }

    private func logicalCompletion(
        _ result: Result<ConversationRunResult, Error>,
        generation: UInt64,
        runID: UUID
    ) {
        guard generation == self.generation, activeRun?.id == runID else { return }
        switch result {
        case .success(let result):
            switch result {
            case .completed: projection.setTerminal(.completed)
            case .refused: projection.setTerminal(.refused)
            case .incomplete(let reason): projection.setTerminal(.incomplete(reason))
            }
        case .failure(let error):
            if error is CancellationError {
                projection.setTerminal(.cancelled)
            } else {
                projection.setTerminal(.failed(Self.agentFailure(error)))
            }
        }
        projection.setPhase(.draining)
        publish()
    }

    private func drainCompleted(generation: UInt64, runID: UUID) {
        guard generation == self.generation, activeRun?.id == runID else { return }
        observationTask?.cancel()
        observationTask = nil
        cleanupTask = nil
        activeRun = nil
        projection.clearRunAfterDrain()
        publish()
    }

    private func retainAbandonedCleanup(for run: ConversationRunHandle) {
        let events = run.events
        let task = Task { [weak self] in
            let observation = Task {
                for await _ in events {}
            }
            await run.cancel()
            _ = try? await run.wait()
            _ = try? await run.waitForDrain()
            _ = await observation.result
            await self?.abandonedCleanupFinished(run.id)
        }
        abandonedCleanups[run.id] = task
    }

    private func abandonedCleanupFinished(_ runID: UUID) {
        abandonedCleanups.removeValue(forKey: runID)
    }

    private func publish() {
        mailbox.send(projection.snapshot)
    }

    private static func agentFailure(_ error: any Error) -> AgentFailure {
        switch error {
        case is CancellationError: .cancelled
        case let value as AgentLoopError: .loop(value)
        case let value as AgentSessionError: .session(value)
        case let value as ModelProviderError: .provider(value)
        case let value as ModelStreamError: .modelStream(value)
        case let value as ToolRegistryError: .toolRegistry(value)
        case let value as ToolInvocationError: .toolInvocation(value)
        case let value as EvidenceError: .evidence(value)
        case let value as ToolReceiptError: .receipt(value)
        case let value as ToolResourceError: .resource(value)
        case let value as ToolSchedulerError: .scheduler(value)
        case let value as AgentJournalError: .journal(value)
        case let value as AgentMutationPersistenceError: .mutationPersistence(value)
        case let value as AgentContextError: .context(value)
        default: .unclassified
        }
    }
}
