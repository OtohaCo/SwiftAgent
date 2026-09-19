import AgentCore
import AgentDecisions
import AgentJevProvider
import AgentModels
import AgentTools
import Foundation

public enum QualificationCaseStatus: String, Codable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case notExercised = "NOT_EXERCISED"
    case notRun = "NOT_RUN"
    case notRunBudget = "NOT_RUN_BUDGET"
    case blockedConfiguration = "BLOCKED_CONFIGURATION"
    case blockedPlatform = "BLOCKED_PLATFORM"
}

public struct QualificationCaseResult: Sendable {
    public let scenario: QualificationScenario
    public let status: QualificationCaseStatus
    public let requestAttempts: Int
    public let modelTurns: Int
    public let toolCalls: Int
    public let toolExecutions: Int
    public let usage: ModelUsage
    public let note: String

    public var rendered: String {
        let input = usage.inputTokens.map(String.init) ?? "UNREPORTED"
        let output = usage.outputTokens.map(String.init) ?? "UNREPORTED"
        let reasoning = usage.reasoningTokens.map(String.init) ?? "UNREPORTED"
        return "case=\(scenario.rawValue) status=\(status.rawValue) attempts=\(requestAttempts) "
            + "model_turns=\(modelTurns) tool_calls=\(toolCalls) tool_executions=\(toolExecutions) "
            + "usage_input=\(input) usage_output=\(output) usage_reasoning=\(reasoning) note=\(note)"
    }
}

public struct QualificationRunner: Sendable {
    private let configuration: QualificationConfiguration
    private let budget: LiveRequestBudget
    private let evidence: RequestEvidenceLedger
    private let modelSelection: ConfiguredModelProvider?

    public init(
        configuration: QualificationConfiguration,
        budget: LiveRequestBudget,
        evidence: RequestEvidenceLedger
    ) throws {
        self.configuration = configuration
        self.budget = budget
        self.evidence = evidence
        modelSelection = configuration.options.provider == .jev ? nil : try LiveProviderFactory.makeModelProvider(
            configuration: configuration,
            budget: budget,
            evidence: evidence
        )
    }

    public func runSelected() async -> [QualificationCaseResult] {
        let scenarios = selectedScenarios()
        var results: [QualificationCaseResult] = []
        var pauseReason: String?
        for scenario in scenarios {
            if let pauseReason {
                results.append(.init(
                    scenario: scenario,
                    status: .notRun,
                    requestAttempts: 0,
                    modelTurns: 0,
                    toolCalls: 0,
                    toolExecutions: 0,
                    usage: .init(),
                    note: pauseReason
                ))
                continue
            }
            let before = await budget.snapshot().totalAttempts
            do {
                let result = try await run(scenario)
                let after = await budget.snapshot().totalAttempts
                results.append(withAttempts(result, attempts: max(after - before, result.requestAttempts)))
            } catch let error as LiveBudgetError {
                let attempts = await attemptsSince(before)
                results.append(.init(
                    scenario: scenario,
                    status: .notRunBudget,
                    requestAttempts: attempts,
                    modelTurns: 0,
                    toolCalls: 0,
                    toolExecutions: 0,
                    usage: .init(),
                    note: budgetNote(error)
                ))
            } catch let error as LiveConfigurationError {
                let attempts = await attemptsSince(before)
                results.append(.init(
                    scenario: scenario,
                    status: .blockedConfiguration,
                    requestAttempts: attempts,
                    modelTurns: 0,
                    toolCalls: 0,
                    toolExecutions: 0,
                    usage: .init(),
                    note: configurationNote(error)
                ))
            } catch is CancellationError {
                let attempts = await attemptsSince(before)
                results.append(.init(
                    scenario: scenario,
                    status: scenario == .cancel ? .pass : .fail,
                    requestAttempts: attempts,
                    modelTurns: 0,
                    toolCalls: 0,
                    toolExecutions: 0,
                    usage: .init(),
                    note: scenario == .cancel ? "cancelled_and_drained" : "unexpected_cancellation"
                ))
            } catch let error as ModelProviderError {
                results.append(failure(
                    scenario,
                    attempts: await attemptsSince(before),
                    note: providerFailureNote(error)
                ))
                if shouldPauseProvider(after: error) {
                    pauseReason = "paused_after_\(error.kind.rawValue)"
                }
            } catch let error as DecisionProviderError {
                results.append(failure(
                    scenario,
                    attempts: await attemptsSince(before),
                    note: "decision_\(error.kind.rawValue)"
                ))
            } catch {
                results.append(failure(
                    scenario,
                    attempts: await attemptsSince(before),
                    note: "unclassified_failure"
                ))
            }
        }
        return results
    }

