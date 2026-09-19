import AgentCore
import Foundation
import LiveProviderSupport

public struct AppleChatLaunchConfiguration: Sendable {
    private enum Backend: Sendable {
        case fixture(FixtureConversationRoute)
        case provider(ConfiguredModelProvider)
    }

    private let backend: Backend
    public let modeLabel: String
    public let providerLabel: String
    public let modelLabel: String

    public var displayLabel: String {
        "\(providerLabel) · \(modeLabel) · \(modelLabel)"
    }

    public var isLive: Bool { modeLabel == "LIVE" }

    public static func resolve(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        process: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        let parsedArguments = extractQualificationArguments(arguments)
        let options = try QualificationOptions.parse(parsedArguments)
        guard options.mode == .live else {
            let route: FixtureConversationRoute = arguments.contains("--validated") ? .validated : .direct
            return .init(
                backend: .fixture(route),
                modeLabel: "FIXTURE",
                providerLabel: "Local fixture",
                modelLabel: route == .direct ? "streaming" : "validated"
            )
        }

        let environmentFile = options.environmentFile
            ?? process["SWIFT_AGENT_LIVE_ENV_FILE"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        let environment = try LiveEnvironment.load(process: process, fileURL: environmentFile)
        let budgetFile = options.budgetFile
            ?? environment.value(for: "SWIFT_AGENT_LIVE_BUDGET_FILE")
                .map { URL(fileURLWithPath: $0).standardizedFileURL }
        let budget = try LiveRequestBudget(fileURL: budgetFile)
        let configuration = try QualificationConfiguration.resolve(options: options, environment: environment)
        let selection = try LiveProviderFactory.makeModelProvider(
            configuration: configuration,
            budget: budget,
            evidence: RequestEvidenceLedger()
        )
        return .init(
            backend: .provider(selection),
            modeLabel: selection.modeLabel,
            providerLabel: displayName(options.provider),
            modelLabel: selection.model.name
        )
    }

    public func makeController(conversationID: UUID = UUID()) throws -> ConversationController {
        switch backend {
        case .fixture(let route):
            try makeFixtureConversationController(conversationID: conversationID, route: route, pacing: .visible)
        case .provider(let selection):
            try makeProviderConversationController(conversationID: conversationID, selection: selection)
        }
    }
}

public func makeProviderConversationController(
    conversationID: UUID = UUID(),
    selection: ConfiguredModelProvider
) throws -> ConversationController {
    let agent = try Agent(
        model: selection.model,
        provider: selection.provider,
        tools: [try AccountLookupTool()],
        configuration: .init(
            instructions: "Use lookup_account when the user asks about an account. Report only the observed local tool result.",
            maxModelTurns: 3,
            maxToolCalls: 2,
            runTimeout: .seconds(120)
        )
    )
    return ConversationController(
        conversationID: conversationID,
        session: AgentConversationSessionHandle(session: try agent.makeSession(id: conversationID))
    )
}

private func extractQualificationArguments(_ arguments: [String]) -> [String] {
    let flags = Set([
        "--provider", "--mode", "--case", "--model", "--endpoint",
        "--env-file", "--budget-file", "--service", "--reasoning",
    ])
    var result: [String] = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if flags.contains(argument), arguments.indices.contains(index + 1) {
            result.append(argument)
            result.append(arguments[index + 1])
            index += 2
        } else {
            index += 1
        }
    }
    return result
}

private func displayName(_ provider: QualificationProvider) -> String {
    switch provider {
    case .openAI: "OpenAI"
    case .deepSeek: "DeepSeek"
    case .anthropic: "Anthropic"
    case .jev: "Jev"
    }
}
