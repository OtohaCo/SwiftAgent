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
}
