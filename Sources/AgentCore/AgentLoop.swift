import AgentModels
import AgentTools
import Foundation

package struct AgentPreparedModelRequest: Sendable {
    package let request: ModelRequest
    package let projection: AgentContextProjection
    package let canonicalMessages: [ModelMessage]
}

/// Package orchestration for one model → tool → model loop. SDK users go through
/// `Agent`, `AgentSession` and `AgentRun`.
package struct AgentLoop: Sendable {
    private let binding: AgentModelBinding
    private let tools: ToolRegistry
    private let scheduler: ToolScheduler
    private let modelContextByteLimit: Int?
    private let journal: AgentJournal?
    private let contextEffects: AgentContextEffectLedger
    private let capabilityScope: AgentCapabilityScope?
    private let projectionDrain = AgentProjectionDrain()

    private var model: ModelID { binding.model }
    private var provider: any ModelProvider { binding.provider }

    package init(binding: AgentModelBinding, tools: ToolRegistry,
                 scheduler: ToolScheduler = .init(), modelContextByteLimit: Int? = nil,
                 journal: AgentJournal? = nil,
                 contextEffects: AgentContextEffectLedger = .init(),
                 capabilityScope: AgentCapabilityScope? = nil) {
        self.binding = binding
        self.tools = tools
        self.scheduler = scheduler
        self.modelContextByteLimit = modelContextByteLimit
        self.journal = journal
        self.contextEffects = contextEffects
        self.capabilityScope = capabilityScope
    }

    package init(model: ModelID, provider: any ModelProvider, tools: ToolRegistry, scheduler: ToolScheduler = .init()) {
        self.init(binding: .legacy(model: model, provider: provider), tools: tools, scheduler: scheduler)
    }

    package func preflight(
        messages: [ModelMessage],
        sessionID: UUID,
        runID: UUID,
        conversationRevision: UInt64,
        structuredOutput: StructuredOutputSchema?
    ) async throws -> AgentPreparedModelRequest {
        try await prepareRequest(
            messages: messages,
            sessionID: sessionID,
            runID: runID,
            conversationRevision: conversationRevision,
            contextEpoch: conversationRevision,
            modelTurn: 1,
            structuredOutput: structuredOutput
        )
    }

    package func run(
        messages: [ModelMessage], sessionID: UUID, runID: UUID = UUID(), budget: AgentBudget,
        structuredOutput: StructuredOutputSchema? = nil, operationID: String? = nil
    ) async throws -> AgentLoopResult {
        try await execute(messages: messages, sessionID: sessionID, runID: runID, budget: budget,
                          structuredOutput: structuredOutput, operationID: operationID, emitter: nil)
    }

    package func events(
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

    package func waitForRunToDrain(sessionID: UUID, runID: UUID) async {
        async let providerDrain = waitForProviderToDrain(sessionID: sessionID, runID: runID)
        async let toolDrain = scheduler.waitForRunToDrain(sessionID: sessionID, runID: runID)
        async let contextDrain = projectionDrain.wait()
        await providerDrain
        await toolDrain
        await contextDrain
    }

    private func waitForProviderToDrain(sessionID: UUID, runID: UUID) async {
        guard let provider = provider as? any ModelProviderRunDrain else { return }
        await provider.waitForRunToDrain(sessionID: sessionID, runID: runID)
    }

    func execute(
        messages: [ModelMessage], sessionID: UUID, runID: UUID, budget: AgentBudget,
        structuredOutput: StructuredOutputSchema?, operationID: String? = nil,
        emitter: AgentEventEmitter?, cancelledAtCreation: Bool = false,
        lifecycle: AgentLoopLifecycle? = nil,
        initialRequest: AgentPreparedModelRequest? = nil
    ) async throws -> AgentLoopResult {
        await emitter?.start(.init(sessionID: sessionID, runID: runID, model: model))
        let evidenceLedger = lifecycle?.evidenceLedger ?? EvidenceLedger()
        do {
            if cancelledAtCreation { throw CancellationError() }
            let result = try await withAgentDeadline(budget.deadline) {
                try await runBody(messages: messages, sessionID: sessionID, runID: runID,
                                  budget: budget, structuredOutput: structuredOutput, operationID: operationID,
                                  emitter: emitter, lifecycle: lifecycle, evidenceLedger: evidenceLedger,
                                  initialRequest: initialRequest)
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
        lifecycle: AgentLoopLifecycle?, evidenceLedger: EvidenceLedger,
        initialRequest: AgentPreparedModelRequest?
    ) async throws -> AgentLoopResult {
        try budget.checkActive()
        var history = messages
        var modelTurns = 0
        var toolCalls = 0
        var receipts: [AgentToolReceipt] = []
        var projectionRevision = initialRequest?.projection.plan.sourceRevision ?? 0
        var contextEpoch = initialRequest?.projection.plan.contextEpoch ?? 0
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
                if !inputs.isEmpty {
                    try await applySteering(inputs, to: &history, lifecycle: lifecycle, emitter: emitter)
                    (projectionRevision, contextEpoch) = try advancedProjectionCoordinates(
                        revision: projectionRevision,
                        contextEpoch: contextEpoch
                    )
                }
            }
            if modelTurns > 0 && !provider.descriptor.capabilities.contains(.multiTurn) {
                throw AgentLoopError.unsupportedCapabilities(.multiTurn)
            }
            modelTurns += 1
            try await emitter?.send(.turnStarted(modelTurns))
            try budget.checkActive()
            let preparedRequest: AgentPreparedModelRequest
            if modelTurns == 1,
               let initialRequest,
               initialRequest.canonicalMessages == history {
                preparedRequest = initialRequest
            } else {
                preparedRequest = try await prepareRequest(
                    messages: history,
                    sessionID: sessionID,
                    runID: runID,
                    conversationRevision: projectionRevision,
                    contextEpoch: contextEpoch,
                    modelTurn: modelTurns,
                    structuredOutput: structuredOutput,
                    allowUnresolvedToolTail: initialRequest == nil && modelTurns == 1
                )
            }
            let request = preparedRequest.request
            try budget.checkActive()
            var accumulator = ModelEventAccumulator()
            for try await rawEvent in provider.stream(request: request) {
                try budget.checkActive()
                let event = try scopeContinuation(rawEvent)
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
                    (projectionRevision, contextEpoch) = try advancedProjectionCoordinates(
                        revision: projectionRevision,
                        contextEpoch: contextEpoch
                    )
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
                if let lifecycle { history = try await lifecycle.checkpoint(history, []) }
                return AgentLoopResult(response: response, history: history, outcome: outcome,
                                       modelTurns: modelTurns, toolCalls: toolCalls, receipts: receipts)
            }
            guard modelTurns < budget.maxModelTurns else { throw AgentLoopError.modelTurnLimitReached }
            guard response.toolCalls.count <= budget.maxToolCalls - toolCalls else { throw AgentLoopError.toolCallLimitReached }
            let preparedCalls = try response.toolCalls.map { call in
                guard usedCallIDs.insert(call.id).inserted else { throw AgentLoopError.reusedToolCallID(call.id) }
                return try tools.prepare(call, context: ToolContext(sessionID: sessionID, runID: runID,
                    callID: call.id, deadline: budget.deadline,
                    idempotencyKey: Self.idempotencyKey(operationID: operationID, runID: runID, call: call),
                    argumentsJSON: call.argumentsJSON, evidenceLedger: evidenceLedger,
                    mutationAdmission: lifecycle?.mutationAdmission,
                    executionAdmission: capabilityScope))
            }
            let progress = AgentToolBatchProgress(prefix: history, response: response, budget: budget,
                                                  lifecycle: lifecycle, emitter: emitter)
            do {
                try await scheduler.execute(preparedCalls, deadline: budget.deadline, onStarted: { call in
                    try budget.checkActive()
                    try await capabilityScope?.check(runID: runID, resources: call.resources)
                    try await emitter?.send(.toolStarted(call.call))
                }, onCompleted: { index, call, result in
                    try await progress.record(index: index, call: call, result: result)
                }, onFailed: { call, error in
                    var exposed: any Error = Self.toolError(error)
                    if call.policy.effect == .mutation {
                        let mark = lifecycle?.markMutationNeedsReconciliation
                        let callID = call.call.id
                        exposed = await AgentMutationPersistenceError.capturing(settlement: exposed) {
                            if let mark { try await mark(callID) }
                        }
                    }
                    try await emitter?.failIfActive(call.call.id, failure: AgentFailure(exposed))
                    throw exposed
                })
            } catch { throw Self.toolError(error) }
            let completed = await progress.completed()
            if completed.executedMutation {
                // Only a newly executed side effect creates a provider fallback boundary.
                // A settled replay is a result lookup, not another mutation execution.
                await markMutationBoundaryIfNeeded(sessionID: sessionID, runID: runID)
            }
            history = completed.history
            (projectionRevision, contextEpoch) = try advancedProjectionCoordinates(
                revision: projectionRevision,
                contextEpoch: contextEpoch
            )
            receipts.append(contentsOf: completed.receipts)
            toolCalls += completed.count
        }
    }

    private func markMutationBoundaryIfNeeded(sessionID: UUID, runID: UUID) async {
        guard let boundary = provider as? any ModelProviderMutationBoundary else { return }
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
        history = try await lifecycle.checkpoint(history, inputs)
        await lifecycle.control.acknowledge(inputs)
        for input in inputs { try await emitter?.send(.steeringApplied(id: input.id, text: input.text)) }
    }

    private func advancedProjectionCoordinates(revision: UInt64, contextEpoch: UInt64) throws -> (UInt64, UInt64) {
        guard revision < .max, contextEpoch < .max else {
            throw AgentModelBindingError.staleConversationRevision
        }
        return (revision + 1, contextEpoch + 1)
    }

    private func requireConfiguredModel(_ responseModel: ModelID) throws {
        guard responseModel.provider.utf8.elementsEqual(model.provider.utf8),
              responseModel.name.utf8.elementsEqual(model.name.utf8) else { throw AgentLoopError.modelMismatch }
    }

    private func prepareRequest(
        messages: [ModelMessage],
        sessionID: UUID,
        runID: UUID,
        conversationRevision: UInt64,
        contextEpoch: UInt64,
        modelTurn: Int,
        structuredOutput: StructuredOutputSchema?,
        allowUnresolvedToolTail: Bool = false
    ) async throws -> AgentPreparedModelRequest {
        try Task.checkCancellation()
        await projectionDrain.begin()
        do {
            try Task.checkCancellation()
            let prepared = try await buildRequest(
                messages: messages, sessionID: sessionID, runID: runID,
                conversationRevision: conversationRevision, contextEpoch: contextEpoch,
                modelTurn: modelTurn, structuredOutput: structuredOutput,
                allowUnresolvedToolTail: allowUnresolvedToolTail)
            await projectionDrain.finish()
            return prepared
        } catch {
            await projectionDrain.finish()
            throw error
        }
    }

    private func buildRequest(
        messages: [ModelMessage],
        sessionID: UUID,
        runID: UUID,
        conversationRevision: UInt64,
        contextEpoch: UInt64,
        modelTurn: Int,
        structuredOutput: StructuredOutputSchema?,
        allowUnresolvedToolTail: Bool
    ) async throws -> AgentPreparedModelRequest {
        guard provider.descriptor.id.utf8.elementsEqual(model.provider.utf8) else {
            throw AgentLoopError.providerMismatch
        }
        var required: ModelCapabilities = []
        if !tools.definitions.isEmpty { required.formUnion([.tools, .multiTurn]) }
        if messages.contains(where: { $0.role == .assistant || $0.role == .tool }) { required.insert(.multiTurn) }
        if structuredOutput != nil { required.insert(.structuredOutput) }
        let missing = required.subtracting(provider.descriptor.capabilities)
        guard missing.isEmpty else { throw AgentLoopError.unsupportedCapabilities(missing) }

        var formalMessageIDs: [Int: UUID] = [:]
        var verifiedReadOnlyResults: [ToolCallID: AgentContextVerifiedReadOnlyResult] = [:]
        if let requirements = binding.projector as? any AgentContextSourceReferencing {
            let prefix = messages.prefix { $0.role == .system || $0.role == .developer }.count
            let formal = Array(messages.dropFirst(prefix))
            guard requirements.historySpans.count + requirements.toolResultCallIDs.count <= 256 else {
                throw AgentContextPipelineError.tooManyMaterials
            }
            for span in requirements.historySpans {
                guard span.sessionID == sessionID, span.start >= 0,
                      !span.messageIDs.isEmpty, span.messageIDs.count <= 256,
                      span.start <= formal.count,
                      span.messageIDs.count <= formal.count - span.start,
                      let journal else { throw AgentContextPipelineError.staleSummary }
                let page = try await journal.readMessages(sessionID: sessionID,
                                                          after: UInt64(span.start), limit: span.messageIDs.count)
                guard page.count == span.messageIDs.count,
                      page.map(\.message) == Array(formal[span.start..<(span.start + page.count)]) else {
                    throw AgentContextPipelineError.staleSummary
                }
                for (offset, entry) in page.enumerated() { formalMessageIDs[span.start + offset] = entry.id }
            }
            for callID in requirements.toolResultCallIDs {
                guard let index = formal.firstIndex(where: {
                    if case .tool(let result) = $0 { return result.callID == callID }
                    return false
                }), let journal else { throw AgentContextPipelineError.staleToolExcerpt }
                let page = try await journal.readMessages(sessionID: sessionID, after: UInt64(index), limit: 1)
                guard page.count == 1, page[0].message == formal[index] else {
                    throw AgentContextPipelineError.staleToolExcerpt
                }
                formalMessageIDs[index] = page[0].id
                if let proof = await contextEffects.proof(for: callID) {
                    verifiedReadOnlyResults[callID] = proof
                }
            }
        }
        let projection = try await binding.projector.project(.init(
            canonicalMessages: messages,
            model: model,
            sessionID: sessionID,
            runID: runID,
            conversationRevision: conversationRevision,
            contextEpoch: contextEpoch,
            modelTurn: modelTurn,
            formalMessageIDs: formalMessageIDs,
            verifiedReadOnlyResults: verifiedReadOnlyResults
        ))
        let sourceDigest = try AgentContextProjectionSource.digest(messages: messages)
        guard projection.plan.sourceRevision == conversationRevision,
              projection.plan.sourceDigest == sourceDigest,
              projection.plan.contextEpoch == contextEpoch,
              validToolPairs(projection.messages, allowUnresolvedToolTail: allowUnresolvedToolTail) else {
            throw AgentModelBindingError.invalidProjection
        }
        try validateContinuations(projection.messages)
        let requestBytes = try AgentContextWindow.encodedByteCount(projection.messages)
        if let modelContextByteLimit {
            let bytes = requestBytes
            guard bytes <= modelContextByteLimit else {
                if let report = projection.report, let sink = binding.contextReports {
                    await sink.append(report.withBudget(requestBytes: bytes, estimate: nil,
                                                        failureCode: "request_bytes_exceeded"))
                }
                throw AgentContextError.historyTooLarge(bytes: bytes, limit: modelContextByteLimit)
            }
        }
        var tokenEstimate: AgentContextTokenEstimate?
        if let budget = binding.tokenBudget {
            let estimate: AgentContextTokenEstimate
            do {
                estimate = try await budget.estimator.estimate(.init(
                    model: model, messages: projection.messages,
                    tools: tools.definitions, structuredOutput: structuredOutput
                ))
            } catch {
                if let report = projection.report, let sink = binding.contextReports {
                    await sink.append(report.withBudget(requestBytes: requestBytes, estimate: nil,
                                                        failureCode: "estimation_failed"))
                }
                throw error
            }
            guard estimate.inputTokens >= 0 else { throw AgentModelBindingError.invalidTokenEstimate }
            tokenEstimate = estimate
            guard estimate.inputTokens <= budget.availableInputTokens else {
                if let report = projection.report, let sink = binding.contextReports {
                    await sink.append(report.withBudget(requestBytes: requestBytes, estimate: estimate,
                                                        failureCode: "input_tokens_exceeded"))
                }
                throw AgentModelBindingError.contextBudgetExceeded(
                    estimatedInputTokens: estimate.inputTokens,
                    availableInputTokens: budget.availableInputTokens
                )
            }
        }
        let request = ModelRequest(
            model: model,
            messages: projection.messages,
            tools: tools.definitions,
            structuredOutput: structuredOutput,
            sessionID: sessionID,
            runID: runID
        )
        try (provider as? any ModelProviderRequestValidator)?.validate(request: request)
        if let report = projection.report, let sink = binding.contextReports {
            await sink.append(report.withBudget(requestBytes: requestBytes, estimate: tokenEstimate))
        }
        return .init(request: request, projection: projection, canonicalMessages: messages)
    }

    private func validateContinuations(_ messages: [ModelMessage]) throws {
        for message in messages {
            guard case .assistant(let content, _) = message else { continue }
            for part in content {
                guard case .providerContinuation(let state) = part else { continue }
                guard state.model == model else { throw AgentModelBindingError.incompatibleContinuation }
                if let origin = state.origin {
                    guard origin == binding.continuationOrigin else {
                        throw AgentModelBindingError.incompatibleContinuation
                    }
                } else if binding.legacyContinuationPolicy != .allowMatchingModel {
                    throw AgentModelBindingError.incompatibleContinuation
                }
            }
        }
    }

    private func scopeContinuation(_ event: ModelEvent) throws -> ModelEvent {
        guard binding.legacyContinuationPolicy != .allowMatchingModel else { return event }
        switch event {
        case .providerContinuation(let state):
            return .providerContinuation(try scoped(state))
        case .responseCompleted(let response):
            return .responseCompleted(.init(
                info: response.info,
                content: try response.content.map(scoped),
                toolCalls: response.toolCalls,
                usage: response.usage,
                stopReason: response.stopReason
            ))
        default:
            return event
        }
    }

    private func scoped(_ content: ModelContent) throws -> ModelContent {
        guard case .providerContinuation(let state) = content else { return content }
        return .providerContinuation(try scoped(state))
    }

    private func scoped(_ state: ModelProviderContinuation) throws -> ModelProviderContinuation {
        guard state.model == model,
              state.origin == nil || state.origin == binding.continuationOrigin else {
            throw AgentModelBindingError.incompatibleContinuation
        }
        return .init(model: state.model, format: state.format, payload: state.payload, origin: binding.continuationOrigin)
    }

    private func validToolPairs(_ messages: [ModelMessage], allowUnresolvedToolTail: Bool) -> Bool {
        var pending = Set<ToolCallID>()
        var seenCallIDs = Set<ToolCallID>()
        for (index, message) in messages.enumerated() {
            switch message {
            case .assistant(_, let calls):
                guard pending.isEmpty else { return false }
                for call in calls {
                    guard seenCallIDs.insert(call.id).inserted else { return false }
                    pending.insert(call.id)
                }
            case .tool(let result):
                guard pending.remove(result.callID) != nil else { return false }
            case .user, .system, .developer:
                guard pending.isEmpty else { return false }
            }
            if allowUnresolvedToolTail, index == messages.index(before: messages.endIndex) {
                return true
            }
        }
        return pending.isEmpty
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

/// A timed-out noncooperative projector/estimator may still be physically
/// running. Session drain must retain the Run and store lease until it exits.
private actor AgentProjectionDrain {
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin() { active += 1 }

    func finish() {
        active -= 1
        guard active == 0 else { return }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard active > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
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
