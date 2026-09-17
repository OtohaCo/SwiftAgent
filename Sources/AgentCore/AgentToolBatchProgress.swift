import AgentModels
import AgentTools

/// Serial result commits keep canonical history independent of executor completion order.
actor AgentToolBatchProgress {
    private let prefix: [ModelMessage]
    private let response: ModelResponse
    private let budget: AgentBudget
    private let lifecycle: AgentLoopLifecycle?
    private let emitter: AgentEventEmitter?
    private var results: [Int: ToolResultMessage] = [:]
    private var receipts: [AgentToolReceipt] = []

    init(prefix: [ModelMessage], response: ModelResponse, budget: AgentBudget,
         lifecycle: AgentLoopLifecycle?, emitter: AgentEventEmitter?) {
        self.prefix = prefix
        self.response = response
        self.budget = budget
        self.lifecycle = lifecycle
        self.emitter = emitter
    }

    func record(index: Int, call: PreparedToolCall, result: ToolResult<JSONValue>) async throws {
        do {
            try budget.checkActive()
            let message = ToolResultMessage(callID: call.call.id, content: [.json(result.output)], isError: false)
            try await emitter?.reserveCompletion(call.call.id)
            var proposed = results
            proposed[index] = message
            let committedHistory = history(proposed)
            if call.policy.effect == .mutation {
                guard let receipt = result.receipt else { throw ToolReceiptError.missing }
                if let commitMutation = lifecycle?.commitMutation {
                    try await commitMutation(call.call.id, receipt, committedHistory, [])
                } else {
                    try await lifecycle?.recordMutationReceipt(call.call.id, receipt)
                    try await lifecycle?.checkpoint(committedHistory, [])
                }
            } else {
                try await lifecycle?.checkpoint(committedHistory, [])
            }
            results = proposed
            let receipt = result.receipt.map { AgentToolReceipt(callID: call.call.id, effect: call.policy.effect, receipt: $0) }
            if let receipt { receipts.append(receipt) }
            // A committed checkpoint must be reflected in events even if cancellation arrived afterward.
            try await emitter?.commitCompletion(message, receipt: receipt)
        } catch {
            // The executor already returned. Any failure while settling or committing
            // must quarantine a mutation before the run reports its failure.
            if call.policy.effect == .mutation {
                try await lifecycle?.markMutationNeedsReconciliation(call.call.id)
            }
            await emitter?.abortCompletion(call.call.id, failure: AgentFailure(error))
            throw error
        }
    }

    func completed() -> (history: [ModelMessage], receipts: [AgentToolReceipt], count: Int) {
        (history(results), receipts, results.count)
    }

    private func history(_ results: [Int: ToolResultMessage]) -> [ModelMessage] {
        let indices = results.keys.sorted()
        guard !indices.isEmpty else { return prefix }
        let calls = indices.map { response.toolCalls[$0] }
        let content = calls.count == response.toolCalls.count ? response.content : response.content.filter {
            if case .providerContinuation = $0 { return false }
            return true
        }
        return prefix + [.assistant(content: content, toolCalls: calls)] + indices.compactMap { results[$0].map(ModelMessage.tool) }
    }
}
