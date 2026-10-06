import AgentModels
import AgentTools

/// Serial result commits keep canonical history independent of executor completion order.
actor AgentToolBatchProgress {
    private var prefix: [ModelMessage]
    private let response: ModelResponse
    /// The response's calls as they are replayed; differs only where arguments were replaced.
    private let calls: [ToolCall]
    private let budget: AgentBudget
    private let lifecycle: AgentLoopLifecycle?
    private let emitter: AgentEventEmitter?
    private var results: [Int: ToolResultMessage] = [:]
    private var receipts: [AgentToolReceipt] = []
    private var executedMutation = false
    private var declaredTools: Set<String> = []
    private var canonicalHistory: [ModelMessage]?
    private var pendingRejections: [ToolCallID]

    /// `rejected` holds results, by response index, for calls refused before preparation completed
    /// (arguments the model must correct). They commit with the batch; `index` in `record` is a response index.
    init(prefix: [ModelMessage], response: ModelResponse, calls: [ToolCall]? = nil,
         rejected: [Int: ToolResultMessage] = [:], budget: AgentBudget,
         lifecycle: AgentLoopLifecycle?, emitter: AgentEventEmitter?) {
        self.prefix = prefix
        self.response = response
        self.calls = calls ?? response.toolCalls
        results = rejected
        pendingRejections = rejected.keys.sorted().compactMap { rejected[$0]?.callID }
        self.budget = budget
        self.lifecycle = lifecycle
        self.emitter = emitter
    }

    func record(index: Int, call: PreparedToolCall, result: ToolResult<JSONValue>) async throws {
        var reserved = false
        var reservedRejections: [ToolCallID] = []
        do {
            try budget.checkActive()
            var images = result.images.map(ModelContent.image)
            if !images.isEmpty, lifecycle?.keepsImages == false {
                // A journal that cannot keep images (format schema 3-9). A read-only result fails here,
                // before anything is committed. A mutation's effect already happened: its settlement is
                // kept, with each image as its text substitute, rather than quarantined.
                guard call.policy.effect == .mutation, !result.isIdempotentReplay else { throw AgentJournalError.unsupportedFormat }
                images = result.images.map { .text($0.textSubstitute) }
            }
            let message = ToolResultMessage(
                callID: call.call.id,
                content: [.json(result.output)] + images,
                isError: result.isModelVisibleError
            )
            try await emitter?.reserveCompletion(call.call.id)
            reserved = true
            reservedRejections = try await reserveRejections()
            var proposed = results
            proposed[index] = message
            let committedHistory = history(proposed)
            if result.confirmedNoEffect != nil {
                guard let commit = lifecycle?.commitNoEffectResult else { throw AgentJournalError.invalidRecord }
                let canonical = try await commit(call, result, committedHistory)
                updateCanonicalPrefix(canonical, committedHistory: committedHistory)
            } else if let commitAudit = lifecycle?.commitAuditedResult, call.auditAuthorization != nil {
                let canonical = try await commitAudit(call, result, committedHistory)
                updateCanonicalPrefix(canonical, committedHistory: committedHistory)
                if call.policy.effect == .mutation, !result.isIdempotentReplay { executedMutation = true }
                if call.policy.effect == .readOnly { await lifecycle?.recordReadOnlyResult(call.call, message) }
            } else if call.policy.effect == .mutation {
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
                    await lifecycle.recordReadOnlyResult(call.call, message)
                }
            }
            results = proposed
            // Declarations take effect only with a committed result.
            declaredTools.formUnion(result.declaredTools)
            let receipt = result.receipt.map { AgentToolReceipt(callID: call.call.id, effect: call.policy.effect, receipt: $0) }
            if let receipt { receipts.append(receipt) }
            // A committed checkpoint must be reflected in events even if cancellation arrived afterward.
            await publishRejections(reservedRejections)
            try await emitter?.commitCompletion(message, receipt: receipt)
        } catch {
            await emitter?.abortAdmissionRejections(reservedRejections)
            // The executor already returned. Quarantine persistence must not
            // pin the emitter's reserved completion, or finish() waits forever.
            // A no-effect result reached the executor but failed its atomic publication.
            // Scheduler onFailed only handles invocation failures, not this completion path.
            let settlement: any Error
            if result.confirmedNoEffect != nil {
                settlement = await AgentAuditPersistenceError.capturing(original: error) {
                    try await call.auditAuthorization?.failed(error)
                }
            } else { settlement = error }
            let exposed: any Error
            if call.policy.effect == .mutation, !result.isIdempotentReplay {
                let mark = lifecycle?.markMutationNeedsReconciliation
                let callID = call.call.id
                exposed = await AgentMutationPersistenceError.capturing(settlement: settlement) {
                    if let mark { try await mark(callID) }
                }
            } else {
                exposed = settlement
            }
            if reserved {
                await emitter?.abortCompletion(call.call.id, failure: AgentFailure(exposed))
            }
            throw exposed
        }
    }

    /// Commits a batch in which no call was prepared: only rejected results exist.
    func commitUnexecuted() async throws {
        try budget.checkActive()
        let reserved = try await reserveRejections()
        do {
            let committedHistory = history(results)
            let canonical = try await lifecycle?.checkpoint(committedHistory, []) ?? committedHistory
            updateCanonicalPrefix(canonical, committedHistory: committedHistory)
            await publishRejections(reserved)
        } catch {
            await emitter?.abortAdmissionRejections(reserved)
            throw error
        }
    }

    private func reserveRejections() async throws -> [ToolCallID] {
        let ids = pendingRejections
        if !ids.isEmpty { try await emitter?.reserveAdmissionRejections(ids) }
        return ids
    }

    private func publishRejections(_ ids: [ToolCallID]) async {
        // Later checkpoints include the same rejection results, but never publish them again.
        pendingRejections.removeAll()
        await emitter?.commitAdmissionRejections(ids)
    }

    func completed() -> (history: [ModelMessage], receipts: [AgentToolReceipt], count: Int, executedMutation: Bool,
                         declaredTools: Set<String>) {
        (canonicalHistory ?? history(results), receipts, results.count, executedMutation, declaredTools)
    }

    private func history(_ results: [Int: ToolResultMessage]) -> [ModelMessage] {
        let indices = results.keys.sorted()
        guard !indices.isEmpty else { return prefix }
        let replayed = indices.map { calls[$0] }
        // Opaque provider state describes the whole response, so discarding proposals invalidates it.
        // Replaced invalid arguments do not: providers replay the same replacement.
        let content = replayed.count == calls.count ? response.content : response.content.filter {
            if case .providerContinuation = $0 { return false }
            return true
        }
        return prefix + [.assistant(content: content, toolCalls: replayed)] + indices.compactMap { results[$0].map(ModelMessage.tool) }
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
