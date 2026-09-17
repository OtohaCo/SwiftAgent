import AgentModels
import AgentTools
import Foundation

/// Sole owner of model turns and tool-result feedback. Run state is local to each invocation.
public struct AgentLoop: Sendable {
    private let model: ModelID
    private let provider: any ModelProvider
    private let tools: ToolRegistry
    private let scheduler: ToolScheduler

    public init(model: ModelID, provider: any ModelProvider, tools: ToolRegistry, scheduler: ToolScheduler = .init()) {
        self.model = model
        self.provider = provider
        self.tools = tools
        self.scheduler = scheduler
    }

    public func run(
        messages: [ModelMessage], sessionID: UUID, runID: UUID = UUID(), budget: AgentBudget,
        structuredOutput: StructuredOutputSchema? = nil, operationID: String? = nil
    ) async throws -> AgentLoopResult {
        try await execute(messages: messages, sessionID: sessionID, runID: runID, budget: budget,
                          structuredOutput: structuredOutput, operationID: operationID, emitter: nil)
    }

    public func events(
        messages: [ModelMessage], sessionID: UUID, runID: UUID = UUID(), budget: AgentBudget,
        structuredOutput: StructuredOutputSchema? = nil, operationID: String? = nil
    ) -> AsyncStream<AgentEvent> {
        let cancelledAtCreation = Task.isCancelled
        return AsyncStream { continuation in
            let emitter = AgentEventEmitter(continuation)
            let worker = Task {
                do {
                    _ = try await execute(messages: messages, sessionID: sessionID, runID: runID, budget: budget,
                        structuredOutput: structuredOutput, operationID: operationID, emitter: emitter,
                        cancelledAtCreation: cancelledAtCreation)
                } catch { /* execute publishes the terminal error event. */ }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    public func waitForRunToDrain(sessionID: UUID, runID: UUID) async {
        async let providerDrain = waitForProviderToDrain(sessionID: sessionID, runID: runID)
        async let toolDrain = scheduler.waitForRunToDrain(sessionID: sessionID, runID: runID)
        await providerDrain
        await toolDrain
    }

    private func waitForProviderToDrain(sessionID: UUID, runID: UUID) async {
        guard let provider = provider as? any ModelProviderRunDrain else { return }
        await provider.waitForRunToDrain(sessionID: sessionID, runID: runID)
    }

    func execute(
        messages: [ModelMessage], sessionID: UUID, runID: UUID, budget: AgentBudget,
        structuredOutput: StructuredOutputSchema?, operationID: String? = nil,
        emitter: AgentEventEmitter?, cancelledAtCreation: Bool = false,
        lifecycle: AgentLoopLifecycle? = nil
    ) async throws -> AgentLoopResult {
        await emitter?.start(.init(sessionID: sessionID, runID: runID, model: model))
        let evidenceLedger = lifecycle?.evidenceLedger ?? EvidenceLedger()
        do {
            if cancelledAtCreation { throw CancellationError() }
            let result = try await withAgentDeadline(budget.deadline) {
                try await runBody(messages: messages, sessionID: sessionID, runID: runID,
                                  budget: budget, structuredOutput: structuredOutput, operationID: operationID,
                                  emitter: emitter, lifecycle: lifecycle, evidenceLedger: evidenceLedger)
            }
            await lifecycle?.beforeFinish()
            await clearMutationBoundary(sessionID: sessionID, runID: runID)
            await emitter?.finish(.result(result))
            return result
        } catch {
            await lifecycle?.beforeFinish()
            await clearMutationBoundary(sessionID: sessionID, runID: runID)
            await emitter?.finish(error is CancellationError ? .cancelled : .failed(AgentFailure(error)))
            throw error
        }
    }

    private func runBody(
        messages: [ModelMessage], sessionID: UUID, runID: UUID, budget: AgentBudget,
        structuredOutput: StructuredOutputSchema?, operationID: String?, emitter: AgentEventEmitter?,
        lifecycle: AgentLoopLifecycle?, evidenceLedger: EvidenceLedger
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
            let request = ModelRequest(model: model, messages: history, tools: tools.definitions,
                                       structuredOutput: structuredOutput, sessionID: sessionID, runID: runID)
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
                let content = checkpointContent(response, retainingToolCalls: 0)
                if !content.isEmpty { history.append(.assistant(content: content, toolCalls: [])) }
                try await lifecycle?.checkpoint(history, [])
                return AgentLoopResult(response: response, history: history, outcome: outcome,
                                       modelTurns: modelTurns, toolCalls: toolCalls, receipts: receipts)
            }
            guard modelTurns < budget.maxModelTurns else { throw AgentLoopError.modelTurnLimitReached }
            guard response.toolCalls.count <= budget.maxToolCalls - toolCalls else { throw AgentLoopError.toolCallLimitReached }
            let prepared = try response.toolCalls.map { call in
                guard usedCallIDs.insert(call.id).inserted else { throw AgentLoopError.reusedToolCallID(call.id) }
                return try tools.prepare(call, context: ToolContext(sessionID: sessionID, runID: runID,
                    callID: call.id, deadline: budget.deadline,
                    idempotencyKey: Self.idempotencyKey(operationID: operationID, runID: runID, call: call),
                    argumentsJSON: call.argumentsJSON, evidenceLedger: evidenceLedger,
                    mutationAdmission: lifecycle?.mutationAdmission))
            }
            let progress = AgentToolBatchProgress(prefix: history, response: response, budget: budget,
                                                  lifecycle: lifecycle, emitter: emitter)
            do {
                try await scheduler.execute(prepared, deadline: budget.deadline, onStarted: { call in
                    try budget.checkActive()
                    try await emitter?.send(.toolStarted(call.call))
                }, onCompleted: { index, call, result in
                    try await progress.record(index: index, call: call, result: result)
                }, onFailed: { call, error in
                    if call.policy.effect == .mutation {
                        try await lifecycle?.markMutationNeedsReconciliation(call.call.id)
                    }
                    try await emitter?.failIfActive(call.call.id, failure: AgentFailure(Self.toolError(error)))
                })
                for call in prepared where call.policy.effect == .mutation {
                    // The scheduler has completed authorization, evidence validation,
                    // durable admission and executor work before the next model turn.
                    await markMutationBoundaryIfNeeded(call, sessionID: sessionID, runID: runID)
                }
            } catch { throw Self.toolError(error) }
            let completed = await progress.completed()
            history = completed.history
            receipts.append(contentsOf: completed.receipts)
            toolCalls += completed.count
        }
    }

    private func markMutationBoundaryIfNeeded(_ call: PreparedToolCall, sessionID: UUID, runID: UUID) async {
        guard call.policy.effect == .mutation,
              let boundary = provider as? any ModelProviderMutationBoundary else { return }
        await boundary.markMutationBoundary(sessionID: sessionID, runID: runID)
    }

    private func clearMutationBoundary(sessionID: UUID, runID: UUID) async {
        guard let boundary = provider as? any ModelProviderMutationBoundary else { return }
        await boundary.clearMutationBoundary(sessionID: sessionID, runID: runID)
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

    private static func toolError(_ error: any Error) -> any Error {
        guard let error = error as? ToolSchedulerError else { return error }
        switch error {
        case .deadlineExceeded: return AgentLoopError.deadlineExceeded
        case .toolTimedOut(let id): return AgentLoopError.toolTimedOut(id)
        }
    }

    private func checkpointContent(_ response: ModelResponse, retainingToolCalls count: Int) -> [ModelContent] {
        // Opaque state describes the whole response, so discarding proposals invalidates it.
        guard count != response.toolCalls.count else { return response.content }
        return response.content.filter {
            if case .providerContinuation = $0 { return false }
            return true
        }
    }

    private static func idempotencyKey(
        operationID: String?,
        runID: UUID,
        call: ToolCall
    ) -> String {
        guard let operationID = operationID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !operationID.isEmpty else {
            return "\(runID.uuidString)/\(call.id.rawValue)"
        }

        let arguments: String
        if let value = try? JSONValue.decodeToolArguments(call.argumentsJSON) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(value) {
                arguments = String(decoding: data, as: UTF8.self)
            } else {
                arguments = call.argumentsJSON
            }
        } else {
            arguments = call.argumentsJSON
        }
        return "\(operationID)/\(call.name)/\(arguments)"
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
