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
        try await withAgentDeadline(budget.deadline) {
            try await runBody(messages: messages, sessionID: sessionID, runID: runID,
                              budget: budget, structuredOutput: structuredOutput)
        }
    }

    private func runBody(
        messages: [ModelMessage], sessionID: UUID, runID: UUID, budget: AgentBudget,
        structuredOutput: StructuredOutputSchema?
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
            modelTurns += 1
            let request = ModelRequest(model: model, messages: history, tools: tools.definitions, structuredOutput: structuredOutput)
            var accumulator = ModelEventAccumulator()
            for try await event in provider.stream(request: request) {
                try budget.checkActive()
                try accumulator.append(event)
            }
            try budget.checkActive()
            let response = try accumulator.finish()
            guard response.info.model.provider.utf8.elementsEqual(model.provider.utf8),
                  response.info.model.name.utf8.elementsEqual(model.name.utf8) else {
                throw AgentLoopError.modelMismatch
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
                return AgentLoopResult(response: response, history: history, outcome: outcome,
                                       modelTurns: modelTurns, toolCalls: toolCalls)
            }
            guard modelTurns < budget.maxModelTurns else { throw AgentLoopError.modelTurnLimitReached }
            guard response.toolCalls.count <= budget.maxToolCalls - toolCalls else { throw AgentLoopError.toolCallLimitReached }
            let prepared = try response.toolCalls.map { call in
                guard usedCallIDs.insert(call.id).inserted else { throw AgentLoopError.reusedToolCallID(call.id) }
                return try tools.prepare(call, context: ToolContext(sessionID: sessionID, runID: runID,
                    callID: call.id, deadline: budget.deadline, idempotencyKey: "\(runID.uuidString)/\(call.id.rawValue)"))
            }
            history.append(.assistant(content: response.content, toolCalls: response.toolCalls))
            for call in prepared {
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
                history.append(.tool(.init(callID: call.call.id, content: [.json(result.output)], isError: false)))
            }
        }
    }
}

public enum AgentLoopOutcome: Equatable, Sendable {
    case completed
    case refused
    case incomplete(StopReason)
}

public struct AgentLoopResult: Sendable {
    public let response: ModelResponse
    public let history: [ModelMessage]
    public let outcome: AgentLoopOutcome
    public let modelTurns: Int
    public let toolCalls: Int
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