    public func requestEvidence() async -> [RequestEvidenceEntry] {
        await evidence.entries
    }

    private func attemptsSince(_ total: Int) async -> Int {
        max(0, await budget.snapshot().totalAttempts - total)
    }

    private func selectedScenarios() -> [QualificationScenario] {
        guard configuration.options.scenario == .all else { return [configuration.options.scenario] }
        if configuration.options.provider == .jev { return [.noul, .choice, .score, .mixed] }
        return [.text, .tool, .restart, .structured, .cancel]
    }

    private func run(_ scenario: QualificationScenario) async throws -> QualificationCaseResult {
        if configuration.options.provider == .jev { return try await runJev(scenario) }
        guard let modelSelection else {
            throw LiveConfigurationError.unsupportedCombination(
                provider: configuration.options.provider,
                scenario: scenario
            )
        }
        switch scenario {
        case .preflight:
            return .init(
                scenario: scenario, status: .pass, requestAttempts: 0, modelTurns: 0,
                toolCalls: 0, toolExecutions: 0, usage: .init(), note: "offline_preflight"
            )
        case .text:
            return try await runText(modelSelection)
        case .tool:
            return try await runTool(modelSelection)
        case .restart:
            return try await runRestart(modelSelection)
        case .structured:
            return try await runStructured(modelSelection)
        case .usage:
            return try await runUsage(modelSelection)
        case .cancel:
            return try await runCancellation(modelSelection)
        case .noul, .choice, .score, .mixed, .all:
            throw LiveConfigurationError.unsupportedCombination(
                provider: configuration.options.provider,
                scenario: scenario
            )
        }
    }

    private func runText(_ selection: ConfiguredModelProvider) async throws -> QualificationCaseResult {
        let agent = try makeAgent(selection: selection)
        let session = try agent.makeSession()
        let first = try await execute(session: session, prompt: "Remember the synthetic code BLUE-17 and reply briefly.")
        let second = try await execute(session: session, prompt: "Reply with only the synthetic code from my previous message.")
        let lastEvidence = await evidence.entries.last
        let historyAccepted = configuration.options.mode == .fixture
            || (lastEvidence?.hasAssistantHistory == true
                && lastEvidence?.hasQualificationHistoryMarker == true)
        let status: QualificationCaseStatus = historyAccepted ? .pass : .fail
        return .init(
            scenario: .text,
            status: status,
            requestAttempts: first.modelTurns + second.modelTurns,
            modelTurns: first.modelTurns + second.modelTurns,
            toolCalls: 0,
            toolExecutions: 0,
            usage: merge(first.response.usage, second.response.usage),
            note: historyAccepted ? "second_request_contains_committed_history" : "history_not_observed"
        )
    }

    private func runTool(_ selection: ConfiguredModelProvider) async throws -> QualificationCaseResult {
        let probe = ToolExecutionProbe()
        let agent = try makeAgent(selection: selection, tools: [try AddNumbersTool(probe: probe)])
        let session = try agent.makeSession()
        let result = try await execute(
            session: session,
            prompt: "Use add_numbers exactly once with lhs 2 and rhs 3. Then report the verified sum."
        )
        let executions = await probe.count
        let lastEvidence = await evidence.entries.last
        let requestAcceptedToolResult = configuration.options.mode == .fixture
            || lastEvidence?.hasBoundToolResult == true
        let exercised = result.toolCalls == 1 && executions == 1 && result.modelTurns == 2
        return .init(
            scenario: .tool,
            status: exercised && requestAcceptedToolResult ? .pass : .notExercised,
            requestAttempts: result.modelTurns,
            modelTurns: result.modelTurns,
            toolCalls: result.toolCalls,
            toolExecutions: executions,
            usage: result.response.usage,
            note: exercised && requestAcceptedToolResult
                ? "model_called_local_tool_and_accepted_result"
                : "model_did_not_complete_required_tool_loop"
        )
    }

