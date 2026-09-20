import AgentModels
import AgentUsage
import Foundation
@testable import LiveProviderSupport
import Testing

struct QualificationRunnerTests {
    @Test(arguments: [
        QualificationScenario.text,
        .tool,
        .restart,
        .structured,
        .usage,
        .cancel,
    ])
    func fixtureCasesUseTheRealAgentSessionRunAndDrainPath(_ scenario: QualificationScenario) async throws {
        let options = QualificationOptions(
            provider: .openAI,
            mode: .fixture,
            scenario: scenario,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .official
        )
        let environment = LiveEnvironment(process: [:])
        let configuration = try QualificationConfiguration.resolve(options: options, environment: environment)
        let runner = try QualificationRunner(
            configuration: configuration,
            budget: LiveRequestBudget(fileURL: nil),
            evidence: RequestEvidenceLedger()
        )

        let results = await runner.runSelected()

        #expect(results.count == 1)
        #expect(results[0].status == .pass)
        #expect(results[0].requestAttempts == 0)
        if scenario == .tool {
            #expect(results[0].toolCalls == 1)
            #expect(results[0].toolExecutions == 1)
            #expect(results[0].usageSummary.observedResponseCount == 2)
            #expect(results[0].usageSummary.inputTokens.reportedSubtotal == 34)
            #expect(results[0].usageSummary.outputTokens.reportedSubtotal == 14)
            #expect(results[0].usageSummary.totalTokens == 48)
            #expect(results[0].usageSummary.reasoningTokens.reportedSubtotal == 4)
            #expect(results[0].usageSummary.reasoningTokens.missingCount == 1)
        }
        if scenario == .restart {
            #expect(results[0].toolCalls == 1)
            #expect(results[0].toolExecutions == 1)
            #expect(results[0].note == "durable_tool_history_replayed_without_reexecution")
            #expect(results[0].usageSummary.observedResponseCount == 3)
        }
        if scenario == .text {
            #expect(results[0].usageSummary.observedResponseCount == 2)
            #expect(results[0].usageSummary.inputTokens.reportedSubtotal == 21)
            #expect(results[0].usageSummary.outputTokens.reportedSubtotal == 8)
        }
        if scenario == .cancel {
            #expect(results[0].usageSummary.observedResponseCount == 1)
            #expect(results[0].usageSummary.finalizedResponseCount == 0)
            #expect(results[0].usageSummary.provisionalResponseCount == 1)
            #expect(results[0].usageSummary.inputTokens.missingCount == 1)
        }
    }

    @Test func renderedUsageNamesScopeCoverageAndFieldCompleteness() async throws {
        let options = QualificationOptions(
            provider: .openAI,
            mode: .fixture,
            scenario: .tool,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .official
        )
        let configuration = try QualificationConfiguration.resolve(
            options: options,
            environment: LiveEnvironment(process: [:])
        )
        let runner = try QualificationRunner(
            configuration: configuration,
            budget: LiveRequestBudget(fileURL: nil),
            evidence: RequestEvidenceLedger()
        )

        let result = try #require(await runner.runSelected().first)
        #expect(result.rendered.contains("usage_scope=case_visible_responses"))
        #expect(result.rendered.contains("usage_coverage=public_model_responses"))
        #expect(result.rendered.contains("usage_responses=2"))
        #expect(result.rendered.contains("usage_input=34"))
        #expect(result.rendered.contains("usage_input_missing=0"))
        #expect(result.rendered.contains("usage_reasoning=4"))
        #expect(result.rendered.contains("usage_reasoning_missing=1"))
        #expect(result.rendered.contains("usage_cached_input=UNREPORTED"))
        #expect(result.rendered.contains("usage_cached_input_reported=0"))
        #expect(result.rendered.contains("usage_cached_input_missing=2"))
        #expect(result.rendered.contains("usage_cache_write_input=UNREPORTED"))
        #expect(result.rendered.contains("usage_cache_write_input_reported=0"))
        #expect(result.rendered.contains("usage_cache_write_input_missing=2"))
        #expect(result.rendered.contains("usage_total=48"))
        #expect(result.rendered.contains("usage_finalized_total=48"))
        #expect(result.rendered.contains("usage_provisional_total=UNREPORTED"))
        #expect(result.rendered.contains("cost=UNKNOWN"))
    }

