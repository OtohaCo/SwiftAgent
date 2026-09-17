import AgentModels

actor AgentEventEmitter {
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let requiresConsumer: Bool
    private var finished = false
    private var activeTools: [ToolCallID] = []
    private var reservedCompletions = Set<ToolCallID>()
    private var pendingTermination: AgentRunTermination?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ continuation: AsyncStream<AgentEvent>.Continuation, requiresConsumer: Bool = true) {
        self.continuation = continuation
        self.requiresConsumer = requiresConsumer
    }

    func start(_ info: AgentRunInfo) {
        continuation.yield(.runStarted(info))
    }

    func send(_ event: AgentEvent) throws {
        try Task.checkCancellation()
        guard !finished, pendingTermination == nil else { throw CancellationError() }
        switch event {
        case .toolStarted(let call): activeTools.append(call.id)
        case .toolCompleted(let result): activeTools.removeAll { $0 == result.callID }
        case .toolFailed(let id, _): activeTools.removeAll { $0 == id }
        default: break
        }
        if case .terminated = continuation.yield(event), requiresConsumer { throw CancellationError() }
    }

    func failIfActive(_ id: ToolCallID, failure: AgentFailure) throws {
        guard activeTools.contains(id) else { return }
        try send(.toolFailed(id, failure))
    }

    func reserveCompletion(_ id: ToolCallID) throws {
        try Task.checkCancellation()
        guard !finished, pendingTermination == nil, activeTools.contains(id),
              reservedCompletions.insert(id).inserted else { throw CancellationError() }
    }

    func commitCompletion(_ result: ToolResultMessage, receipt: AgentToolReceipt?) throws {
        guard reservedCompletions.remove(result.callID) != nil else { throw CancellationError() }
        activeTools.removeAll { $0 == result.callID }
        var disconnected = false
        if let receipt, case .terminated = continuation.yield(.toolReceiptValidated(receipt)) { disconnected = true }
        if case .terminated = continuation.yield(.toolCompleted(result)) { disconnected = true }
        finishIfReady()
        if disconnected && requiresConsumer { throw CancellationError() }
    }

    func abortCompletion(_ id: ToolCallID, failure: AgentFailure) {
        guard reservedCompletions.remove(id) != nil else { return }
        activeTools.removeAll { $0 == id }
        continuation.yield(.toolFailed(id, failure))
        finishIfReady()
    }

    func finish(_ termination: AgentRunTermination) async {
        guard !finished else { return }
        if pendingTermination == nil { pendingTermination = termination }
        finishIfReady()
        if !finished { await withCheckedContinuation { finishWaiters.append($0) } }
    }

    private func finishIfReady() {
        guard !finished, reservedCompletions.isEmpty, let termination = pendingTermination else { return }
        finished = true
        for activeTool in activeTools {
            switch termination {
            case .failed(let failure): continuation.yield(.toolFailed(activeTool, failure))
            case .cancelled: continuation.yield(.toolFailed(activeTool, .cancelled))
            case .result: break
            }
        }
        activeTools.removeAll()
        continuation.yield(.runFinished(termination))
        continuation.finish()
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
