import AgentModels
import Foundation
import Testing

/// A clock for deadline tests: time moves only when the test advances it, so a deadline
/// passes exactly where the test says, however busy the machine is.
final class ManualAgentClock: AgentClockSource, @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset = Duration.zero
    private var sleepers: [UUID: (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<UUID> = []
    private var sleeperWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var instantWaiters: [(instant: ContinuousClock.Instant, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var instantTokens: [UUID] = []

    var now: ContinuousClock.Instant { lock.withLock { origin.advanced(by: offset) } }

    /// An instant `duration` after the current manual time.
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
                    let count = sleepers.count
                    ready = sleeperWaiters.filter { $0.count <= count }.map(\.continuation)
                    let armed = sleepers.values.filter { $0.deadline == deadline }.count
                    let due = { (waiter: (instant: ContinuousClock.Instant, count: Int, continuation: CheckedContinuation<Void, Never>)) in
                        waiter.instant == deadline && waiter.count <= armed
                    }
                    ready += instantWaiters.filter(due).map(\.continuation)
                    sleeperWaiters.removeAll { $0.count <= count }
                    let kept = zip(instantWaiters, instantTokens).filter { !due($0.0) }
                    instantWaiters = kept.map(\.0); instantTokens = kept.map(\.1)
                }
                lock.unlock()
                if let outcome { continuation.resume(with: outcome) }
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                if let sleeper = sleepers.removeValue(forKey: id) { return sleeper.continuation }
                cancelled.insert(id); return nil
            }
            sleeper?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleep whose instant has come.
    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            offset += duration
            let current = origin.advanced(by: offset)
            let ids = sleepers.filter { $0.value.deadline <= current }.map(\.key)
            return ids.compactMap { sleepers.removeValue(forKey: $0)?.continuation }
        }
        due.forEach { $0.resume() }
    }

    /// Waits until at least `count` sleeps are pending (for example the Run's deadline timer).
    func waitForSleepers(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if sleepers.count >= count { return true }
                sleeperWaiters.append((count, continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }

    var pendingSleepers: Int { lock.withLock { sleepers.count } }

    func hasSleeper(until instant: ContinuousClock.Instant) -> Bool {
        lock.withLock { sleepers.values.contains { $0.deadline == instant } }
    }

    /// Waits until something sleeps until exactly `instant`. On a manual clock a limit
    /// computed as "now + limit" lands on a known instant, so the test can tell that the
    /// limit's timer is armed before it moves time past it.
    func waitForSleeper(until instant: ContinuousClock.Instant, count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async {
        let token = UUID()
        let bound = Task { [weak self] in
            // A real-time safety bound: a timer that is never armed fails the test instead of hanging it.
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self else { return }
            let expired = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard let index = self.instantTokens.firstIndex(of: token) else { return nil }
                self.instantTokens.remove(at: index)
                return self.instantWaiters.remove(at: index).continuation
            }
            if let expired {
                Issue.record("No timer was armed for the expected instant", sourceLocation: sourceLocation)
                expired.resume()
            }
        }
        defer { bound.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if sleepers.values.filter({ $0.deadline == instant }).count >= count { return true }
                instantWaiters.append((instant, count, continuation)); instantTokens.append(token); return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Arms-then-passes: waits for the timer at `now + duration`, then moves time to it.
    func advanceWhenArmed(by duration: Duration, timers: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitForSleeper(until: after(duration), count: timers, sourceLocation: sourceLocation)
        advance(by: duration)
    }
}

/// Runs `body` with run, tool and authorization deadlines measured on `clock`.
func withManualClock<T: Sendable>(_ body: (ManualAgentClock) async throws -> T) async rethrows -> T {
    let clock = ManualAgentClock()
    return try await AgentClock.$source.withValue(clock) { try await body(clock) }
}

extension ManualAgentClock {
    /// The manual clock installed for the running test.
    static var current: ManualAgentClock {
        guard let clock = AgentClock.source as? ManualAgentClock else {
            preconditionFailure("The test needs the .manualClock trait")
        }
        return clock
    }
}

/// Gives each test case its own manual clock. Run, tool and authorization deadlines then
/// pass only when the test advances the clock, so a test whose limits are only safety
/// bounds does not fail because the machine is busy.
struct ManualClockTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        try await AgentClock.$source.withValue(ManualAgentClock()) { try await function() }
    }
}

extension Trait where Self == ManualClockTrait {
    static var manualClock: Self { .init() }
}

/// A one-shot signal for ordering steps of a clock test.
actor ClockTestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A flag a test can set from any task and read without waiting.
final class ClockTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