    private func runRestart(_ selection: ConfiguredModelProvider) async throws -> QualificationCaseResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftagent-live-restart-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.log")
        let sessionID = UUID()
        let probe = ToolExecutionProbe()
        let tool = try AddNumbersTool(probe: probe)
        let firstJournal = try AgentJournal(persistenceURL: journalURL)
        let firstAgent = try makeAgent(selection: selection, tools: [tool])
        let firstSession = try firstAgent.makeSession(id: sessionID, journal: firstJournal)
        let first = try await execute(
            session: firstSession,
            prompt: "Use add_numbers exactly once with lhs 2 and rhs 3. Remember marker RESTART-TOOL-17 with the verified sum."
        )
        let executionsAfterFirstRun = await probe.count

        let restarted = try AgentJournal.load(from: journalURL)
        let secondAgent = try makeAgent(selection: selection, tools: [tool])
        let secondSession = try secondAgent.makeSession(id: sessionID, journal: restarted)
        let second = try await execute(
            session: secondSession,
            prompt: "After restart, report marker RESTART-TOOL-17 and the prior verified sum without calling add_numbers again."
        )
        let finalExecutions = await probe.count
        let lastEvidence = await evidence.entries.last
        let requestHasDurableToolHistory = configuration.options.mode == .fixture
            || (lastEvidence?.hasAssistantHistory == true
                && lastEvidence?.hasQualificationHistoryMarker == true
                && lastEvidence?.hasBoundToolResult == true)
        let replayAccepted = first.toolCalls == 1
            && second.toolCalls == 0
            && executionsAfterFirstRun == 1
            && finalExecutions == 1
            && requestHasDurableToolHistory
        return .init(
            scenario: .restart,
            status: replayAccepted ? .pass : .fail,
            requestAttempts: first.modelTurns + second.modelTurns,
            modelTurns: first.modelTurns + second.modelTurns,
            toolCalls: first.toolCalls + second.toolCalls,
            toolExecutions: finalExecutions,
            usage: merge(first.response.usage, second.response.usage),
            note: replayAccepted
                ? "durable_tool_history_replayed_without_reexecution"
                : "restart_tool_history_or_execution_count_mismatch"
        )
    }

    private func runStructured(_ selection: ConfiguredModelProvider) async throws -> QualificationCaseResult {
        let schema = StructuredOutputSchema(
            name: "qualification_answer",
            schema: ToolSchema.object(properties: ["answer": .string], required: ["answer"]).json
        )
        let agent = try makeAgent(selection: selection, structuredOutput: schema)
        let result = try await execute(
            session: try agent.makeSession(),
            prompt: "Return a JSON object whose answer field is exactly SwiftAgent."
        )
        let text = responseText(result.response)
        let parsed = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
        let valid: Bool
        if case .object(let object) = parsed, object["answer"] == .string("SwiftAgent") { valid = true }
        else { valid = false }
        return .init(
            scenario: .structured,
            status: valid ? .pass : .fail,
            requestAttempts: result.modelTurns,
            modelTurns: result.modelTurns,
            toolCalls: 0,
            toolExecutions: 0,
            usage: result.response.usage,
            note: valid ? "complete_terminal_json_validated" : "structured_output_invalid"
        )
    }

    private func runUsage(_ selection: ConfiguredModelProvider) async throws -> QualificationCaseResult {
        let result = try await execute(
            session: try makeAgent(selection: selection).makeSession(),
            prompt: "Reply with exactly SwiftAgent."
        )
        let reported = result.response.usage.inputTokens != nil || result.response.usage.outputTokens != nil
        return .init(
            scenario: .usage,
            status: reported ? .pass : .notExercised,
            requestAttempts: result.modelTurns,
            modelTurns: result.modelTurns,
            toolCalls: 0,
            toolExecutions: 0,
            usage: result.response.usage,
            note: reported ? "provider_reported_cumulative_usage" : "usage_unreported"
        )
    }

    private func runCancellation(_ selection: ConfiguredModelProvider) async throws -> QualificationCaseResult {
        let run = try await makeAgent(selection: selection, maxModelTurns: 1)
            .makeSession()
            .run("Hold this response until cancellation, while drafting a long synthetic answer.")
        let cancellation = CancellationObservation()
        let events = run.events
        let observer = Task {
            for await event in events {
                if case .model(.responseStarted) = event {
                    await cancellation.markRequestStarted()
                    await run.cancel()
                }
            }
        }
        let completedNormally: Bool
        do {
            _ = try await run.wait()
            completedNormally = true
        } catch is CancellationError {
            completedNormally = false
        }
        try await run.waitForDrain()
        _ = await observer.result
        let started = await cancellation.requestStarted
        return .init(
            scenario: .cancel,
            status: started && !completedNormally ? .pass : .notExercised,
            requestAttempts: started ? 1 : 0,
            modelTurns: 0,
            toolCalls: 0,
            toolExecutions: 0,
            usage: .init(),
            note: started && !completedNormally ? "request_started_then_cancelled_and_drained" : "response_completed_before_cancel"
        )
    }

    private func runJev(_ scenario: QualificationScenario) async throws -> QualificationCaseResult {
        guard [.preflight, .noul, .choice, .score, .mixed].contains(scenario) else {
            throw LiveConfigurationError.unsupportedCombination(provider: .jev, scenario: scenario)
        }
        if scenario == .preflight {
            return .init(
                scenario: scenario, status: .pass, requestAttempts: 0, modelTurns: 0,
                toolCalls: 0, toolExecutions: 0, usage: .init(), note: "offline_preflight"
            )
        }
        let request = try jevRequest(scenario)
        let response: DecisionResponse
        if configuration.options.mode == .fixture {
            response = fixtureJevResponse(request)
        } else {
            try await budget.reserve(.jev)
            let provider = try JevDecisionProvider(
                apiKey: configuration.credential,
                endpoint: configuration.endpoint,
                model: configuration.model,
                requestTimeout: .seconds(120)
            )
            response = try await provider.decide(request)
        }
        let valid = validateJev(response, request: request)
        return .init(
            scenario: scenario,
            status: valid ? .pass : .fail,
            requestAttempts: 1,
            modelTurns: 0,
            toolCalls: 0,
            toolExecutions: 0,
            usage: .init(
                inputTokens: response.usage?.inputTokens,
                outputTokens: response.usage?.outputTokens
            ),
            note: valid ? "typed_decision_validated_no_execution_authority" : "decision_contract_mismatch"
        )
    }

    private func makeAgent(
        selection: ConfiguredModelProvider,
        tools: [any AgentTool] = [],
        structuredOutput: StructuredOutputSchema? = nil,
        maxModelTurns: Int = 3
    ) throws -> Agent {
        try Agent(
            model: selection.model,
            provider: selection.provider,
            tools: tools,
            configuration: .init(
                instructions: "Follow the synthetic qualification request exactly. Use registered tools when explicitly required.",
                structuredOutput: structuredOutput,
                maxModelTurns: maxModelTurns,
                maxToolCalls: 2,
                runTimeout: .seconds(120)
            )
        )
    }

    private func execute(session: AgentSession, prompt: String) async throws -> AgentLoopResult {
        let run = try await session.run(prompt)
        let events = run.events
        let observer = Task {
            for await _ in events {}
        }
        do {
            let result = try await run.wait()
            try await run.waitForDrain()
            _ = await observer.result
            return result
        } catch {
            _ = try? await run.waitForDrain()
            _ = await observer.result
            throw error
        }
    }
}

