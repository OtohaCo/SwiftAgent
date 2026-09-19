import AgentModels
@testable import LiveProviderSupport
import Testing

struct QualificationRunnerTests {
    @Test(arguments: [
        QualificationScenario.text,
        .tool,
        .restart,
        .structured,
        .usage,
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
        #expect(results[0].requestAttempts > 0)
        if scenario == .tool {
            #expect(results[0].toolCalls == 1)
            #expect(results[0].toolExecutions == 1)
        }
        if scenario == .restart {
            #expect(results[0].toolCalls == 1)
            #expect(results[0].toolExecutions == 1)
            #expect(results[0].note == "durable_tool_history_replayed_without_reexecution")
        }
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
