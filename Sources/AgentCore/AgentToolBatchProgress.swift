import AgentModels
import AgentTools

/// Serial result commits keep canonical history independent of executor completion order.
actor AgentToolBatchProgress {
    private var prefix: [ModelMessage]
    private let response: ModelResponse
    private let budget: AgentBudget
    private let lifecycle: AgentLoopLifecycle?
    private let emitter: AgentEventEmitter?
    private var results: [Int: ToolResultMessage] = [:]
    private var receipts: [AgentToolReceipt] = []
    private var executedMutation = false
    private var canonicalHistory: [ModelMessage]?

    init(prefix: [ModelMessage], response: ModelResponse, budget: AgentBudget,
         lifecycle: AgentLoopLifecycle?, emitter: AgentEventEmitter?) {
        self.prefix = prefix
        self.response = response
        self.budget = budget
        self.lifecycle = lifecycle
        self.emitter = emitter
    }

    func record(index: Int, call: PreparedToolCall, result: ToolResult<JSONValue>) async throws {
        var reserved = false
        do {
            try budget.checkActive()
            let message = ToolResultMessage(callID: call.call.id, content: [.json(result.output)], isError: false)
            try await emitter?.reserveCompletion(call.call.id)
            reserved = true
            var proposed = results
            proposed[index] = message
            let committedHistory = history(proposed)
            if call.policy.effect == .mutation {
                guard let receipt = result.receipt else { throw ToolReceiptError.missing }
                if result.isIdempotentReplay, let lifecycle {
                    let canonical = try await lifecycle.checkpoint(committedHistory, [])
                    updateCanonicalPrefix(canonical, committedHistory: committedHistory)
                } else if let commitMutation = lifecycle?.commitMutation {
                    let canonical = try await commitMutation(call.call.id, receipt, result.output, committedHistory, [])
                    updateCanonicalPrefix(canonical, committedHistory: committedHistory)
                    executedMutation = true
                } else {
                    try await lifecycle?.recordMutationReceipt(call.call.id, receipt, result.output)
                    if let lifecycle {
                        let canonical = try await lifecycle.checkpoint(committedHistory, [])
                        updateCanonicalPrefix(canonical, committedHistory: committedHistory)
                    }
                    executedMutation = true
                }
            } else {
                if let lifecycle {
                    let canonical = try await lifecycle.checkpoint(committedHistory, [])
                    updateCanonicalPrefix(canonical, committedHistory: committedHistory)
                }
            }
            results = proposed
            let receipt = result.receipt.map { AgentToolReceipt(callID: call.call.id, effect: call.policy.effect, receipt: $0) }
            if let receipt { receipts.append(receipt) }
            // A committed checkpoint must be reflected in events even if cancellation arrived afterward.
            try await emitter?.commitCompletion(message, receipt: receipt)
        } catch {
            // The executor already returned. Quarantine persistence must not
            // pin the emitter's reserved completion, or finish() waits forever.
            let exposed: any Error
            if call.policy.effect == .mutation, !result.isIdempotentReplay {
                let mark = lifecycle?.markMutationNeedsReconciliation
                let callID = call.call.id
                exposed = await AgentMutationPersistenceError.capturing(settlement: error) {
                    if let mark { try await mark(callID) }
                }
            } else {
                exposed = error
            }
            if reserved {
                await emitter?.abortCompletion(call.call.id, failure: AgentFailure(exposed))
            }
            throw exposed
        }
    }

    func completed() -> (history: [ModelMessage], receipts: [AgentToolReceipt], count: Int, executedMutation: Bool) {
        (canonicalHistory ?? history(results), receipts, results.count, executedMutation)
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

    private func updateCanonicalPrefix(_ history: [ModelMessage], committedHistory: [ModelMessage]) {
        canonicalHistory = history
        let transcript = Array(committedHistory.dropFirst(prefix.count))
        guard !transcript.isEmpty, history.count >= transcript.count,
              history.suffix(transcript.count).elementsEqual(transcript) else {
            prefix = history
            return
        }
        prefix = Array(history.dropLast(transcript.count))
    }
}
