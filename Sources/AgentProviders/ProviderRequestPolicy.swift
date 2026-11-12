import AgentModels
import Foundation

/// Opt-in limits for one logical model request, including its retries.
/// Idle budgets measure normalized output, not HTTP bytes or SSE heartbeats,
/// unless `idleCountsWireActivity` is set.
public struct ProviderRequestPolicy: Sendable {
    public let idleBeforeFirstOutput: Duration?
    public let idleAfterOutput: Duration?
    /// When true, bytes the provider receives also restart the idle budget, even when
    /// they decode to no `ModelEvent`: SSE comments, `ping` and lifecycle events,
    /// encrypted reasoning items and signature-only reasoning parts. Such activity
    /// never counts as output, so a request without output can still be retried.
    /// The total deadline is unaffected. Built-in adapters report activity for every
    /// received chunk; a custom adapter reports it with `ProviderWireActivity.report()`.
    public let idleCountsWireActivity: Bool
    public let totalDeadline: Duration?
    public let maximumAttempts: Int
    public let initialBackoff: Duration
    public let maximumBackoff: Duration
    public let maximumRetryAfter: Duration

    public init(idleBeforeFirstOutput: Duration? = nil, idleAfterOutput: Duration? = nil,
                totalDeadline: Duration? = nil, maximumAttempts: Int = 1,
                initialBackoff: Duration = .seconds(1), maximumBackoff: Duration = .seconds(30),
                maximumRetryAfter: Duration = .seconds(60),
                idleCountsWireActivity: Bool = false) throws {
        guard [idleBeforeFirstOutput, idleAfterOutput, totalDeadline].allSatisfy({ $0.map { $0 > .zero } ?? true }),
              (1...100).contains(maximumAttempts), initialBackoff >= .zero,
              maximumBackoff >= initialBackoff, maximumRetryAfter >= .zero else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid provider request policy.")
        }
        self.idleBeforeFirstOutput = idleBeforeFirstOutput
        self.idleAfterOutput = idleAfterOutput
        self.totalDeadline = totalDeadline
        self.maximumAttempts = maximumAttempts
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
        self.maximumRetryAfter = maximumRetryAfter
        self.idleCountsWireActivity = idleCountsWireActivity
    }

    func delay(after attempt: Int, retryAfter: Duration?, jitter: Double) -> Duration {
        var delay = initialBackoff
        for _ in 1..<max(1, attempt) {
            if delay >= maximumBackoff / 2 { delay = maximumBackoff; break }
            delay *= 2
        }
        // Equal jitter keeps the delay in [half, full] of the capped exponential.
        delay = min(delay, maximumBackoff) * (0.5 + min(1, max(0, jitter)) * 0.5)
        return max(delay, min(max(.zero, retryAfter ?? .zero), maximumRetryAfter))
    }
}

struct ProviderPolicyClock: Sendable {
    var now: @Sendable () -> Duration
    var sleep: @Sendable (Duration) async throws -> Void
    var jitter: @Sendable () -> Double

    static var continuous: Self {
        let origin = ContinuousClock.now
        return .init(now: { origin.duration(to: .now) },
                     sleep: { try await Task.sleep(for: $0) },
                     jitter: { Double.random(in: 0...1) })
    }
}

