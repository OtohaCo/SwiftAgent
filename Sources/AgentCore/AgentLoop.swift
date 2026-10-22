import AgentModels
import AgentTools
import Foundation

package struct AgentPreparedModelRequest: Sendable {
    package let request: ModelRequest
    package let projection: AgentContextProjection
    package let canonicalMessages: [ModelMessage]
    package var conversationControls: ModelConversationControlState? = nil
}

/// Package orchestration for one model → tool → model loop. SDK users go through
/// `Agent`, `AgentSession` and `AgentRun`.
package struct AgentLoop: Sendable {
    private let binding: AgentModelBinding
    private let tools: ToolRegistry
    private let scheduler: ToolScheduler
    private let modelContextByteLimit: Int?
    private let journal: AgentJournal?
    private let nativeContextState: AgentNativeContextState
    private let conversationControlState: AgentConversationControlState
    private let runContextControls: AgentRunContextControls?
    private let contextOperation: Bool
    private let contextEffects: AgentContextEffectLedger
    private let capabilityScope: AgentCapabilityScope?
    private let allowedResources: Set<ToolResource>?
    private let preAdmissionReplanning: AgentPreAdmissionReplanning
    private let projectionDrain = AgentProjectionDrain()
    private let nativeOperations = AgentNativeOperationIDs()
    private let audit: AgentAuditRuntime?
    /// Test seam: runs before the loop handles each model event, to make the consumer lag behind the model source.
    private let beforeHandlingModelEvent: (@Sendable (ModelEvent) async -> Void)?

    private var model: ModelID { binding.model }
    private var provider: any ModelProvider { binding.provider }
    var modelBinding: AgentModelBinding { binding }

    package init(binding: AgentModelBinding, tools: ToolRegistry,
                 scheduler: ToolScheduler = .init(), modelContextByteLimit: Int? = nil,
                 journal: AgentJournal? = nil,
                 contextEffects: AgentContextEffectLedger = .init(),
                 nativeContextState: AgentNativeContextState = .init(),
                 conversationControlState: AgentConversationControlState = .init(), runContextControls: AgentRunContextControls? = nil, contextOperation: Bool = false,
                 capabilityScope: AgentCapabilityScope? = nil,
                 allowedResources: Set<ToolResource>? = nil,
                 preAdmissionReplanning: AgentPreAdmissionReplanning = .disabled,
                 audit: AgentAuditRuntime? = nil,
                 beforeHandlingModelEvent: (@Sendable (ModelEvent) async -> Void)? = nil) {
        self.beforeHandlingModelEvent = beforeHandlingModelEvent
        self.binding = binding
        self.tools = tools
        self.scheduler = scheduler
        self.modelContextByteLimit = modelContextByteLimit
        self.journal = journal
        self.nativeContextState = nativeContextState
        self.conversationControlState = conversationControlState
        self.runContextControls = runContextControls
        self.contextOperation = contextOperation
        self.contextEffects = contextEffects
        self.capabilityScope = capabilityScope
        self.allowedResources = allowedResources
        self.preAdmissionReplanning = preAdmissionReplanning
        self.audit = audit
    }

    package init(model: ModelID, provider: any ModelProvider, tools: ToolRegistry, scheduler: ToolScheduler = .init(),
                 beforeHandlingModelEvent: (@Sendable (ModelEvent) async -> Void)? = nil) {
        self.init(binding: .legacy(model: model, provider: provider), tools: tools, scheduler: scheduler,
                  beforeHandlingModelEvent: beforeHandlingModelEvent)
    }

    package func preflight(
        messages: [ModelMessage],
        sessionID: UUID,
        runID: UUID,
        conversationRevision: UInt64,
        structuredOutput: StructuredOutputSchema?
    ) async throws -> AgentPreparedModelRequest {
        if binding.nativeContextPolicy?.compactBeforeGeneration == .anthropicOnDemand,
           runContextControls?.reminder != nil {
            throw ModelProviderError(kind: .unsupportedCapability,
                message: "Run-local on-demand compaction cannot cover the required reminder before continuing generation; compact between completed Runs instead.")
        }
        return try await prepareRequest(
            messages: messages,
            sessionID: sessionID,
            runID: runID,
            conversationRevision: conversationRevision,
            contextEpoch: conversationRevision,
            modelTurn: 1,
            structuredOutput: structuredOutput,
            declaredTools: tools.initiallyDeclaredNames,
            isStartupPreflight: true
        )
    }

    package func run(
        messages: [ModelMessage], sessionID: UUID, runID: UUID = UUID(), budget: AgentBudget,
        structuredOutput: StructuredOutputSchema? = nil, operationID: String? = nil
    ) async throws -> AgentLoopResult {
        try await execute(messages: messages, sessionID: sessionID, runID: runID, budget: budget.renewed(),
                          structuredOutput: structuredOutput, operationID: operationID, emitter: nil)
    }

    package func events(
        messages: [ModelMessage], sessionID: UUID, runID: UUID = UUID(), budget: AgentBudget,
        structuredOutput: StructuredOutputSchema? = nil, operationID: String? = nil
    ) -> AsyncStream<AgentEvent> {
        let cancelledAtCreation = Task.isCancelled
        let budget = budget.renewed()
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
        await audit?.waitForDrain()
        if let provider = provider as? any ModelProviderCompaction {
            for id in await nativeOperations.ids() { await provider.waitForCompactionToDrain(sessionID: sessionID, operationID: id) }
        }
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
        let outcome: Result<AgentLoopResult, any Error>
        do {
            if cancelledAtCreation { throw CancellationError() }
            await audit?.beginBody()
            outcome = .success(try await withAgentDeadline(budget.deadline, gate: budget.gate, operation: {
                do {
                    return try await runBody(messages: messages, sessionID: sessionID, runID: runID,
                        budget: budget, structuredOutput: structuredOutput, operationID: operationID,
                        emitter: emitter, lifecycle: lifecycle, evidenceLedger: evidenceLedger,
                        initialRequest: initialRequest)
                } catch {
                    let captured = await AgentAuditPersistenceError.capturing(original: error) {
                        try await audit?.rejectUnprepared(error)
                    }
                    let exposed = await AgentAuditPersistenceError.capturing(original: captured) {
                        try await audit?.closeUnstarted(error)
                    }
                    throw exposed
                }
            }, onOperationFinished: { await audit?.finishBody() }))
        } catch {
            outcome = .failure(error)
        }
        let finishFailure = await lifecycle?.beforeFinish(outcome)
        await clearMutationBoundary(sessionID: sessionID, runID: runID)
        switch (outcome, finishFailure) {
        case (_, let failure?):
            await emitter?.finish(.failed(AgentFailure(failure)))
            throw failure
        case (.success(let result), nil):
            await emitter?.finish(.result(result))
            return result
        case (.failure(let error), nil):
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
        var maintenanceRounds = 0
        var toolCalls = 0
        var admissionFeedbackUsed = false
        var mutationObserved = false
        var receipts: [AgentToolReceipt] = []
        var projectionRevision = initialRequest?.projection.plan.sourceRevision ?? 0
        var contextEpoch = initialRequest?.projection.plan.contextEpoch ?? 0
        // Run-local and only growing: a committed tool result can declare deferred tools for the
        // next request. A new Run starts again from its registry's declarations.
        var declaredTools = tools.initiallyDeclaredNames
        var usedCallIDs = Set<ToolCallID>()
        for message in messages {
            switch message {
            case .assistant(_, let calls): usedCallIDs.formUnion(calls.map(\.id))
            case .tool(let result): usedCallIDs.insert(result.callID)
            default: break
            }
        }
        if let mode = binding.nativeContextPolicy?.compactBeforeGeneration {
            guard let nativeProvider = provider as? any ModelProviderCompaction else {
                throw ModelProviderError(kind: .unsupportedCapability, message: "The binding requests an unavailable native compact operation.")
            }
            let prepared = try await prepareRequest(messages: history, sessionID: sessionID, runID: runID,
                conversationRevision: projectionRevision, contextEpoch: contextEpoch, modelTurn: 0,
                structuredOutput: structuredOutput, declaredTools: declaredTools)
            let source = try await nativeContextState.source(for: prepared, sessionID: sessionID, journal: journal, provider: provider, compactionMode: mode)
            let invocation = UUID(), operation = UUID()
            let request = prepared.request.withNativeSource(source, invocationID: invocation)
            await nativeOperations.insert(operation)
            let response = try await executeNativeCompact(provider: nativeProvider,
                request: .init(request: request, mode: mode, operationID: operation, invocationID: invocation),
                emit: { event in try await emitter?.send(.compaction(operationID: operation, invocationID: invocation, event: event)) })
            try budget.checkActive()
            if let state = response.continuation {
                guard state.contextTransition?.responseID == response.info.id else { throw AgentModelBindingError.incompatibleContinuation }
                if let publish = lifecycle?.publishNativeContext {
                    history = try await publish(history, state, request, response.usage, source.canonicalMessageCount)
                } else {
                    guard journal == nil else { throw AgentJournalError.invalidRecord }
                    let value = try await nativeContextState.candidate(state, request: request, canonicalTailStart: source.canonicalMessageCount,
                        canonical: history, binding: binding, usage: response.usage)
                    await nativeContextState.install(value)
                }
            }
            try await emitter?.send(.compaction(operationID: operation, invocationID: invocation, event: .completed(response)))
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
            if let sourceRevision = lifecycle?.sourceRevision {
                // A tool batch may publish several canonical checkpoints. Its
                // source revision is the Session's actual revision, not a turn count.
                projectionRevision = try await sourceRevision(history)
            }
            modelTurns += 1
            try await emitter?.send(.turnStarted(modelTurns))
            try budget.checkActive()
            let preparedRequest: AgentPreparedModelRequest
            if modelTurns == 1,
               let initialRequest,
               initialRequest.canonicalMessages == history, binding.nativeContextPolicy?.compactBeforeGeneration == nil {
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
                    declaredTools: declaredTools,
                    allowUnresolvedToolTail: initialRequest == nil && modelTurns == 1
                )
            }
            if let controls = preparedRequest.conversationControls, await conversationControlState.current() != controls {
                if let publish = lifecycle?.publishConversationControls {
                    try await publish(controls, history)
                } else {
                    guard journal == nil else { throw AgentJournalError.invalidRecord }
                    await conversationControlState.install(controls)
                }
            }
            let request: ModelRequest
            if (provider as? any ModelProviderCompaction)?.automaticCompaction != nil || requestNeedsNativeSource(preparedRequest.request)
                || (provider as? any ModelProviderPreservedThinkingCompaction)?.supportsPreservedThinkingCompaction == true {
                let source = try await nativeContextState.source(for: preparedRequest, sessionID: sessionID, journal: journal, provider: provider)
                request = preparedRequest.request.withNativeSource(source, invocationID: UUID())
            } else { request = preparedRequest.request }
            let requestBoundary: ModelProviderRequestBoundary?
            if let preserved = provider as? any ModelProviderPreservedThinkingCompaction,
               preserved.supportsPreservedThinkingCompaction, !binding.isLegacyBinding,
               let source = request.nativeContextSource, let invocationID = request.invocationID,
               preparedRequest.request.messages == (try await nativeContextState.effectiveMessages(history, binding: binding,
                    sessionID: sessionID, journal: journal, structuredOutput: structuredOutput, tools: tools)) {
                requestBoundary = try .init(id: UUID(), source: source, invocationID: invocationID,
                    origin: binding.continuationOrigin,
                    rootConfigurationDigest: try AgentNativeContextState.rootDigest(history, binding: binding, structuredOutput: structuredOutput),
                    tools: request.tools, conversationControls: request.conversationControls,
                    witness: try preserved.preservedThinkingRequestWitness(request: request))
            } else { requestBoundary = nil }
            try budget.checkActive()
            var accumulator = ModelEventAccumulator()
            var receivedThisTurn: [ToolCallID] = []
                var startedThisTurn: Set<ToolCallID> = []
            for try await rawEvent in settlingModelEvents(provider.stream(request: request), gate: budget.gate) {
                await beforeHandlingModelEvent?(rawEvent)
                try budget.checkActive()
                let event = try scopeContinuation(rawEvent, requestBoundary: requestBoundary)
                if let audit, case .toolCallStarted(let id, let name) = event {
                    if id.rawValue.utf8.count > 512 || name.utf8.count > 512
                        || id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.isEmpty
                        || !startedThisTurn.insert(id).inserted {
                        // Only a bounded identity diagnostic is available; no claim to reconstruct fragments.
                        try await audit.capture(.init(id: id, name: name, argumentsJSON: "", completeness: .incomplete),
                            operationID: operationID, mutationIdentity: nil)
                        try await audit.rejected(id, reason: "invalid_or_duplicate_stream_identity")
                    }
                }
                if let audit, case .toolCallCompleted(let call) = event {
                    let bounded = call.argumentsJSON.utf8.count <= AuditEncoding.maximumRawBytes
                        && call.id.rawValue.utf8.count <= 512 && call.name.utf8.count <= 512
                    let key = bounded ? Self.idempotencyKey(operationID: operationID, runID: runID, call: call) : nil
                    try await audit.capture(call, operationID: operationID, mutationIdentity: key)
                    receivedThisTurn.append(call.id)
                }
                do { try accumulator.append(event) }
                catch {
                    for id in receivedThisTurn { try await audit?.rejected(id, reason: "model_stream_rejected") }
                    throw error
                }
                if case .responseStarted(let info) = event { try requireConfiguredModel(info.model) }
                if case .responseCompleted = event { continue }
                try await emitter?.send(.model(event))
            }
            try budget.checkActive()
            let response = try accumulator.finish()
            try requireConfiguredModel(response.info.model)
            try await emitter?.send(.model(.responseCompleted(response)))
            if response.stopReason == .cancelled { throw CancellationError() }
            if let lifecycle, preparedRequest.conversationControls == nil || response.classification == .finalResponse {
                let inputs = try await lifecycle.control.takeSteering(atTermination: response.classification == .finalResponse)
                if !inputs.isEmpty {
                    // Another model turn follows: the answer just settled is not the last, and the deadline limits it.
                    budget.gate.reopen()
                    for call in response.toolCalls { try await audit?.rejected(call.id, reason: "steering_superseded") }
                    guard modelTurns < budget.maxModelTurns else { throw AgentLoopError.modelTurnLimitReached }
                    if preparedRequest.conversationControls != nil {
                        let accepted = checkpointContent(response, retainingToolCalls: 0).filter {
                            if case .providerContinuation(let state) = $0 { state.contextTransition == nil } else { true }
                        }
                        guard !accepted.isEmpty else { throw ModelProviderError(kind: .unsupportedCapability, message: "Steering needs a real assistant boundary after trusted controls.") }
                        history.append(.assistant(content: accepted, toolCalls: []))
                    }
                    try await applySteering(inputs, to: &history, lifecycle: lifecycle, emitter: emitter)
                    (projectionRevision, contextEpoch) = try advancedProjectionCoordinates(
                        revision: projectionRevision,
                        contextEpoch: contextEpoch
                    )
                    continue
                }
            }
            if response.classification == .maintenance {
                guard response.toolCalls.isEmpty else {
                    throw ModelProviderError(kind: .invalidResponse, message: "Maintenance cannot publish unaccepted client tool proposals.")
                }
                maintenanceRounds += 1
                let configuredLimits = [binding.nativeContextPolicy?.maximumMaintenanceRounds,
                    (provider as? any ModelProviderCompaction)?.automaticCompaction?.maximumMaintenanceRounds].compactMap { $0 }
                guard maintenanceRounds <= (configuredLimits.min() ?? 4) else {
                    throw ModelProviderError(kind: .invalidResponse, message: "Native maintenance did not converge within its bounded continuation budget.")
                }
                if let state = try nativeCandidate(response, request: request) {
                    history = try await publishNative(state, request: request, response: response, history: history,
                        tailStart: request.nativeContextSource!.canonicalMessageCount, lifecycle: lifecycle)
                } else if response.stopReason == .unknown("compaction") {
                    throw ModelProviderError(kind: .invalidResponse, message: "Compaction pause has no complete native checkpoint.")
                }
                (projectionRevision, contextEpoch) = try advancedProjectionCoordinates(revision: projectionRevision, contextEpoch: contextEpoch)
                try budget.checkActive()
                continue
            }
            maintenanceRounds = 0
            if response.stopReason != .toolCalls {
                for call in response.toolCalls { try await audit?.rejected(call.id, reason: "not_dispatched") }
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
                if response.toolCalls.isEmpty, let state = try nativeCandidate(response, request: request) {
                    history = try await publishNative(state, request: request, response: response, history: history,
                        tailStart: history.count - history.prefix { $0.role == .system || $0.role == .developer }.count, lifecycle: lifecycle)
                } else if let lifecycle { history = try await lifecycle.checkpoint(history, []) }
                return AgentLoopResult(response: response, history: history, outcome: outcome,
                                       modelTurns: modelTurns, toolCalls: toolCalls, receipts: receipts)
            }
            guard modelTurns < budget.maxModelTurns else {
                for call in response.toolCalls { try await audit?.rejected(call.id, reason: "model_turn_limit") }
                throw AgentLoopError.modelTurnLimitReached
            }
            guard response.toolCalls.count <= budget.maxToolCalls - toolCalls else {
                for call in response.toolCalls { try await audit?.rejected(call.id, reason: "tool_call_limit") }
                throw AgentLoopError.toolCallLimitReached
            }
            var preparedCalls: [PreparedToolCall] = []
            // Response index of each prepared call, and model-visible results for calls whose
            // arguments the model must correct. Those calls are never authorized, admitted or run.
            var preparedIndices: [Int] = []
            var rejectedArguments: [Int: ToolResultMessage] = [:]
            for (index, call) in response.toolCalls.enumerated() {
                do {
                // The Host's call namespace is the Host's (ADR 0011): a model never makes a call in its name.
                guard !call.id.rawValue.hasPrefix(AgentHostToolCall.callIDPrefix) else { throw AgentHostInvocationError.reservedCallIdentity(call.id) }
                guard usedCallIDs.insert(call.id).inserted else { throw AgentLoopError.reusedToolCallID(call.id) }
                var prepared: PreparedToolCall
                do {
                    prepared = try tools.prepare(call, context: ToolContext(sessionID: sessionID, runID: runID,
                        callID: call.id, deadline: budget.deadline,
                        idempotencyKey: Self.idempotencyKey(operationID: operationID, runID: runID, call: call),
                        argumentsJSON: call.argumentsJSON, evidenceLedger: evidenceLedger,
                        mutationAdmission: lifecycle?.mutationAdmission,
                        executionAdmission: capabilityScope), declared: declaredTools,
                        prepareAuthorizationBinding: audit != nil)
                } catch {
                    guard let feedback = Self.invalidArgumentsFeedback(error, call: call) else { throw error }
                    rejectedArguments[index] = feedback
                    continue
                }
                if let allowedResources, !Set(prepared.resources).isSubset(of: allowedResources) {
                    throw AgentCapabilityError.resourceOutsideScope
                }
                if let audit { prepared = try await audit.prepare(prepared, deadline: budget.deadline) }
                preparedCalls.append(prepared)
                preparedIndices.append(index)
                } catch {
                    try await audit?.rejected(call.id, reason: error is AgentCapabilityError ? "resource_outside_scope" : "preparation_rejected")
                    for sibling in response.toolCalls where sibling.id != call.id {
                        try await audit?.rejected(sibling.id, reason: "batch_preparation_failed")
                    }
                    throw error
                }
            }
            if let call = preparedCalls.first, preparedCalls.count == 1, rejectedArguments.isEmpty,
               !admissionFeedbackUsed, !mutationObserved,
               call.policy.effect == .mutation,
               preAdmissionReplanning.includes(call.call.name),
               let lifecycle {
                // This probe belongs to the prepared runtime invocation, before authorization,
                // durable intent and final admission. Invocation repeats the check on success.
                if let rejection = try await call.preAdmissionEvidenceRejection() {
                    try await audit?.rejected(call.call.id, reason: "runtime_evidence_rejected")
                    try budget.checkActive()
                    try await capabilityScope?.check(runID: runID, resources: call.resources)
                    guard try await lifecycle.checkReplanningSafety(operationID) else {
                        throw EvidenceError.unavailable(rejection.reference)
                    }
                    let reference = Self.modelSubmittedReference(rejection.reference,
                        argumentsJSON: call.call.argumentsJSON)
                    let detail = reference.map { "Evidence for reference \($0) is unavailable" }
                        ?? "Required Evidence for this submitted reference is unavailable"
                    let message = ToolResultMessage(callID: rejection.callID, content: [.json(.object([
                        "code": .string("evidence_unavailable"),
                        "message": .string("\(detail); this call was denied before execution."),
                    ]))], isError: true)
                    let proposed = history + [
                        .assistant(content: checkpointContent(response, retainingToolCalls: 1).filter {
                            if case .providerContinuation(let state) = $0 { state.contextTransition == nil } else { true }
                        }, toolCalls: [call.call]),
                        .tool(message),
                    ]
                    try budget.checkActive()
                    try await capabilityScope?.check(runID: runID, resources: call.resources)
                    guard try await lifecycle.checkReplanningSafety(operationID) else {
                        throw EvidenceError.unavailable(rejection.reference)
                    }
                    history = try await lifecycle.recordAdmissionRejection(rejection, proposed)
                    // A committed rejection remains formal history. Cancellation/revoke can
                    // still stop the next request; it must never erase the committed pair.
                    try await emitter?.send(.toolAdmissionRejected(rejection.callID))
                    try budget.checkActive()
                    try await capabilityScope?.check(runID: runID, resources: call.resources)
                    guard try await lifecycle.checkReplanningSafety(operationID) else {
                        throw EvidenceError.unavailable(rejection.reference)
                    }
                    (projectionRevision, contextEpoch) = try advancedProjectionCoordinates(
                        revision: projectionRevision, contextEpoch: contextEpoch)
                    toolCalls += 1
                    admissionFeedbackUsed = true
                    continue
                }
            }
            // Replay keeps every proposal. Arguments that are not one JSON object become `{}`: each
            // provider requires a tool call's input to be an object, and the result explains the mistake.
            var replayCalls = response.toolCalls
            for index in rejectedArguments.keys.sorted() {
                let call = response.toolCalls[index]
                try await audit?.rejected(call.id, reason: "invalid_arguments")
                if (try? JSONValue.decodeToolArguments(call.argumentsJSON)) == nil {
                    replayCalls[index] = ToolCall(id: call.id, name: call.name,
                        argumentsJSON: ToolCall.replacedInvalidArgumentsJSON, completeness: .complete)
                }
            }
            if replayCalls == response.toolCalls, let stage = lifecycle?.stageNativeContext,
               let state = try nativeCandidate(response, request: request) {
                try await stage(state, request, response.usage, request.nativeContextSource!.canonicalMessageCount + 1)
            }
            let progress = AgentToolBatchProgress(prefix: history, response: response, calls: replayCalls,
                                                  rejected: rejectedArguments, budget: budget,
                                                  lifecycle: lifecycle, emitter: emitter)
            if preparedCalls.isEmpty { try await progress.commitUnexecuted() }
            let responseIndices = preparedIndices
            do {
                try await scheduler.execute(preparedCalls, deadline: budget.deadline, onStarted: { call in
                    try budget.checkActive()
                    try await capabilityScope?.check(runID: runID, resources: call.resources)
                    try await emitter?.send(.toolStarted(call.call))
                }, onCompleted: { index, call, result in
                    try await progress.record(index: responseIndices[index], call: call, result: result)
                }, onFailed: { call, error in
                    // Audit failure cannot discard the original error or skip existing recovery.
                    var exposed = await AgentAuditPersistenceError.capturing(original: Self.toolError(error)) {
                        try await call.auditAuthorization?.failed(error)
                    }
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
            if lifecycle?.stageNativeContext == nil, replayCalls == response.toolCalls, completed.count == response.toolCalls.count,
               let state = try nativeCandidate(response, request: request) {
                history = try await publishNative(state, request: request, response: response, history: history,
                    tailStart: request.nativeContextSource!.canonicalMessageCount + 1, lifecycle: lifecycle)
            }
            (projectionRevision, contextEpoch) = try advancedProjectionCoordinates(
                revision: projectionRevision,
                contextEpoch: contextEpoch
            )
            receipts.append(contentsOf: completed.receipts)
            declaredTools.formUnion(completed.declaredTools)
            mutationObserved = mutationObserved || completed.executedMutation
                || completed.receipts.contains { $0.effect == .mutation }
            toolCalls += completed.count
        }
    }

    private func executeNativeCompact(provider: any ModelProviderCompaction, request: ModelCompactionRequest,
                                      emit: @escaping @Sendable (ModelCompactionEvent) async throws -> Void) async throws -> ModelCompactionResponse {
        await projectionDrain.begin()
        do {
            let response = try await AgentNativeCompactionExecutor(provider: provider).execute(request, emit: emit)
            await projectionDrain.finish()
            return response
        } catch { await projectionDrain.finish(); throw error }
    }

    private func requestNeedsNativeSource(_ request: ModelRequest) -> Bool {
        request.nativeContext != nil || binding.nativeContextPolicy?.compactBeforeGeneration != nil
    }

    private func nativeCandidate(_ response: ModelResponse, request: ModelRequest) throws -> ModelProviderContinuation? {
        let states = response.content.compactMap { content -> ModelProviderContinuation? in
            guard case .providerContinuation(let state) = content, state.contextTransition != nil else { return nil }
            return state
        }
        guard states.count <= 1 else { throw AgentModelBindingError.incompatibleContinuation }
        if let state = states.first {
            guard state.contextTransition?.responseID == response.info.id,
                  state.contextTransition?.source == request.nativeContextSource,
                  request.nativeContextSource != nil else { throw AgentModelBindingError.incompatibleContinuation }
        }
        return states.first
    }

    private func publishNative(_ state: ModelProviderContinuation, request: ModelRequest, response: ModelResponse,
                               history: [ModelMessage], tailStart: Int, lifecycle: AgentLoopLifecycle?) async throws -> [ModelMessage] {
        if let publish = lifecycle?.publishNativeContext {
            return try await publish(history, state, request, response.usage, tailStart)
        }
        guard journal == nil else { throw AgentJournalError.invalidRecord }
        let value = try await nativeContextState.candidate(state, request: request, canonicalTailStart: tailStart,
                                                          canonical: history, binding: binding, usage: response.usage)
        await nativeContextState.install(value)
        return history
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
        declaredTools: Set<String>,
        allowUnresolvedToolTail: Bool = false,
        isStartupPreflight: Bool = false
    ) async throws -> AgentPreparedModelRequest {
        try Task.checkCancellation()
        await projectionDrain.begin()
        do {
            try Task.checkCancellation()
            let prepared = try await buildRequest(
                messages: messages, sessionID: sessionID, runID: runID,
                conversationRevision: conversationRevision, contextEpoch: contextEpoch,
                modelTurn: modelTurn, structuredOutput: structuredOutput,
                declaredTools: declaredTools, allowUnresolvedToolTail: allowUnresolvedToolTail,
                isStartupPreflight: isStartupPreflight)
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
        declaredTools: Set<String>,
        allowUnresolvedToolTail: Bool,
        isStartupPreflight: Bool
    ) async throws -> AgentPreparedModelRequest {
        guard provider.descriptor.id.utf8.elementsEqual(model.provider.utf8) else {
            throw AgentLoopError.providerMismatch
        }
        if (provider as? any ModelProviderCompaction)?.automaticCompaction != nil || binding.nativeContextPolicy?.compactBeforeGeneration != nil
            || (provider as? any ModelProviderPreservedThinkingCompaction)?.supportsPreservedThinkingCompaction == true {
            guard !binding.isLegacyBinding else {
                throw ModelProviderError(kind: .unsupportedCapability, message: "Native context requires an explicit deployment-scoped model binding.")
            }
            if let journal, !journal.supportsNativeContext { throw AgentJournalError.unsupportedFormat }
        }
        if let mode = binding.nativeContextPolicy?.compactBeforeGeneration {
            guard let nativeProvider = provider as? any ModelProviderCompaction, nativeProvider.compactionModes.contains(mode) else {
                throw ModelProviderError(kind: .unsupportedCapability, message: "The controlled compaction mode is not qualified for this deployment.")
            }
        }
        if await nativeContextState.current() != nil, binding.isLegacyBinding {
            throw ModelProviderError(kind: .unsupportedCapability, message: "Restored native state requires its explicit deployment binding.")
        }
        let originalCanonicalMessages = messages
        let canonicalMessages = try await nativeContextState.ordinaryMessages(messages)
        let messages = try await nativeContextState.effectiveMessages(originalCanonicalMessages, binding: binding, sessionID: sessionID,
                                                                      journal: journal, structuredOutput: structuredOutput, tools: tools)
        let nativeContext = await nativeContextState.current()
        let nativePending = await nativeContextState.pendingCalls(in: canonicalMessages)
        if nativeContext != nil,
           let requirements = binding.projector as? any AgentContextSourceReferencing,
           !requirements.historySpans.isEmpty || !requirements.toolResultCallIDs.isEmpty {
            throw ModelProviderError(kind: .unsupportedCapability,
                message: "Canonical range projectors cannot reinterpret ranges across a native covered prefix; use an identity or native-suffix projector.")
        }
        // Requests, capability checks and token estimates see the declared tools only.
        let activeDefinitions = contextOperation ? (await conversationControlState.current()?.activeTools ?? tools.definitions(declared: declaredTools)) : tools.definitions(declared: declaredTools)
        let controlsInput: AgentRunContextControls?
        if isStartupPreflight { controlsInput = runContextControls }
        else { controlsInput = try runContextControls.map { try .init(reminder: $0.reminder) } }
        let proposedControls = try await conversationControlState.prepare(canonical: canonicalMessages, binding: binding,
            definitions: activeDefinitions, baselineDefinitions: tools.definitions, baselineDeclaredNames: tools.initiallyDeclaredNames, instructions: controlsInput, structuredOutput: structuredOutput)
        if proposedControls != nil, let journal, !journal.supportsNativeContext { throw AgentJournalError.unsupportedFormat }
        let toolDefinitions = proposedControls?.toolBaseline ?? activeDefinitions
        var required: ModelCapabilities = []
        if !toolDefinitions.isEmpty { required.formUnion([.tools, .multiTurn]) }
        if messages.contains(where: { $0.role == .assistant || $0.role == .tool }) { required.insert(.multiTurn) }
        if structuredOutput != nil { required.insert(.structuredOutput) }
        let missing = required.subtracting(provider.descriptor.capabilities)
        guard missing.isEmpty else { throw AgentLoopError.unsupportedCapabilities(missing) }

        var originalHistoryDigests: [AgentContextHistorySpan: String] = [:]
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
                      page.map(\.message) == Array(originalCanonicalMessages.dropFirst(prefix).dropFirst(span.start).prefix(page.count)) else {
                    throw AgentContextPipelineError.staleSummary
                }
                originalHistoryDigests[span] = try AgentContextProjectionSource.digest(messages: page.map(\.message))
                for (offset, entry) in page.enumerated() { formalMessageIDs[span.start + offset] = entry.id }
            }
            for callID in requirements.toolResultCallIDs {
                guard let index = formal.firstIndex(where: {
                    if case .tool(let result) = $0 { return result.callID == callID }
                    return false
                }), let journal else { throw AgentContextPipelineError.staleToolExcerpt }
                let page = try await journal.readMessages(sessionID: sessionID, after: UInt64(index), limit: 1)
                guard page.count == 1, page[0].message == Array(originalCanonicalMessages.dropFirst(prefix))[index] else {
                    throw AgentContextPipelineError.staleToolExcerpt
                }
                formalMessageIDs[index] = page[0].id
                if let proof = await contextEffects.proof(for: callID) {
                    verifiedReadOnlyResults[callID] = proof
                }
            }
        }
        if let requirements = binding.projector as? any AgentContextReadOnlyGroupReferencing {
            guard requirements.readOnlyGroupCallIDs.count <= 256 else {
                throw AgentContextPipelineError.tooManyMaterials
            }
            var requested: Set<ToolCallID> = []
            for anchor in requirements.readOnlyGroupCallIDs {
                guard let group = AgentResolvedReadOnlyToolProjector.closedGroup(containing: anchor, in: messages),
                      requested.count + group.results.count <= 256 else {
                    throw AgentContextProjectionError.unresolvedReadOnlySpan(anchor)
                }
                for id in group.results.keys {
                    requested.insert(id)
                    if let proof = await contextEffects.proof(for: id) { verifiedReadOnlyResults[id] = proof }
                }
            }
        }
        let sourceEncoding = try AgentContextProjectionSource.measure(messages: messages)
        var projectionInput = AgentContextProjectionInput(
            canonicalMessages: messages,
            model: model,
            sessionID: sessionID,
            runID: runID,
            conversationRevision: conversationRevision,
            contextEpoch: contextEpoch,
            modelTurn: modelTurn,
            formalMessageIDs: formalMessageIDs,
            verifiedReadOnlyResults: verifiedReadOnlyResults
        )
        projectionInput.bindSourceEncoding(sourceEncoding)
        projectionInput.bindOriginalHistoryDigests(originalHistoryDigests)
        let projection = try await binding.projector.project(projectionInput)
        guard projection.plan.sourceRevision == conversationRevision,
              projection.plan.sourceDigest == sourceEncoding.digest,
              projection.plan.contextEpoch == contextEpoch,
              validToolPairs(projection.messages, allowUnresolvedToolTail: allowUnresolvedToolTail, initialPending: nativePending) else {
            throw AgentModelBindingError.invalidProjection
        }
        try await nativeContextState.rejectRetiredReinjection(projection.messages, canonical: originalCanonicalMessages)
        try validateContinuations(projection.messages)
        // Images reach the model, become text or stop the request here, per the Run's explicit choice.
        let (imageMessages, imagesDescribed) = try binding.imageInput.apply(
            to: projection.messages, adapterSendsImages: provider.descriptor.capabilities.contains(.imageInput))
        let (modelMessages, filesDescribed) = try binding.fileInput.apply(
            to: imageMessages, adapterSendsFiles: provider.descriptor.capabilities.contains(.fileInput))
        let described = imagesDescribed || filesDescribed
        if let checkpoint = nativeContext, let lineage = checkpoint.preservedThinkingLineage {
            let leading = canonicalMessages.prefix { $0.role == .system || $0.role == .developer }.count
            let expected = Array(canonicalMessages.dropFirst(leading + checkpoint.canonicalTailStart).prefix(lineage.tailMessageCount))
            let actual = Array(modelMessages.drop(while: { $0.role == .system || $0.role == .developer }).prefix(lineage.tailMessageCount))
            guard expected.count == lineage.tailMessageCount, actual == expected,
                  try AgentContextProjectionSource.digest(messages: actual) == lineage.tailDigest else {
                throw AgentModelBindingError.invalidProjection
            }
        }
        // Images sent as text make this request's view lossy, and its plan says so.
        let sentProjection = described ? AgentContextProjection(
            messages: modelMessages,
            plan: .init(projectionID: projection.plan.projectionID, version: projection.plan.version,
                        sourceRevision: projection.plan.sourceRevision, sourceDigest: projection.plan.sourceDigest,
                        contextEpoch: projection.plan.contextEpoch, lossy: true,
                        reason: projection.plan.reason ?? "Attachments were sent as their text substitutes."),
            report: projection.report
        ) : projection
        let retiredPrefix = await nativeContextState.currentHandoff()?.canonicalMessageCount
        let controlView = try proposedControls.map { try AgentConversationControlState.view($0, canonical: canonicalMessages,
            effective: modelMessages, native: nativeContext, retiredPrefix: retiredPrefix) }
        let controlBytes = try controlView.map { try AgentConversationControlState.encode($0.controls).count } ?? 0
        let visibleBytes = sharesCanonicalMessageStorage(modelMessages, messages)
            ? sourceEncoding.byteCount : try AgentContextWindow.encodedByteCount(modelMessages)
        let nativeBytes = nativeContext.map { $0.continuation.payload.count } ?? 0
        let (requestBytes, byteOverflow) = visibleBytes.addingReportingOverflow(nativeBytes + controlBytes)
        guard !byteOverflow else { throw AgentModelBindingError.invalidProjection }
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
            if nativeContext != nil, !(budget.estimator is any AgentNativeContextTokenEstimator) {
                throw AgentModelBindingError.contextWindowUnknown
            }
            if controlView?.controls.isEmpty == false, !(budget.estimator is any AgentConversationControlTokenEstimator) {
                throw AgentModelBindingError.contextWindowUnknown
            }
            let estimate: AgentContextTokenEstimate
            do {
                estimate = try await budget.estimator.estimate(.init(
                    model: model, messages: modelMessages,
                    tools: toolDefinitions, structuredOutput: structuredOutput, nativeContext: nativeContext, conversationControls: controlView
                ))
            } catch {
                if let report = projection.report, let sink = binding.contextReports {
                    await sink.append(report.withBudget(requestBytes: requestBytes, estimate: nil,
                                                        failureCode: "estimation_failed"))
                }
                throw error
            }
            guard estimate.inputTokens >= 0 else { throw AgentModelBindingError.invalidTokenEstimate }
            // A custom estimator must include the explicit Host file estimates. This is a
            // lower-bound consistency check, not verification of remote document tokenization.
            let fileTokens = modelMessages.flatMap(\.files).reduce(0) { $0 + $1.estimatedInputTokens }
            guard estimate.inputTokens >= fileTokens else { throw AgentModelBindingError.invalidTokenEstimate }
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
            messages: modelMessages,
            tools: toolDefinitions,
            structuredOutput: structuredOutput,
            sessionID: sessionID,
            runID: runID, nativeContext: nativeContext, conversationControls: controlView
        )
        try (provider as? any ModelProviderRequestValidator)?.validate(request: request)
        if let report = projection.report, let sink = binding.contextReports {
            await sink.append(report.withBudget(requestBytes: requestBytes, estimate: tokenEstimate))
        }
        return .init(request: request, projection: sentProjection, canonicalMessages: originalCanonicalMessages, conversationControls: proposedControls)
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

    private func scopeContinuation(_ event: ModelEvent, requestBoundary: ModelProviderRequestBoundary? = nil) throws -> ModelEvent {
        switch event {
        case .providerContinuation(let state):
            if binding.legacyContinuationPolicy == .allowMatchingModel, state.contextTransition == nil, requestBoundary == nil { return event }
            return .providerContinuation(try scoped(state, requestBoundary: requestBoundary))
        case .responseCompleted(let response):
            if binding.legacyContinuationPolicy == .allowMatchingModel, requestBoundary == nil, !response.content.contains(where: {
                if case .providerContinuation(let state) = $0 { state.contextTransition != nil } else { false }
            }) { return event }
            return .responseCompleted(.init(
                info: response.info,
                content: try response.content.map { try scoped($0, requestBoundary: requestBoundary) },
                toolCalls: response.toolCalls,
                usage: response.usage,
                stopReason: response.stopReason, inputTransformations: response.inputTransformations
            ))
        default:
            return event
        }
    }

    private func scoped(_ content: ModelContent, requestBoundary: ModelProviderRequestBoundary? = nil) throws -> ModelContent {
        guard case .providerContinuation(let state) = content else { return content }
        return .providerContinuation(try scoped(state, requestBoundary: requestBoundary))
    }

    private func scoped(_ state: ModelProviderContinuation, requestBoundary: ModelProviderRequestBoundary? = nil) throws -> ModelProviderContinuation {
        guard state.model == model,
              state.origin == nil || state.origin == binding.continuationOrigin else {
            throw AgentModelBindingError.incompatibleContinuation
        }
        return .init(model: state.model, format: state.format, payload: state.payload, origin: binding.continuationOrigin, contextTransition: state.contextTransition, requestBoundary: requestBoundary)
    }

    private func validToolPairs(_ messages: [ModelMessage], allowUnresolvedToolTail: Bool,
                                initialPending: Set<ToolCallID> = []) -> Bool {
        var pending = initialPending
        var seenCallIDs = initialPending
        let leading = messages.prefix { $0.role == .system || $0.role == .developer }.count
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
                if index >= leading { guard pending.isEmpty else { return false } }
            }
            if allowUnresolvedToolTail, index == messages.index(before: messages.endIndex) {
                return true
            }
        }
        return pending.isEmpty
    }

    package static func toolError(_ error: any Error) -> any Error {
        guard let error = error as? ToolSchedulerError else { return error }
        switch error {
        case .deadlineExceeded: return AgentLoopError.deadlineExceeded
        case .toolTimedOut(let id): return AgentLoopError.toolTimedOut(id)
        }
    }

    /// A model-visible result for a call the model can correct: arguments that are not one JSON
    /// object, or that do not match the tool's input schema. `nil` for every other preparation failure.
    private static func invalidArgumentsFeedback(_ error: any Error, call: ToolCall) -> ToolResultMessage? {
        let name = call.name
        let retry = "so the tool was not run. Call \(name) again with arguments that match its input schema."
        let message: String
        switch error {
        case ToolRegistryError.invalidJSON:
            message = "The arguments for \(name) were not a valid JSON object (\(call.argumentsJSON.count) characters received), "
                + "so the tool was not run. Call \(name) again with one complete JSON object that matches its input schema."
        case ToolRegistryError.invalidArguments(let issue):
            let path = issue.path.count > 200 ? String(issue.path.prefix(200)) + "..." : issue.path
            switch issue.keyword {
            case "required":
                message = "The arguments for \(name) are missing the required field \(path), " + retry
            case "false" where !path.isEmpty:
                message = "The arguments for \(name) include \(path), which the tool does not accept, " + retry
            default:
                let location = path.isEmpty ? "The arguments for \(name) do" : "The value at \(path) in the arguments for \(name) does"
                message = "\(location) not satisfy the \"\(issue.keyword)\" rule of its input schema, " + retry
            }
        case ToolInvocationError.invalidArguments:
            message = "The arguments for \(name) did not match its input schema, " + retry
        default:
            return nil
        }
        return ToolResultMessage(callID: call.id, content: [.json(.object([
            "code": .string("invalid_arguments"),
            "message": .string(message),
        ]))], isError: true)
    }

    private static func modelSubmittedReference(_ reference: EvidenceReference,
                                                argumentsJSON: String) -> String? {
        guard reference.id.utf8.count <= 80,
              reference.id.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte)
                      || (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
              }),
              let arguments = try? JSONValue.decodeToolArguments(argumentsJSON) else { return nil }
        func contains(_ value: JSONValue) -> Bool {
            switch value {
            case .string(let text): return text == reference.id
            case .array(let values): return values.contains(where: contains)
            case .object(let values): return values.values.contains(where: contains)
            default: return false
            }
        }
        return contains(arguments) ? reference.id : nil
    }

    private func checkpointContent(_ response: ModelResponse, retainingToolCalls count: Int) -> [ModelContent] {
        // Opaque state describes the whole response, so discarding proposals invalidates it.
        guard count != response.toolCalls.count else { return response.content }
        return response.content.filter {
            if case .providerContinuation = $0 { return false }
            return true
        }
    }

    package static func idempotencyKey(
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
private actor AgentNativeOperationIDs {
    private var values: Set<UUID> = []
    func insert(_ id: UUID) { values.insert(id) }
    func ids() -> Set<UUID> { values }
}

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
