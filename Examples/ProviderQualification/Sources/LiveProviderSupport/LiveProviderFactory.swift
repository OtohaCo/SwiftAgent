import AgentModels
import AgentProviders
import Foundation

public struct ConfiguredModelProvider: Sendable {
    public let model: ModelID
    public let provider: any ModelProvider
    public let modeLabel: String
    public let serviceLabel: String
}

public enum LiveProviderFactory {
    public static func makeModelProvider(
        configuration: QualificationConfiguration,
        budget: LiveRequestBudget,
        evidence: RequestEvidenceLedger,
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
    ) throws -> ConfiguredModelProvider {
        let options = configuration.options
        let model = ModelID(provider: options.provider.rawValue, name: configuration.model)
        if options.mode == .fixture {
            return .init(
                model: model,
                provider: QualificationFixtureProvider(providerID: options.provider.rawValue),
                modeLabel: "FIXTURE",
                serviceLabel: "local"
            )
        }

        let budgeted = BudgetedProviderHTTPTransport(
            provider: options.provider,
            budget: budget,
            evidence: evidence,
            base: transport
        )
        let aliases = configuration.resolvedModel.map { [configuration.model: $0] } ?? [:]
        let provider: any ModelProvider
        switch options.provider {
        case .openAI:
            let effort = configuration.reasoning.map(OpenAIReasoningEffort.init(rawValue:))
            provider = try OpenAIResponsesProvider(
                apiKey: configuration.credential,
                endpoint: configuration.endpoint,
                maximumOutputTokens: 512,
                reasoningEffort: effort,
                reasoningSummary: effort == nil ? nil : .concise,
                resolvedModelIDsByAlias: aliases,
                transport: budgeted
            )
        case .deepSeek:
            provider = try DeepSeekResponsesProvider(
                apiKey: configuration.credential,
                endpoint: configuration.endpoint,
                maximumOutputTokens: 512,
                reasoningEffort: .init(rawValue: configuration.reasoning ?? "high"),
                resolvedModelIDsByAlias: aliases,
                transport: budgeted
            )
        case .anthropic:
            provider = try AnthropicProvider(
                apiKey: configuration.credential,
                endpoint: configuration.endpoint,
                maximumOutputTokens: 2_048,
                thinking: try anthropicThinking(configuration.reasoning),
                resolvedModelIDsByAlias: aliases,
                transport: budgeted
            )
        case .jev:
            throw LiveConfigurationError.unsupportedCombination(provider: .jev, scenario: options.scenario)
        }
        return .init(
            model: model,
            provider: provider,
            modeLabel: "LIVE",
            serviceLabel: options.service.rawValue
        )
    }
}

private func anthropicThinking(_ rawValue: String?) throws -> AnthropicThinking {
    switch rawValue?.lowercased() {
    case nil, "none": .disabled
    case "adaptive": .adaptive
    case "enabled", "minimal", "low", "medium", "high", "xhigh", "max": .enabled(budgetTokens: 1_024)
    default: throw LiveConfigurationError.invalidArgument("Unsupported Anthropic reasoning mode.")
    }
}