/// Wrap a configured adapter to enable request limits and retries. Defaults on
/// the underlying adapters are unchanged. Never replays after observable output.
public struct ProviderRequestPolicyProvider: ModelProvider, ModelProviderRequestValidator,
    ModelProviderRunDrain, ModelProviderMutationBoundary {
    private let inner: any ModelProvider
    private let policy: ProviderRequestPolicy
    private let clock: ProviderPolicyClock
    private let drain = ProviderRunDrain()
    public var descriptor: ModelProviderDescriptor { inner.descriptor }

    public init(wrapping provider: any ModelProvider, policy: ProviderRequestPolicy) {
        self.init(wrapping: provider, policy: policy, clock: .continuous)
    }

    init(wrapping provider: any ModelProvider, policy: ProviderRequestPolicy, clock: ProviderPolicyClock) {
        inner = provider; self.policy = policy; self.clock = clock
    }

    public func validate(request: ModelRequest) throws {
        try (inner as? any ModelProviderRequestValidator)?.validate(request: request)
    }
    public func waitForRunToDrain(sessionID: UUID, runID: UUID) async {
        await drain.wait(sessionID: sessionID, runID: runID)
        await (inner as? any ModelProviderRunDrain)?.waitForRunToDrain(sessionID: sessionID, runID: runID)
    }
    public func markMutationBoundary(sessionID: UUID, runID: UUID) async {
        await (inner as? any ModelProviderMutationBoundary)?.markMutationBoundary(sessionID: sessionID, runID: runID)
    }
    public func clearMutationBoundary(sessionID: UUID, runID: UUID) async {
        await (inner as? any ModelProviderMutationBoundary)?.clearMutationBoundary(sessionID: sessionID, runID: runID)
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let deadline = policy.totalDeadline.map { clock.now() + $0 }
            for attempt in 1...policy.maximumAttempts {
                try Task.checkCancellation()
                if let deadline, clock.now() >= deadline { throw policyTimeout(.requestDeadlineExceeded) }
                var buffered: [ModelEvent] = []
                var output = false
                do {
                    for try await event in boundedAttempt(request, deadline: deadline) {
                        // Attempt reports are independent diagnostics, including failed billed requests.
                        if case .requestAttempt = event { try emit(event); continue }
                        if policyOutput(event) {
                            if !output {
                                output = true
                                for previous in buffered { try emit(previous) }
                                buffered.removeAll()
                            }
                        }
                        if output { try emit(event) } else {
                            guard buffered.count < 1_024 else { throw ProviderJSON.invalid() }
                            buffered.append(event)
                        }
                    }
                    // The adapter contract requires a terminal; validate clean EOF even for custom providers.
                    guard output else { throw ProviderHTTPFailure.streamEndedEarly() }
                    return
                } catch is CancellationError { throw CancellationError() }
                catch let error as ModelProviderError {
                    try Task.checkCancellation()
                    guard !output, attempt < policy.maximumAttempts,
                          [.transport, .rateLimited, .unavailable, .overloaded].contains(error.kind),
                          error.diagnostic?.reason != .requestDeadlineExceeded else { throw error }
                    let delay = policy.delay(after: attempt, retryAfter: error.retryAfter, jitter: clock.jitter())
                    if let deadline, delay >= deadline - clock.now() { throw policyTimeout(.requestDeadlineExceeded) }
                    try await clock.sleep(delay)
                }
            }
        }
    }

    private func boundedAttempt(_ request: ModelRequest, deadline: Duration?) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let key = drain.begin(request)
            let state = PolicyAttemptState(continuation: continuation, policy: policy, clock: clock, deadline: deadline)
            let activity = policy.idleCountsWireActivity ? ProviderWireActivityRecorder { await state.wireActivity() } : nil
            let producer = Task {
                defer { drain.end(key) }
                await state.start()
                do {
                    try Task.checkCancellation()
                    var terminal = false
                    // The inner adapter's producer task inherits the recorder.
                    let events = ProviderWireActivity.$recorder.withValue(activity) { inner.stream(request: request) }
                    for try await event in events {
                        try Task.checkCancellation()
                        if case .responseCompleted = event { terminal = true }
                        guard await state.accept(event) else { break }
                    }
                    try Task.checkCancellation()
                    await state.finish(terminal ? nil : ProviderHTTPFailure.streamEndedEarly())
                } catch { await state.finish(error) }
            }
            continuation.onTermination = { _ in
                producer.cancel()
                Task { await state.finish(CancellationError()) }
            }
        }
    }
}

private func policyOutput(_ event: ModelEvent) -> Bool {
    switch event {
    case .responseStarted, .usage, .inputTransformations, .requestAttempt: false
    default: true
    }
}

private func policyTimeout(_ reason: ModelProviderError.Diagnostic.Reason) -> ModelProviderError {
    .init(kind: .transport, message: "Provider request exceeded its time budget.",
          diagnostic: .init(stage: .transport, reason: reason))
}

private actor PolicyAttemptState {
    let continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation
    let policy: ProviderRequestPolicy
    let clock: ProviderPolicyClock
    let deadline: Duration?
    var output = false
    var ended = false
    var generation = 0
    var timer: Task<Void, Never>?

    init(continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation,
         policy: ProviderRequestPolicy, clock: ProviderPolicyClock, deadline: Duration?) {
        self.continuation = continuation; self.policy = policy; self.clock = clock; self.deadline = deadline
    }
    func start() { schedule() }
    func wireActivity() { if !ended { schedule() } }
    func accept(_ event: ModelEvent) -> Bool {
        guard !ended else { return false }
        if policyOutput(event) { output = true; schedule() }
        if case .terminated = continuation.yield(event) { return false }
        return true
    }
    func finish(_ error: (any Error)?) {
        guard !ended else { return }
        ended = true; timer?.cancel(); timer = nil
        continuation.finish(throwing: error)
    }
    private func schedule() {
        generation += 1
        timer?.cancel()
        let idle = output ? policy.idleAfterOutput : policy.idleBeforeFirstOutput
        let remaining = deadline.map { max(.zero, $0 - clock.now()) }
        guard let wait = [idle, remaining].compactMap({ $0 }).min() else { return }
        let reason: ModelProviderError.Diagnostic.Reason = remaining.map { $0 <= wait } == true
            ? .requestDeadlineExceeded : (output ? .outputIdleTimedOut : .firstOutputTimedOut)
        let version = generation
        timer = Task {
            do { try await clock.sleep(wait); try Task.checkCancellation() } catch { return }
            expire(version, reason: reason)
        }
    }
    private func expire(_ version: Int, reason: ModelProviderError.Diagnostic.Reason) {
        guard version == generation else { return }
        finish(policyTimeout(reason))
    }
}

/// Activity on the wire of the current model request, for `ProviderRequestPolicy.idleCountsWireActivity`.
public enum ProviderWireActivity {
    @TaskLocal static var recorder: ProviderWireActivityRecorder?

    /// Report that the provider received bytes for the request being streamed. Call it from
    /// the adapter's stream (or a task it starts) when data arrives that may decode to no
    /// event. Outside a policy that counts wire activity it does nothing.
    public static func report() { recorder?.record() }
}

/// Coalesces reports: at most one restart of the idle budget is pending at a time.
final class ProviderWireActivityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var count = 0
    private let restart: @Sendable () async -> Void

    init(_ restart: @escaping @Sendable () async -> Void) { self.restart = restart }

    var reports: Int { lock.withLock { count } }

    func record() {
        guard lock.withLock({ count += 1; let start = !pending; pending = true; return start }) else { return }
        Task {
            lock.withLock { pending = false }
            await restart()
        }
    }
}