    @Test(.timeLimit(.minutes(1)))
    func resultWaitsForTheSingleEventObserverToProcessTheFinalUsage() async throws {
        let gate = QualificationEventGate()
        let completion = QualificationCompletionProbe()
        let options = QualificationOptions(
            provider: .openAI,
            mode: .fixture,
            scenario: .usage,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .official
        )
        let configuration = try QualificationConfiguration.resolve(
            options: options,
            environment: LiveEnvironment(process: [:])
        )
        let runner = try QualificationRunner(
            configuration: configuration,
            budget: LiveRequestBudget(fileURL: nil),
            evidence: RequestEvidenceLedger(),
            usageEventHook: { event in
                if case .model(.responseCompleted) = event { await gate.pause() }
            }
        )

        let task = Task {
            let result = await runner.runSelected()
            await completion.markFinished()
            return result
        }
        await gate.waitUntilPaused()
        #expect(!(await completion.finished))
        await gate.resume()

        let result = try #require(await task.value.first)
        #expect(result.usageSummary.finalizedResponseCount == 1)
        #expect(result.usageSummary.totalTokens == 14)
    }

    @Test func failedSecondResponseKeepsPriorFinalUsageAndCurrentProvisionalUsage() async throws {
        let ledger = UsageLedger()
        let diagnostics = UsageDiagnosticsStore()
        var recorder = AgentUsageEventRecorder(ledger: ledger, diagnostics: diagnostics)
        let sessionID = UUID()
        let runID = UUID()
        let model = ModelID(provider: "fixture", name: "usage")
        let first = ResponseInfo(id: "first", model: model)
        let second = ResponseInfo(id: "second", model: model)

        await recorder.consume(.runStarted(.init(sessionID: sessionID, runID: runID, model: model)))
        await recorder.consume(.turnStarted(1))
        await recorder.consume(.model(.responseStarted(first)))
        await recorder.consume(.model(.usage(.init(inputTokens: 10, outputTokens: 3))))
        await recorder.consume(.model(.responseCompleted(.init(
            info: first,
            usage: .init(inputTokens: 10, outputTokens: 3),
            stopReason: .toolCalls
        ))))
        await recorder.consume(.turnStarted(2))
        await recorder.consume(.model(.responseStarted(second)))
        await recorder.consume(.model(.usage(.init(inputTokens: 8))))
        await recorder.consume(.runFinished(.failed(.provider(.init(
            kind: .invalidResponse,
            message: "sanitized"
        )))))

        let summary = await ledger.summary()
        #expect(summary.observedResponseCount == 2)
        #expect(summary.finalizedResponseCount == 1)
        #expect(summary.provisionalResponseCount == 1)
        #expect(summary.inputTokens.reportedSubtotal == 18)
        #expect(summary.outputTokens.reportedSubtotal == 3)
        #expect(summary.outputTokens.missingCount == 1)
        #expect(summary.totalTokens == nil)
        #expect(summary.finalizedUsage.totalTokens == 13)
        #expect(summary.provisionalUsage.inputTokens.reportedSubtotal == 8)
        #expect(summary.provisionalUsage.totalTokens == nil)
    }

    @Test(arguments: [StopReason.refusal, .maxOutputTokens])
    func terminalBusinessOutcomeDoesNotDiscardFinalUsage(_ stopReason: StopReason) async throws {
        let ledger = UsageLedger()
        let diagnostics = UsageDiagnosticsStore()
        var recorder = AgentUsageEventRecorder(ledger: ledger, diagnostics: diagnostics)
        let sessionID = UUID()
        let runID = UUID()
        let model = ModelID(provider: "fixture", name: "usage")
        let info = ResponseInfo(id: "terminal", model: model)

        await recorder.consume(.runStarted(.init(sessionID: sessionID, runID: runID, model: model)))
        await recorder.consume(.turnStarted(1))
        await recorder.consume(.model(.responseStarted(info)))
        await recorder.consume(.model(.responseCompleted(.init(
            info: info,
            usage: .init(inputTokens: 7, outputTokens: 2),
            stopReason: stopReason
        ))))

        let summary = await ledger.summary()
        #expect(summary.finalizedResponseCount == 1)
        #expect(summary.totalTokens == 9)
    }

    @Test func turnWithoutAResponseDoesNotCreateAUsageSample() async throws {
        let ledger = UsageLedger()
        let diagnostics = UsageDiagnosticsStore()
        var recorder = AgentUsageEventRecorder(ledger: ledger, diagnostics: diagnostics)
        let sessionID = UUID()
        let runID = UUID()
        let model = ModelID(provider: "fixture", name: "usage")

        await recorder.consume(.runStarted(.init(sessionID: sessionID, runID: runID, model: model)))
        await recorder.consume(.turnStarted(1))
        await recorder.consume(.runFinished(.cancelled))

        let summary = await ledger.summary()
        #expect(summary.observedResponseCount == 0)
        #expect(summary.coverage == .noSamples)
    }

