@testable import AppleChatIntegration
import AgentCore
import AgentModels
import Foundation
import Testing

struct ConversationControllerTests {
    @Test func rapidSecondSendIsRejectedBeforeStartupReturns() async throws {
        let session = ControlledSession()
        let controller = ConversationController(session: session)

        _ = try await controller.send("First")
        #expect(await session.nextStartedText() == "First")
        await #expect(throws: ConversationControllerError.runInProgress) {
            try await controller.send("Second")
        }
        #expect(await controller.snapshot().phase == .starting)
    }

    @Test func stopDuringStartupCancelsAndDrainsALateRun() async throws {
        let session = ControlledSession()
        let run = ControlledRun()
        let controller = ConversationController(session: session)
        var snapshots = controller.snapshots.makeAsyncIterator()
        _ = await snapshots.next()

        _ = try await controller.send("Start slowly")
        #expect(await session.nextStartedText() == "Start slowly")
        await controller.stop()
        #expect((await nextSnapshot(&snapshots, phase: .stopRequested)).phase == .stopRequested)

        await session.resolveNext(with: run.handle)
        await run.waitForCancellationRequest()
        await run.finishCancelled()
        #expect((await nextSnapshot(&snapshots, phase: .draining)).terminal == .cancelled)
        await #expect(throws: ConversationControllerError.runInProgress) {
            try await controller.send("Too early")
        }

        await run.releaseDrain()
        let idle = await nextSnapshot(&snapshots, phase: .idle)
        #expect(idle.terminal == .cancelled)
    }

    @Test func stopThenSendWaitsForPhysicalDrainOwnership() async throws {
        let session = ControlledSession()
        let firstRun = ControlledRun()
        let secondRun = ControlledRun()
        let controller = ConversationController(session: session)
        var snapshots = controller.snapshots.makeAsyncIterator()
        _ = await snapshots.next()

        _ = try await controller.send("First")
        _ = await session.nextStartedText()
        await session.resolveNext(with: firstRun.handle)
        _ = await nextSnapshot(&snapshots, phase: .running)
        await controller.stop()
        await firstRun.waitForCancellationRequest()
        await firstRun.finishCancelled()
        _ = await nextSnapshot(&snapshots, phase: .draining)

        await #expect(throws: ConversationControllerError.runInProgress) {
            try await controller.send("Second")
        }
        await firstRun.releaseDrain()
        _ = await nextSnapshot(&snapshots, phase: .idle)

        _ = try await controller.send("Second")
        #expect(await session.nextStartedText() == "Second")
        await session.resolveNext(with: secondRun.handle)
        #expect((await nextSnapshot(&snapshots, phase: .running)).generation == 2)
    }

    @Test func oldGenerationEventsCannotRepaintANewerConversationTurn() async throws {
        let session = ControlledSession()
        let firstRun = ControlledRun()
        let secondRun = ControlledRun()
        let controller = ConversationController(session: session)
        var snapshots = controller.snapshots.makeAsyncIterator()
        _ = await snapshots.next()

        _ = try await controller.send("First")
        _ = await session.nextStartedText()
        await session.resolveNext(with: firstRun.handle)
        _ = await nextSnapshot(&snapshots, phase: .running)
        await firstRun.finishCompleted(text: "First answer", closeEvents: false)
        await firstRun.releaseDrain()
        _ = await nextSnapshot(&snapshots, phase: .idle)

        _ = try await controller.send("Second")
        _ = await session.nextStartedText()
        await session.resolveNext(with: secondRun.handle)
        _ = await nextSnapshot(&snapshots, phase: .running)
        await secondRun.emitText("Current answer")
        _ = await nextSnapshotContaining(&snapshots, text: "Current answer")
        await firstRun.emitText("STALE")

        let snapshot = await controller.snapshot()
        let text = snapshot.items.compactMap(\.assistant).map(\.text).joined(separator: " ")
        #expect(text.contains("Current answer"))
        #expect(!text.contains("STALE"))
    }

    @Test func failureRemainsVisibleWhilePhysicalDrainContinues() async throws {
        let session = ControlledSession()
        let run = ControlledRun()
        let controller = ConversationController(session: session)
        var snapshots = controller.snapshots.makeAsyncIterator()
        _ = await snapshots.next()

        _ = try await controller.send("Fail")
        _ = await session.nextStartedText()
        await session.resolveNext(with: run.handle)
        _ = await nextSnapshot(&snapshots, phase: .running)
        let failure = AgentFailure.provider(.init(kind: .invalidResponse, message: "sanitized"))
        await run.finishFailed(failure)

        let draining = await nextSnapshot(&snapshots, phase: .draining)
        #expect(draining.terminal == .failed(failure))
        await run.releaseDrain()
        let idle = await nextSnapshot(&snapshots, phase: .idle)
        #expect(idle.terminal == .failed(failure))
    }
}