private actor ToolExecutionProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct AddNumbersTool: AgentTool {
    struct Input: Codable, Sendable { let lhs: Int; let rhs: Int }
    struct Output: Codable, Sendable { let sum: Int }
    static let name = "add_numbers"
    static let description = "Add two synthetic integers using the local host executor."
    static let inputSchema = ToolSchema.object(
        properties: ["lhs": .integer, "rhs": .integer],
        required: ["lhs", "rhs"]
    )
    static let outputSchema = ToolSchema.object(properties: ["sum": .integer], required: ["sum"])
    let policy: ToolPolicy
    let probe: ToolExecutionProbe

    init(probe: ToolExecutionProbe) throws {
        self.probe = probe
        policy = try .readOnly(authorization: .notRequired)
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        .allowed
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.record()
        let (sum, overflow) = input.lhs.addingReportingOverflow(input.rhs)
        guard !overflow else { throw ModelProviderError(kind: .invalidRequest, message: "Synthetic addition overflow.") }
        return .init(output: .init(sum: sum))
    }
}

private actor CancellationObservation {
    private(set) var requestStarted = false
    func markRequestStarted() { requestStarted = true }
}

private func responseText(_ response: ModelResponse) -> String {
    response.content.compactMap { content -> String? in
        guard case .text(let text) = content else { return nil }
        return text
    }.joined()
}

