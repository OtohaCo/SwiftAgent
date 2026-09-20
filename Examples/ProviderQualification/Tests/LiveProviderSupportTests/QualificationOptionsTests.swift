import Foundation
import LiveProviderSupport
import Testing

struct QualificationOptionsTests {
    @Test func defaultsToOfflineFixturePreflight() throws {
        let options = try QualificationOptions.parse([])
        #expect(options.mode == .fixture)
        #expect(options.scenario == .preflight)
        #expect(options.provider == .openAI)
    }

    @Test func localProviderAcceptsExplicitLANHTTPBaseURL() throws {
        let options = try QualificationOptions.parse([
            "--provider", "local",
            "--mode", "live",
            "--case", "text",
            "--model", "local-model",
            "--endpoint", "http://192.168.1.10:1234/v1",
            "--service", "local",
        ])

        #expect(options.provider == .local)
        #expect(options.endpointOverride?.absoluteString == "http://192.168.1.10:1234/v1")
        #expect(options.service == .local)
    }

    @Test func parsesOneExplicitProviderAndScenario() throws {
        let options = try QualificationOptions.parse([
            "--provider", "deepseek",
            "--mode", "live",
            "--case", "tool",
            "--model", "deepseek-flash",
            "--endpoint", "https://api.deepseek.example/responses",
            "--reasoning", "high",
            "--env-file", "/tmp/.env.live",
            "--budget-file", "/tmp/swiftagent-budget.json",
        ])

        #expect(options.provider == .deepSeek)
        #expect(options.mode == .live)
        #expect(options.scenario == .tool)
        #expect(options.modelOverride == "deepseek-flash")
        #expect(options.endpointOverride?.absoluteString == "https://api.deepseek.example/responses")
        #expect(options.reasoning == "high")
        #expect(options.environmentFile?.path == "/tmp/.env.live")
        #expect(options.budgetFile?.path == "/tmp/swiftagent-budget.json")
    }

    @Test func invalidOrIncompleteArgumentsFailClosed() {
        #expect(throws: LiveConfigurationError.self) {
            try QualificationOptions.parse(["--mode", "online"])
        }
        #expect(throws: LiveConfigurationError.self) {
            try QualificationOptions.parse(["--provider"])
        }
        #expect(throws: LiveConfigurationError.self) {
            try QualificationOptions.parse(["--endpoint", "http://example.com"])
        }
    }

    @Test func liveRequestsRequireAPersistentBudgetLedger() throws {
        let live = QualificationOptions(
            provider: .openAI,
            mode: .live,
            scenario: .tool,
            modelOverride: "test-model",
            endpointOverride: URL(string: "https://api.openai.example/v1/responses"),
            environmentFile: nil,
            budgetFile: nil,
            service: .official
        )
        let environment = LiveEnvironment(process: [:])

        #expect(throws: LiveConfigurationError.missingBudgetFile) {
            try resolvedBudgetFile(options: live, environment: environment, required: true)
        }

        let fromEnvironment = try resolvedBudgetFile(
            options: live,
            environment: LiveEnvironment(process: ["SWIFT_AGENT_LIVE_BUDGET_FILE": "/tmp/shared-budget.json"]),
            required: true
        )
        #expect(fromEnvironment?.path == "/tmp/shared-budget.json")

        let fixture = QualificationOptions(
            provider: .openAI,
            mode: .fixture,
            scenario: .tool,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .official
        )
        #expect(try resolvedBudgetFile(options: fixture, environment: environment, required: true) == nil)
    }

    @Test func environmentFileResolutionIsExplicitAndDoesNotProbeTheWorkingDirectory() throws {
        let defaults = try QualificationOptions.parse([])
        #expect(resolvedEnvironmentFile(options: defaults, process: [:]) == nil)

        let fromProcess = resolvedEnvironmentFile(
            options: defaults,
            process: ["SWIFT_AGENT_LIVE_ENV_FILE": "/tmp/operator.env"]
        )
        #expect(fromProcess?.path == "/tmp/operator.env")

        let explicit = try QualificationOptions.parse(["--env-file", "/tmp/explicit.env"])
        let resolved = resolvedEnvironmentFile(
            options: explicit,
            process: ["SWIFT_AGENT_LIVE_ENV_FILE": "/tmp/operator.env"]
        )
        #expect(resolved?.path == "/tmp/explicit.env")
    }
}
