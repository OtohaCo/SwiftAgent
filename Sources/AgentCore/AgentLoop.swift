import AgentModels
import AgentTools
import Foundation

/// Sole owner of model turns and tool-result feedback. Run state is local to each invocation.
public struct AgentLoop: Sendable {
    private let model: ModelID
    private let provider: any ModelProvider
    private let tools: ToolRegistry

    public init(model: ModelID, provider: any ModelProvider, tools: ToolRegistry) {
        self.model = model
        self.provider = provider
        self.tools = tools
    }

    public func run(
        messages: [ModelMessage], sessionID: UUID, runID: UUID = UUID(), budget: AgentBudget,
        structuredOutput: StructuredOutputSchema? = nil
    ) async throws -> AgentLoopResult {
        try await execute(messages: messages, sessionID: sessionID, runID: runID, budget: budget,
                          structuredOutput: structuredOutput, emitter: nil)
    }

    public func events(
        messages: [ModelMessage], sessionID: UUID, runID: UUID = UUID(), budget: AgentBudget,
        structuredOutput: StructuredOutputSchema? = nil
    ) -> AsyncStream<AgentEvent> {
        let cancelledAtCreation = Task.isCancelled
        return AsyncStream { continuation in
            let emitter = AgentEventEmitter(continuation)
            let worker = Task {
                do {
                    _ = try await execute(messages: messages, sessionID: sessionID, runID: runID, budget: budget,
                        structuredOutput: structuredOutput, emitter: emitter, cancelledAtCreation: cancelledAtCreation)
                } catch { /* execute publishes the terminal error event. */ }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    func execute(
        messages: [ModelMessage], sessionID: UUID, runID: UUID, budget: AgentBudget,
        structuredOutput: StructuredOutputSchema?, emitter: AgentEventEmitter?, cancelledAtCreation: Bool = false,
        lifecycle: AgentLoopLifecycle? = nil
    ) async throws -> AgentLoopResult {
        await emitter?.start(.init(sessionID: sessionID, runID: runID, model: model))
        let evidenceLedger = lifecycle?.evidenceLedger ?? EvidenceLedger()
        do {
            if cancelledAtCreation { throw CancellationError() }
            let result = try await withAgentDeadline(budget.deadline) {
                try await runBody(messages: messages, sessionID: sessionID, runID: runID,
                                  budget: budget, structuredOutput: structuredOutput, emitter: emitter, lifecycle: lifecycle, evidenceLedger: evidenceLedger)
            }
            await lifecycle?.beforeFinish()
            await emitter?.finish(.result(result))
            return result
        } catch {
            await lifecycle?.beforeFinish()
            await emitter?.finish(error is CancellationError ? .cancelled : .failed(AgentFailure(error)))
            throw error
        }
    }

    private func runBody(
        messages: [ModelMessage], sessionID: UUID, runID: UUID, budget: AgentBudget,
        structuredOutput: StructuredOutputSchema?, emitter: AgentEventEmitter?, lifecycle: AgentLoopLifecycle?, evidenceLedger: EvidenceLedger
    ) async throws -> AgentLoopResult {
        try budget.checkActive()
        guard provider.descriptor.id.utf8.elementsEqual(model.provider.utf8) else { throw AgentLoopError.providerMismatch }
        var required: ModelCapabilities = []
        if !tools.definitions.isEmpty { required.formUnion([.tools, .multiTurn]) }
        if messages.contains(where: { $0.role == .assistant || $0.role == .tool }) { required.insert(.multiTurn) }
        if structuredOutput != nil { required.insert(.structuredOutput) }
        let missing = required.subtracting(provider.descriptor.capabilities)
        guard missing.isEmpty else { throw AgentLoopError.unsupportedCapabilities(missing) }
        var history = messages
        var modelTurns = 0
        var toolCalls = 0
        var receipts: [AgentToolReceipt] = []
        var usedCallIDs = Set<ToolCallID>()
        for message in messages {
            switch message {
            case .assistant(_, let calls): usedCallIDs.formUnion(calls.map(\.id))
            case .tool(let result): usedCallIDs.insert(result.callID)
            default: break
            }
        }
        while true {
            try budget.checkActive()
            guard modelTurns < budget.maxModelTurns else { throw AgentLoopError.modelTurnLimitReached }
            if let lifecycle {
                let inputs = try await lifecycle.control.takeSteering(atTermination: false)
                try await applySteering(inputs, to: &history, lifecycle: lifecycle, emitter: emitter)
            }
            if modelTurns > 0 && !provider.descriptor.capabilities.contains(.multiTurn) {
                throw AgentLoopError.unsupportedCapabilities(.multiTurn)
            }
            modelTurns += 1
            try await emitter?.send(.turnStarted(modelTurns))
            try budget.checkActive()
            let request = ModelRequest(model: model, messages: history, tools: tools.definitions, structuredOutput: structuredOutput)
            var accumulator = ModelEventAccumulator()
            for try await event in provider.stream(request: request) {
                try budget.checkActive()
                try accumulator.append(event)
                if case .responseStarted(let info) = event { try requireConfiguredModel(info.model) }
                if case .responseCompleted = event { continue }
                try await emitter?.send(.model(event))
            }
            try budget.checkActive()
            let response = try accumulator.finish()
            try requireConfiguredModel(response.info.model)
            try await emitter?.send(.model(.responseCompleted(response)))
            if response.stopReason == .cancelled { throw CancellationError() }
            if let lifecycle {
                let inputs = try await lifecycle.control.takeSteering(atTermination: response.stopReason != .toolCalls)
                if !inputs.isEmpty {
                    guard modelTurns < budget.maxModelTurns else { throw AgentLoopError.modelTurnLimitReached }
                    try await applySteering(inputs, to: &history, lifecycle: lifecycle, emitter: emitter)
                    continue
                }
            }
            if response.stopReason != .toolCalls {
                let outcome: AgentLoopOutcome
                switch response.stopReason {
                case .endTurn, .stopSequence: outcome = .completed
                case .refusal: outcome = .refused
                case .cancelled: throw CancellationError()
                default: outcome = .incomplete(response.stopReason)
                }
                // Unexecuted proposals stay in the terminal response, not model-ready history.
                if !response.content.isEmpty { history.append(.assistant(content: response.content, toolCalls: [])) }
                try await lifecycle?.checkpoint(history, [])
                return AgentLoopResult(response: response, history: history, outcome: outcome,
                                       modelTurns: modelTurns, toolCalls: toolCalls, receipts: receipts)
            }
            guard modelTurns < budget.maxModelTurns else { throw AgentLoopError.modelTurnLimitReached }
            guard response.toolCalls.count <= budget.maxToolCalls - toolCalls else { throw AgentLoopError.toolCallLimitReached }
            let prepared = try response.toolCalls.map { call in
                guard usedCallIDs.insert(call.id).inserted else { throw AgentLoopError.reusedToolCallID(call.id) }
                return try tools.prepare(call, context: ToolContext(sessionID: sessionID, runID: runID,
                    callID: call.id, deadline: budget.deadline, idempotencyKey: "\(runID.uuidString)/\(call.id.rawValue)", evidenceLedger: evidenceLedger))
            }
            let prefixCount = history.count
            history.append(.assistant(content: response.content, toolCalls: response.toolCalls))
            for (index, call) in prepared.enumerated() {
                try budget.checkActive()
                try await emitter?.send(.toolStarted(call.call))
                try budget.checkActive()
                let now = ContinuousClock.now
                let remaining = now.duration(to: budget.deadline)
                let timeout = min(call.policy.timeout, remaining)
                let toolDeadline = now.advanced(by: timeout)
                let timeoutError: AgentLoopError = timeout == remaining ? .deadlineExceeded : .toolTimedOut(call.call.id)
                let result = try await withAgentDeadline(toolDeadline, timeoutError: timeoutError) {
                    try await call.invoke(deadline: toolDeadline)
                }
                try budget.checkActive()
                toolCalls += 1
                let message = ToolResultMessage(callID: call.call.id, content: [.json(result.output)], isError: false)
                history.append(.tool(message))
                if let lifecycle {
                    let completed = Array(response.toolCalls.prefix(index + 1))
                    let checkpoint = Array(history.prefix(prefixCount))
                        + [.assistant(content: response.content, toolCalls: completed)]
                        + Array(history.suffix(index + 1))
                    try await lifecycle.checkpoint(checkpoint, [])
                }
                if let receipt = result.receipt {
                    let validated = AgentToolReceipt(callID: call.call.id, effect: call.policy.effect, receipt: receipt)
                    receipts.append(validated)
                    try await emitter?.send(.toolReceiptValidated(validated))
                }
                try await emitter?.send(.toolCompleted(message))
            }
        }
    }

    private func applySteering(_ inputs: [AgentSteeringInput], to history: inout [ModelMessage],
                               lifecycle: AgentLoopLifecycle, emitter: AgentEventEmitter?) async throws {
        guard !inputs.isEmpty else { return }
        history.append(contentsOf: inputs.map { .user([.text($0.text)]) })
        try await lifecycle.checkpoint(history, inputs)
        await lifecycle.control.acknowledge(inputs)
        for input in inputs { try await emitter?.send(.steeringApplied(id: input.id, text: input.text)) }
    }

    private func requireConfiguredModel(_ responseModel: ModelID) throws {
        guard responseModel.provider.utf8.elementsEqual(model.provider.utf8),
              responseModel.name.utf8.elementsEqual(model.name.utf8) else { throw AgentLoopError.modelMismatch }
    }
}

public enum AgentLoopOutcome: Equatable, Sendable {
    case completed
    case refused
    case incomplete(StopReason)
}

public struct AgentLoopResult: Equatable, Sendable {
    public let response: ModelResponse
    public let history: [ModelMessage]
    public let outcome: AgentLoopOutcome
    public let modelTurns: Int
    public let toolCalls: Int
    public let receipts: [AgentToolReceipt]
}

public enum AgentLoopError: Error, Equatable, Sendable {
    case modelMismatch
    case providerMismatch
    case unsupportedCapabilities(ModelCapabilities)
    case invalidBudget
    case modelTurnLimitReached
    case toolCallLimitReached
    case deadlineExceeded
    case reusedToolCallID(ToolCallID)
    case toolTimedOut(ToolCallID)
}