private func merge(_ first: ModelUsage, _ second: ModelUsage) -> ModelUsage {
    func add(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }
    return .init(
        inputTokens: add(first.inputTokens, second.inputTokens),
        outputTokens: add(first.outputTokens, second.outputTokens),
        cachedInputTokens: add(first.cachedInputTokens, second.cachedInputTokens),
        cacheWriteInputTokens: add(first.cacheWriteInputTokens, second.cacheWriteInputTokens),
        reasoningTokens: add(first.reasoningTokens, second.reasoningTokens)
    )
}

private func withAttempts(_ result: QualificationCaseResult, attempts: Int) -> QualificationCaseResult {
    .init(
        scenario: result.scenario,
        status: result.status,
        requestAttempts: attempts,
        modelTurns: result.modelTurns,
        toolCalls: result.toolCalls,
        toolExecutions: result.toolExecutions,
        usage: result.usage,
        note: result.note
    )
}

func providerFailureNote(_ error: ModelProviderError) -> String {
    let suffix: String?
    switch error.message {
    case "Invalid provider response.": suffix = "schema"
    case "HTTP redirects are not allowed.": suffix = "redirect"
    case "Invalid HTTP response.": suffix = "http_response"
    case "Missing HTTP response.": suffix = "missing_http_response"
    default:
        if error.message.hasPrefix("DeepSeek returned model '") {
            suffix = "model_identity"
        } else if let event = safeDeepSeekEvent(from: error.message) {
            suffix = "event_\(event)"
        } else if let stage = safeDeepSeekCompletedStage(from: error.message) {
            suffix = "completed_\(stage)"
        } else {
            suffix = nil
        }
    }
    return "provider_\(error.kind.rawValue)\(suffix.map { "_\($0)" } ?? "")"
}

private func safeDeepSeekCompletedStage(from message: String) -> String? {
    let stages = ["identity", "lifecycle", "output snapshot", "usage", "continuation"]
    guard let stage = stages.first(where: { message == "Invalid DeepSeek completed \($0)." }) else {
        return nil
    }
    return stage.replacingOccurrences(of: " ", with: "_")
}

private func safeDeepSeekEvent(from message: String) -> String? {
    let prefix = "Invalid DeepSeek event '"
    guard message.hasPrefix(prefix), message.hasSuffix("'.") else { return nil }
    let start = message.index(message.startIndex, offsetBy: prefix.count)
    let end = message.index(message.endIndex, offsetBy: -2)
    let event = String(message[start..<end])
    guard !event.isEmpty, event.unicodeScalars.allSatisfy({ scalar in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-"
    }) else { return nil }
    return event
}

func shouldPauseProvider(after error: ModelProviderError) -> Bool {
    switch error.kind {
    case .authentication, .permissionDenied, .invalidRequest, .unsupportedCapability, .invalidResponse:
        true
    case .rateLimited, .unavailable, .transport, .fallbackBlocked:
        false
    }
}

private func failure(
    _ scenario: QualificationScenario,
    attempts: Int,
    note: String
) -> QualificationCaseResult {
    .init(
        scenario: scenario, status: .fail, requestAttempts: attempts, modelTurns: 0,
        toolCalls: 0, toolExecutions: 0, usage: .init(), note: note
    )
}

