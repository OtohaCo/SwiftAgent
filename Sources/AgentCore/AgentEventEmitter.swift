import AgentModels

actor AgentEventEmitter {
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private var finished = false
    private var activeTool: ToolCallID?

    init(_ continuation: AsyncStream<AgentEvent>.Continuation) {
        self.continuation = continuation
    }

    func start(_ info: AgentRunInfo) {
        continuation.yield(.runStarted(info))
    }

    func send(_ event: AgentEvent) throws {
        try Task.checkCancellation()
        guard !finished else { throw CancellationError() }
        switch event {
        case .toolStarted(let call): activeTool = call.id
        case .toolCompleted, .toolFailed: activeTool = nil
        default: break
        }
        if case .terminated = continuation.yield(event) { throw CancellationError() }
    }

    func finish(_ termination: AgentRunTermination) {
        guard !finished else { return }
        finished = true
        if let activeTool {
            switch termination {
            case .failed(let failure): continuation.yield(.toolFailed(activeTool, failure))
            case .cancelled: continuation.yield(.toolFailed(activeTool, .cancelled))
            case .result: break
            }
        }
        activeTool = nil
        continuation.yield(.runFinished(termination))
        continuation.finish()
    }
}
