import AgentModels
import XCTest

final class OperationDeadlineTests: XCTestCase {
    func testExpiredOperationRunsCompletionHookBeforeThrowing() async {
        let probe = CompletionProbe()

        do {
            _ = try await withOperationDeadline(
                .now,
                timeoutError: DeadlineFixtureError.expired,
                operation: { 1 },
                onOperationFinished: { await probe.mark() }
            )
            XCTFail("An expired operation must fail before starting")
        } catch {
            XCTAssertEqual(error as? DeadlineFixtureError, .expired)
        }

        let completionCount = await probe.count
        XCTAssertEqual(completionCount, 1)
    }
    func testResultSettledBeforeTheDeadlineSurvivesTheDeadlinePassingWhileItIsRecorded() async throws {
        let gate = OperationDeadlineGate(deadline: .now.advanced(by: .milliseconds(150)))
        let value = try await withOperationDeadline(
            gate.deadline, timeoutError: DeadlineFixtureError.expired, gate: gate,
            operation: {
                XCTAssertTrue(gate.settle())
                try await Task.sleep(for: .milliseconds(400))
                return 7
            }
        )
        XCTAssertEqual(value, 7)
    }

    func testOperationNotSettledByTheDeadlineStillTimesOut() async {
        let gate = OperationDeadlineGate(deadline: .now.advanced(by: .milliseconds(150)))
        do {
            _ = try await withOperationDeadline(
                gate.deadline, timeoutError: DeadlineFixtureError.expired, gate: gate,
                operation: {
                    try await Task.sleep(for: .milliseconds(400))
                    return 7
                }
            )
            XCTFail("Work still running at the deadline must time out")
        } catch {
            XCTAssertEqual(error as? DeadlineFixtureError, .expired)
        }
    }