    @Test func jevUsageKeepsDecisionCoverageAndDoesNotInventModelTurns() async throws {
        let options = QualificationOptions(
            provider: .jev,
            mode: .fixture,
            scenario: .choice,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .official
        )
        let configuration = try QualificationConfiguration.resolve(
            options: options,
            environment: LiveEnvironment(process: [:])
        )
        let runner = try QualificationRunner(
            configuration: configuration,
            budget: LiveRequestBudget(fileURL: nil),
            evidence: RequestEvidenceLedger()
        )

        let result = try #require(await runner.runSelected().first)
        #expect(result.status == .pass)
        #expect(result.modelTurns == 0)
        #expect(result.requestAttempts == 0)
        #expect(result.usageSummary.coverage == .decisionResponses)
        #expect(result.usageSummary.inputTokens.reportedSubtotal == 16)
        #expect(result.usageSummary.outputTokens.reportedSubtotal == 6)
    }

    @Test func jevMissingAndExplicitZeroUsageRemainDistinct() async throws {
        let missingLedger = UsageLedger()
        let missingDiagnostics = UsageDiagnosticsStore()
        await recordDecisionUsage(
            nil,
            model: "jev-fixture",
            scenario: .choice,
            ledger: missingLedger,
            diagnostics: missingDiagnostics
        )
        #expect((await missingLedger.summary()).observedResponseCount == 0)

        let zeroLedger = UsageLedger()
        let zeroDiagnostics = UsageDiagnosticsStore()
        await recordDecisionUsage(
            .init(inputTokens: 0, outputTokens: 0),
            model: "jev-fixture",
            scenario: .choice,
            ledger: zeroLedger,
            diagnostics: zeroDiagnostics
        )
        let zero = await zeroLedger.summary()
        #expect(zero.coverage == .decisionResponses)
        #expect(zero.inputTokens.reportedSubtotal == 0)
        #expect(zero.outputTokens.reportedSubtotal == 0)
        #expect(zero.totalTokens == 0)
    }

    @Test func allChatCasesIncludesStandaloneUsageAndCancellation() async throws {
        let options = QualificationOptions(
            provider: .openAI,
            mode: .fixture,
            scenario: .all,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .official
        )
        let configuration = try QualificationConfiguration.resolve(
            options: options,
            environment: LiveEnvironment(process: [:])
        )
        let runner = try QualificationRunner(
            configuration: configuration,
            budget: LiveRequestBudget(fileURL: nil),
            evidence: RequestEvidenceLedger()
        )

        let results = await runner.runSelected()

        #expect(results.map(\.scenario) == [.text, .tool, .restart, .structured, .usage, .cancel])
        #expect(results.allSatisfy { $0.status == .pass })
    }

    @Test func providerFailureNotesStaySanitizedAndPauseProtocolFailures() {
        let schema = ModelProviderError(kind: .invalidResponse, message: "Invalid provider response.")
        let redirect = ModelProviderError(kind: .invalidResponse, message: "HTTP redirects are not allowed.")
        let model = ModelProviderError(
            kind: .invalidResponse,
            message: "DeepSeek returned model 'vendor-private-value' but expected 'configured-value'."
        )
        let unavailable = ModelProviderError(kind: .unavailable, message: "Provider detail must not escape.")
        let event = ModelProviderError(
            kind: .invalidResponse,
            message: "Invalid DeepSeek event 'response.content_part.done'."
        )
        let completed = ModelProviderError(
            kind: .invalidResponse,
            message: "Invalid DeepSeek completed continuation."
        )

        #expect(providerFailureNote(schema) == "provider_invalidResponse_schema")
        #expect(providerFailureNote(redirect) == "provider_invalidResponse_redirect")
        #expect(providerFailureNote(model) == "provider_invalidResponse_model_identity")
        #expect(providerFailureNote(unavailable) == "provider_unavailable")
        #expect(providerFailureNote(event) == "provider_invalidResponse_event_response.content_part.done")
        #expect(providerFailureNote(completed) == "provider_invalidResponse_completed_continuation")
        #expect(!providerFailureNote(model).contains("vendor-private-value"))
        #expect(shouldPauseProvider(after: schema))
        #expect(shouldPauseProvider(after: .init(kind: .authentication, message: "x")))
        #expect(!shouldPauseProvider(after: .init(kind: .transport, message: "x")))
    }
}

private actor QualificationEventGate {
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

private actor QualificationCompletionProbe {
    private(set) var finished = false
    func markFinished() { finished = true }
}
