import AgentModels

/// A model request still in flight: the Run's end records it as stopped when the turn cannot, because a
/// deadline or a stop ends the Run without waiting for the turn.
struct AgentPendingModelRequest: Sendable {
    let model: ModelID
    let ordinal: Int
    let since: ContinuousClock.Instant
    let responseID: String?
    let usage: ModelUsage

    func stopped(at end: ContinuousClock.Instant) -> ModelRequestAttempt {
        .init(ordinal: ordinal, model: model, candidate: nil, responseID: responseID, usage: usage,
              outcome: .cancelled, duration: since.duration(to: end))
    }
}

/// The physical requests behind one model turn, so a Run that reports them records each exactly once: the
/// ones the provider reports itself, and the one the stream describes when the provider did not report it.
struct AgentModelRequestTracker {
    private let model: ModelID
    private var since = ContinuousClock.now
    private var reported = 0
    private var completionReported = false
    /// The provider's last event reported a failed request, so a failure it throws next is that request's.
    private var failureReportedLast = false

    init(model: ModelID) {
        self.model = model
    }

    mutating func providerReported(_ attempt: ModelRequestAttempt) {
        reported += 1
        since = .now
        switch attempt.outcome {
        case .completed: completionReported = true; failureReportedLast = false
        case .failed: failureReportedLast = true
        case .cancelled: failureReportedLast = false
        }
    }

    /// Any event other than a report: whatever ends the stream next is no longer a reported failure.
    mutating func observedEvent() {
        failureReportedLast = false
    }

    /// The request in flight with what it reported so far; nil once the provider reported the one that answered.
    func pending(_ accumulator: ModelEventAccumulator) -> AgentPendingModelRequest? {
        guard !completionReported else { return nil }
        return .init(model: model, ordinal: reported + 1, since: since,
                     responseID: accumulator.startedResponse?.id, usage: accumulator.reportedUsage)
    }

    /// The record of a request whose response completed, unless the provider reported it.
    func unreported(completing response: ModelResponse) -> ModelRequestAttempt? {
        guard !completionReported else { return nil }
        return .init(ordinal: reported + 1, model: model, candidate: nil, responseID: response.info.id,
                     usage: response.usage, outcome: .completed(response.stopReason), duration: since.duration(to: .now))
    }

    /// The record of a request that ended with `error`, unless the provider reported it. A cancellation
    /// right after a reported failure is taken as stopping the provider's next request.
    func unreported(after error: any Error, accumulator: ModelEventAccumulator) -> ModelRequestAttempt? {
        var replay = accumulator
        if let response = try? replay.finish() { return unreported(completing: response) }
        guard let pending = pending(accumulator) else { return nil }
        switch error {
        case is CancellationError: return pending.stopped(at: .now)
        case _ where failureReportedLast: return nil
        case is ModelProviderError, is ModelStreamError:
            return .init(ordinal: pending.ordinal, model: model, candidate: nil, responseID: pending.responseID,
                         usage: pending.usage, outcome: .failed(.init(classifying: error)), duration: since.duration(to: .now))
        // The runtime stopped reading: a deadline, a closed consumer, or a refusal of what had arrived.
        default: return pending.stopped(at: .now)
        }
    }
}
