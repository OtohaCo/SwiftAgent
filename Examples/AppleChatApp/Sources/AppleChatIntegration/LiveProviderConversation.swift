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

        let environmentFile = resolvedEnvironmentFile(options: options, process: process)
        let environment = try LiveEnvironment.load(process: process, fileURL: environmentFile)
        let budgetLimits = try resolvedBudgetLimits(environment: environment)
        let configuration = try QualificationConfiguration.resolve(options: options, environment: environment)
        let budgetFile = try resolvedBudgetFile(options: options, environment: environment, required: true)
        let budget = try LiveRequestBudget(
            fileURL: budgetFile,
            perProviderLimit: budgetLimits.perProviderLimit,
            totalLimit: budgetLimits.totalLimit
        )
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
        if flags.contains(argument) {
            result.append(argument)
            if arguments.indices.contains(index + 1) {
                result.append(arguments[index + 1])
                index += 2
            } else {
                index += 1
            }
        } else {
            index += 1
        }
    }
    return result
}

public func renderedLaunchConfigurationError(_ error: any Error) -> String {
    if let error = error as? LiveConfigurationError {
        switch error {
        case .missingCredential(let variable):
            return "Set \(safeConfigurationVariable(variable)) in the local configuration, run preflight, and try again."
        case .missingModel(let variable):
            return "Set \(safeConfigurationVariable(variable)) to an available model, run preflight, and try again."
        case .missingBudgetFile:
            return "Choose a persistent live request budget file, then try again."
        case .invalidBudgetLimit(let variable):
            return "Set \(safeConfigurationVariable(variable)) to a valid positive integer, then try again."
        case .invalidEndpoint:
            return "The provider endpoint is invalid. Check the local configuration and try again."
        case .unsafeEnvironmentFile, .unreadableEnvironmentFile:
            return "The local provider configuration file could not be read safely."
        case .unsupportedCombination:
            return "The selected provider does not support this example mode."
        case .invalidArgument:
            return "The launch arguments are invalid. Use the documented fixture or live command."
        }
    }
    if let error = error as? LiveBudgetError {
        switch error {
        case .providerLimit(_, let limit):
            return "The Provider request budget of \(limit) attempts is exhausted."
        case .totalLimit(let limit):
            return "The shared live request budget of \(limit) attempts is exhausted."
        case .invalidLedger:
            return "The live request budget file is invalid."
        case .persistenceFailed:
            return "The live request budget could not be saved safely."
        }
    }
    return "The selected provider configuration is unavailable. Check the local preflight and try again."
}

private func safeConfigurationVariable(_ value: String) -> String {
    guard !value.isEmpty, value.count <= 64,
          value.unicodeScalars.allSatisfy({
              CharacterSet.alphanumerics.contains($0) || $0 == "_"
          }) else { return "the required setting" }
    return value
}

private func displayName(_ provider: QualificationProvider) -> String {
    switch provider {
    case .openAI: "OpenAI"
    case .deepSeek: "DeepSeek"
    case .anthropic: "Anthropic"
    case .local: "Local Responses"
    case .jev: "Jev"
    }
}