private actor ControlledSession: ConversationSessionHandle {
    private let started = AsyncStream<String>.makeStream()
    private var starts = [CheckedContinuation<ConversationRunHandle, Error>]()

    func start(_ text: String) async throws -> ConversationRunHandle {
        started.continuation.yield(text)
        return try await withCheckedThrowingContinuation { continuation in
            starts.append(continuation)
        }
    }

    func nextStartedText() async -> String? {
        var iterator = started.stream.makeAsyncIterator()
        return await iterator.next()
    }

    func resolveNext(with run: ConversationRunHandle) {
        starts.removeFirst().resume(returning: run)
    }
}

private final class ControlledRun: Sendable {
    private let state: State
    let handle: ConversationRunHandle

    init(id: UUID = UUID()) {
        let events = AsyncStream<AgentEvent>.makeStream()
        let state = State(events: events.continuation)
        self.state = state
        handle = ConversationRunHandle(
            id: id,
            events: events.stream,
            cancel: { await state.cancel() },
            wait: { try await state.wait() },
            waitForDrain: { try await state.waitForDrain() }
        )
    }

    func waitForCancellationRequest() async { await state.waitForCancellationRequest() }
    func releaseDrain() async { await state.releaseDrain() }
    func emitText(_ text: String) async { await state.emitText(text) }

    func finishCancelled() async {
        await state.finish(.failure(CancellationError()), termination: .cancelled, closeEvents: true)
    }

    func finishFailed(_ failure: AgentFailure) async {
        await state.finish(
            .failure(ModelProviderError(kind: .invalidResponse, message: "sanitized")),
            termination: .failed(failure),
            closeEvents: true
        )
    }

    func finishCompleted(text: String, closeEvents: Bool) async {
        await state.emitText(text)
        await state.finish(.success(.completed), termination: nil, closeEvents: closeEvents)
    }

    private actor State {
        let events: AsyncStream<AgentEvent>.Continuation
        private var cancellationRequested = false
        private var cancellationWaiters = [CheckedContinuation<Void, Never>]()
        private var result: Result<ConversationRunResult, Error>?
        private var resultWaiters = [CheckedContinuation<ConversationRunResult, Error>]()
        private var drainReleased = false
        private var drainWaiters = [CheckedContinuation<Void, Error>]()

        init(events: AsyncStream<AgentEvent>.Continuation) {
            self.events = events
        }

        func cancel() {
            cancellationRequested = true
            let waiters = cancellationWaiters
            cancellationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func waitForCancellationRequest() async {
            if cancellationRequested { return }
            await withCheckedContinuation { cancellationWaiters.append($0) }
        }

        func wait() async throws -> ConversationRunResult {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { resultWaiters.append($0) }
        }

        func waitForDrain() async throws {
            if drainReleased { return }
            try await withCheckedThrowingContinuation { drainWaiters.append($0) }
        }

        func releaseDrain() {
            drainReleased = true
            let waiters = drainWaiters
            drainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func emitText(_ text: String) {
            events.yield(.turnStarted(1))
            events.yield(.model(.textDelta(text)))
        }

        func finish(
            _ result: Result<ConversationRunResult, Error>,
            termination: AgentRunTermination?,
            closeEvents: Bool
        ) {
            self.result = result
            if let termination { events.yield(.runFinished(termination)) }
            if closeEvents { events.finish() }
            let waiters = resultWaiters
            resultWaiters.removeAll()
            waiters.forEach { $0.resume(with: result) }
        }
    }
}

private func nextSnapshot(
    _ iterator: inout AsyncStream<ConversationSnapshot>.Iterator,
    phase: ConversationPhase
) async -> ConversationSnapshot {
    while let snapshot = await iterator.next() {
        if snapshot.phase == phase { return snapshot }
    }
    Issue.record("Snapshot stream ended before phase \(phase)")
    return .init(conversationID: UUID())
}

private func nextSnapshotContaining(
    _ iterator: inout AsyncStream<ConversationSnapshot>.Iterator,
    text: String
) async -> ConversationSnapshot {
    while let snapshot = await iterator.next() {
        if snapshot.items.compactMap(\.assistant).contains(where: { $0.text.contains(text) }) {
            return snapshot
        }
    }
    Issue.record("Snapshot stream ended before text \(text)")
    return .init(conversationID: UUID())
}

private extension ConversationItem {
    var assistant: DisplayAssistantTurn? {
        guard case .assistant(let value) = self else { return nil }
        return value
    }
}