    func testCancellationStillEndsASettledOperation() async {
        let gate = OperationDeadlineGate(deadline: .now.advanced(by: .seconds(5)))
        let task = Task {
            try await withOperationDeadline(
                gate.deadline, timeoutError: DeadlineFixtureError.expired, gate: gate,
                operation: {
                    XCTAssertTrue(gate.settle())
                    try await Task.sleep(for: .seconds(5))
                    return 7
                }
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled operation must not complete")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testGateSettlesOnlyBeforeTheDeadlineAndReopens() {
        let past = OperationDeadlineGate(deadline: .now.advanced(by: .seconds(-1)))
        XCTAssertFalse(past.settle())
        XCTAssertFalse(past.settle(now: .now.advanced(by: .seconds(-2))), "Once expired it stays expired")

        let open = OperationDeadlineGate(deadline: .now.advanced(by: .seconds(60)))
        XCTAssertTrue(open.settle())
        XCTAssertFalse(open.expire(), "A settled result is not taken back by the timer")
        open.reopen()
        XCTAssertTrue(open.expire())
        XCTAssertFalse(open.settle())
    }

    func testPreservedErrorRethrownWhenThrownAfterDeadlinePassed() async {
        let clock = DeterministicDeadlineClock()
        await AgentClock.$source.withValue(clock) {
            let probe = CompletionProbe()
            let deadline = clock.after(.seconds(1))

            do {
                _ = try await withOperationDeadline(
                    deadline,
                    timeoutError: DeadlineFixtureError.expired,
                    operation: {
                        // Ensure the deadline timer is parked before advancing monotonic `now` without waking it.
                        await clock.waitForSleeper(until: deadline)
                        clock.advanceNowWithoutWakingSleepers(by: .seconds(1))
                        throw PreservedFixtureError.preserved
                    },
                    onOperationFinished: { await probe.mark() }
                )
                XCTFail("A preserved failure must be thrown verbatim")
            } catch {
                XCTAssertEqual(error as? PreservedFixtureError, .preserved)
            }

            let completionCount = await probe.count
            XCTAssertEqual(completionCount, 1)
        }
    }

    func testPreservedErrorRethrownWhenDeadlineExpiresDuringOnOperationFinished() async {
        for useGate in [false, true] {
            let clock = DeterministicDeadlineClock()
            await AgentClock.$source.withValue(clock) {
                let deadline = clock.after(.seconds(1))
                let gate = useGate ? OperationDeadlineGate(deadline: deadline) : nil
                let enteredFinished = DeadlineTestSignal()
                let releaseFinished = DeadlineTestSignal()
                let workerCancelled = DeadlineTestSignal()

                let task = Task<Int, Error> {
                    try await withOperationDeadline(
                        deadline,
                        timeoutError: DeadlineFixtureError.expired,
                        gate: gate,
                        operation: {
                            throw PreservedFixtureError.preserved
                        },
                        onOperationFinished: {
                            await withTaskCancellationHandler {
                                await enteredFinished.signal()
                                await releaseFinished.wait()
                            } onCancel: {
                                Task { await workerCancelled.signal() }
                            }
                        }
                    )
                }

                await enteredFinished.wait()
                await clock.waitForSleeper(until: deadline)
                clock.advance(by: .seconds(1))
                await workerCancelled.wait()
                await Task.yield()
                await releaseFinished.signal()

                do {
                    _ = try await task.value
                    XCTFail("A preserved failure must survive deadline expiry during cleanup")
                } catch {
                    XCTAssertEqual(error as? PreservedFixtureError, .preserved)
                }
            }
        }
    }

    func testPreservedErrorRethrownWhenEnclosingTaskIsCancelledDuringOnOperationFinished() async {
        let clock = DeterministicDeadlineClock()
        await AgentClock.$source.withValue(clock) {
            let deadline = clock.after(.seconds(10))
            let enteredFinished = DeadlineTestSignal()
            let releaseFinished = DeadlineTestSignal()
            let workerCancelled = DeadlineTestSignal()

            let task = Task<Int, Error> {
                try await withOperationDeadline(
                    deadline,
                    timeoutError: DeadlineFixtureError.expired,
                    operation: {
                        throw PreservedFixtureError.preserved
                    },
                    onOperationFinished: {
                        await withTaskCancellationHandler {
                            await enteredFinished.signal()
                            await releaseFinished.wait()
                        } onCancel: {
                            Task { await workerCancelled.signal() }
                        }
                    }
                )
            }

            await enteredFinished.wait()
            task.cancel()
            await workerCancelled.wait()
            await Task.yield()
            await releaseFinished.signal()

            do {
                _ = try await task.value
                XCTFail("A preserved failure must survive task cancellation")
            } catch {
                XCTAssertEqual(error as? PreservedFixtureError, .preserved)
            }
        }
    }

    func testNonPreservedErrorsStillOverriddenByDeadlineAndCancellation() async {
        let cases: [any Error & Sendable] = [
            DeadlineFixtureError.other,
            PreservedFixtureError.notPreserved,
        ]

        // 1. Thrown after deadline passed (clock past deadline before timer fires).
        for fixtureError in cases {
            let clock = DeterministicDeadlineClock()
            await AgentClock.$source.withValue(clock) {
                let deadline = clock.after(.seconds(1))
                do {
                    _ = try await withOperationDeadline(
                        deadline,
                        timeoutError: DeadlineFixtureError.expired,
                        operation: {
                            await clock.waitForSleeper(until: deadline)
                            clock.advanceNowWithoutWakingSleepers(by: .seconds(1))
                            throw fixtureError
                        }
                    )
                    XCTFail("Non-preserved errors after deadline must become timeoutError")
                } catch {
                    XCTAssertEqual(error as? DeadlineFixtureError, .expired)
                }
            }
        }

        // 2. Deadline expires during onOperationFinished.
        for fixtureError in cases {
            let clock = DeterministicDeadlineClock()
            await AgentClock.$source.withValue(clock) {
                let deadline = clock.after(.seconds(1))
                let enteredFinished = DeadlineTestSignal()
                let releaseFinished = DeadlineTestSignal()

                let task = Task<Int, Error> {
                    try await withOperationDeadline(
                        deadline,
                        timeoutError: DeadlineFixtureError.expired,
                        operation: { throw fixtureError },
                        onOperationFinished: {
                            await enteredFinished.signal()
                            await releaseFinished.wait()
                        }
                    )
                }
                defer { Task { await releaseFinished.signal() } }

                await enteredFinished.wait()
                await clock.waitForSleeper(until: deadline)
                clock.advance(by: .seconds(1))

                do {
                    _ = try await task.value
                    XCTFail("Non-preserved errors must still be overridden by deadline expiry")
                } catch {
                    XCTAssertEqual(error as? DeadlineFixtureError, .expired)
                }
            }
        }

        // 3. Enclosing task cancelled during onOperationFinished.
        for fixtureError in cases {
            let clock = DeterministicDeadlineClock()
            await AgentClock.$source.withValue(clock) {
                let deadline = clock.after(.seconds(10))
                let enteredFinished = DeadlineTestSignal()
                let releaseFinished = DeadlineTestSignal()

                let task = Task<Int, Error> {
                    try await withOperationDeadline(
                        deadline,
                        timeoutError: DeadlineFixtureError.expired,
                        operation: { throw fixtureError },
                        onOperationFinished: {
                            await enteredFinished.signal()
                            await releaseFinished.wait()
                        }
                    )
                }
                defer { Task { await releaseFinished.signal() } }

                await enteredFinished.wait()
                task.cancel()

                do {
                    _ = try await task.value
                    XCTFail("Non-preserved errors must still be overridden by cancellation")
                } catch {
                    XCTAssertTrue(error is CancellationError)
                }
            }
        }
    }
}

private actor CompletionProbe {
    private(set) var count = 0

    func mark() {
        count += 1
    }
}

private actor DeadlineTestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class DeterministicDeadlineClock: AgentClockSource, @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset = Duration.zero
    private var sleepers: [UUID: (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<UUID> = []
    private var instantWaiters: [(instant: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Never>)] = []

    var now: ContinuousClock.Instant { lock.withLock { origin.advanced(by: offset) } }

    func after(_ duration: Duration) -> ContinuousClock.Instant { now.advanced(by: duration) }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var ready: [CheckedContinuation<Void, Never>] = []
                let outcome: Result<Void, Error>?
                lock.lock()
                if cancelled.remove(id) != nil || Task.isCancelled {
                    outcome = .failure(CancellationError())
                } else if deadline <= origin.advanced(by: offset) {
                    outcome = .success(())
                } else {
                    outcome = nil
                    sleepers[id] = (deadline, continuation)
                    ready = instantWaiters.filter { $0.instant == deadline }.map(\.continuation)
                    instantWaiters.removeAll { $0.instant == deadline }
                }
                lock.unlock()
                if let outcome { continuation.resume(with: outcome) }
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                if let sleeper = sleepers.removeValue(forKey: id) { return sleeper.continuation }
                cancelled.insert(id)
                return nil
            }
            sleeper?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            offset += duration
            let current = origin.advanced(by: offset)
            let ids = sleepers.filter { $0.value.deadline <= current }.map(\.key)
            return ids.compactMap { sleepers.removeValue(forKey: $0)?.continuation }
        }
        due.forEach { $0.resume() }
    }

    /// Moves monotonic `now` forward without resuming pending timer sleepers yet.
    func advanceNowWithoutWakingSleepers(by duration: Duration) {
        lock.withLock { offset += duration }
    }

    func waitForSleeper(until instant: ContinuousClock.Instant) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if sleepers.values.contains(where: { $0.deadline == instant }) { return true }
                instantWaiters.append((instant, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

private enum DeadlineFixtureError: Error, Equatable {
    case expired
    case other
}

private enum PreservedFixtureError: Error, Equatable, OperationDeadlinePreservedError {
    case preserved
    case notPreserved

    var preservesOverDeadlineAndCancellation: Bool {
        self == .preserved
    }
}
