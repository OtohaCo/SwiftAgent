@testable import AppleChatIntegration
import Foundation
import LiveProviderSupport
import Testing

struct LiveProviderConversationTests {
    @Test func explicitLiveConfigurationDoesNotFallBackWhenCredentialIsMissing() {
        #expect(throws: LiveConfigurationError.missingCredential("OPENAI_API_KEY")) {
            try AppleChatLaunchConfiguration.resolve(
                arguments: ["--provider", "openai", "--mode", "live", "--model", "test-model"],
                process: [:]
            )
        }
    }

    @Test func fixtureModeIsNotInferredFromAnUnrelatedLiveArgumentValue() throws {
        let launch = try AppleChatLaunchConfiguration.resolve(
            arguments: ["--mode", "fixture", "--model", "live"],
            process: [:]
        )

        #expect(!launch.isLive)
        #expect(launch.modeLabel == "FIXTURE")
        #expect(launch.providerLabel == "Local fixture")
    }

    @Test func providerControllerUsesTheExistingConversationLifecycleAndToolPath() async throws {
        let options = QualificationOptions(
            provider: .openAI,
            mode: .fixture,
            scenario: .text,
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
        let selection = try LiveProviderFactory.makeModelProvider(
            configuration: configuration,
            budget: LiveRequestBudget(fileURL: nil),
            evidence: RequestEvidenceLedger()
        )
        let controller = try makeProviderConversationController(selection: selection)
        var snapshots = controller.snapshots.makeAsyncIterator()
        _ = await snapshots.next()

        _ = try await controller.send("Use lookup_account for account A-100 and summarize it")
        let terminal = await terminalSnapshot(&snapshots)

        #expect(terminal.terminal == .completed)
        #expect(terminal.items.compactMap(\.tool).contains { $0.state == .completed && !$0.isError })
    }

    @Test func configuredLaunchReportsProviderModelAndLiveModeWithoutSecrets() throws {
        let launch = try AppleChatLaunchConfiguration.resolve(
            arguments: [
                "--provider", "deepseek", "--mode", "live", "--model", "deepseek-test",
                "--endpoint", "https://api.deepseek.example/responses",
            ],
            process: ["DEEPSEEK_API_KEY": "secret-value"]
        )

        #expect(launch.modeLabel == "LIVE")
        #expect(launch.providerLabel == "DeepSeek")
        #expect(launch.modelLabel == "deepseek-test")
        #expect(!launch.displayLabel.contains("secret-value"))
    }
}

private func terminalSnapshot(
    _ iterator: inout AsyncStream<ConversationSnapshot>.Iterator
) async -> ConversationSnapshot {
    while let snapshot = await iterator.next() {
        if snapshot.terminal != nil, snapshot.phase == .idle { return snapshot }
    }
    Issue.record("Snapshot stream ended before terminal and drain")
    return .init(conversationID: UUID())
}

private extension ConversationItem {
    var tool: DisplayToolCall? {
        guard case .tool(let value) = self else { return nil }
        return value
    }
}