private func budgetNote(_ error: LiveBudgetError) -> String {
    switch error {
    case .providerLimit(let provider, let limit): "provider_limit_\(provider.rawValue)_\(limit)"
    case .totalLimit(let limit): "total_limit_\(limit)"
    case .invalidLedger: "invalid_budget_ledger"
    case .persistenceFailed: "budget_persistence_failed"
    }
}

private func configurationNote(_ error: LiveConfigurationError) -> String {
    switch error {
    case .missingCredential(let variable): "missing_\(variable)"
    case .missingModel(let variable): "missing_\(variable)"
    case .unsupportedCombination(let provider, let scenario): "unsupported_\(provider.rawValue)_\(scenario.rawValue)"
    case .invalidArgument: "invalid_argument"
    case .invalidEndpoint: "invalid_endpoint"
    case .missingBudgetFile: "missing_persistent_budget_file"
    case .unsafeEnvironmentFile: "unsafe_environment_file"
    case .unreadableEnvironmentFile: "unreadable_environment_file"
    }
}

private func jevRequest(_ scenario: QualificationScenario) throws -> DecisionRequest {
    let state: JSONValue = .object(["message": .string("Synthetic billing request needs review today.")])
    switch scenario {
    case .noul:
        return try .init(state: state, nouls: ["billing": .init(instructions: .string("Is this billing?"))])
    case .choice:
        return try .init(state: state, choices: ["route": try .init(criteria: [
            .init(name: "support", description: .string("General support")),
            .init(name: "billing", description: .string("Payment review")),
        ])])
    case .score:
        return try .init(state: state, scores: ["urgency": try .init(criteria: [
            .string("Can wait"), .string("This week"), .string("Today"),
        ])])
    case .mixed:
        return try .init(
            state: state,
            nouls: ["billing": .init(instructions: .string("Is this billing?"))],
            choices: ["route": try .init(criteria: [
                .init(name: "support", description: .string("General support")),
                .init(name: "billing", description: .string("Payment review")),
            ])],
            scores: ["urgency": try .init(criteria: [
                .string("Can wait"), .string("This week"), .string("Today"),
            ])]
        )
    default:
        throw LiveConfigurationError.unsupportedCombination(provider: .jev, scenario: scenario)
    }
}

private func fixtureJevResponse(_ request: DecisionRequest) -> DecisionResponse {
    .init(
        model: "jev-fixture",
        nouls: request.nouls.isEmpty ? [:] : ["billing": .init(probability: 0.9)],
        choices: request.choices.isEmpty ? [:] : ["route": .init(
            selected: "billing",
            confidence: 0.8,
            probabilities: [
                .init(name: "support", probability: 0.2),
                .init(name: "billing", probability: 0.8),
            ]
        )],
        scores: request.scores.isEmpty ? [:] : ["urgency": .init(
            score: 1.7,
            confidence: 0.8,
            legend: [.string("Can wait"), .string("This week"), .string("Today")],
            probabilities: [0.1, 0.1, 0.8]
        )],
        usage: .init(inputTokens: 16, outputTokens: 6)
    )
}

private func validateJev(_ response: DecisionResponse, request: DecisionRequest) -> Bool {
    guard Set(response.nouls.keys) == Set(request.nouls.keys),
          Set(response.choices.keys) == Set(request.choices.keys),
          Set(response.scores.keys) == Set(request.scores.keys) else { return false }
    for value in response.nouls.values where !(0...1).contains(value.probability) { return false }
    for (name, value) in response.choices {
        guard let question = request.choices[name] else { return false }
        let candidates = question.criteria.map(\.name)
        guard candidates.contains(value.selected), value.probabilities.map(\.name) == candidates,
              (0...1).contains(value.confidence), value.probabilities.allSatisfy({ (0...1).contains($0.probability) })
        else { return false }
    }
    for (name, value) in response.scores {
        guard let question = request.scores[name], value.legend == question.criteria,
              value.probabilities.count == question.criteria.count,
              (0...Double(question.criteria.count - 1)).contains(value.score),
              (0...1).contains(value.confidence),
              value.probabilities.allSatisfy({ (0...1).contains($0) })
        else { return false }
    }
    return true
}
