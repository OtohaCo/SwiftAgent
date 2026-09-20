import Foundation

public struct QualificationPreflight: Equatable, Sendable {
    public let provider: QualificationProvider
    public let mode: QualificationMode
    public let service: QualificationService
    public let origin: String
    public let model: String?
    public let credentialConfigured: Bool
    public let credentialVariable: String
    public let scenario: QualificationScenario
    public let perProviderLimit: Int
    public let totalLimit: Int

    public var rendered: String {
        let credentialStatus = mode == .fixture
            ? "UNUSED"
            : (provider == .local && !credentialConfigured
                ? "OPTIONAL_UNSET"
                : (credentialConfigured ? "CONFIGURED" : "MISSING"))
        let renderedCredentialVariable = mode == .fixture ? "UNUSED" : credentialVariable
        return [
            "mode=\(mode.rawValue.uppercased())",
            "provider=\(provider.rawValue)",
            "service=\(service.rawValue)",
            "origin=\(origin)",
            "model=\(model ?? "MISSING")",
            "credential=\(credentialStatus)",
            "credential_variable=\(renderedCredentialVariable)",
            "provider_request_limit=\(perProviderLimit)",
            "total_request_limit=\(totalLimit)",
            "case=\(scenario.rawValue)",
        ].joined(separator: " ")
    }
}

public struct QualificationConfiguration: Sendable {
    public let options: QualificationOptions
    public let model: String
    public let endpoint: URL
    public let reasoning: String?
    public let resolvedModel: String?
    let credential: String

    public static func preflight(
        options: QualificationOptions,
        environment: LiveEnvironment,
        perProviderLimit: Int = 12,
        totalLimit: Int = 48
    ) throws -> QualificationPreflight {
        if options.mode == .fixture {
            return .init(
                provider: options.provider,
                mode: options.mode,
                service: options.service,
                origin: "FIXTURE",
                model: options.modelOverride ?? "fixture",
                credentialConfigured: false,
                credentialVariable: "UNUSED",
                scenario: options.scenario,
                perProviderLimit: perProviderLimit,
                totalLimit: totalLimit
            )
        }
        let values = try resolveValues(options: options, environment: environment)
        return .init(
            provider: options.provider,
            mode: options.mode,
            service: options.service,
            origin: redactedOrigin(values.endpoint),
            model: values.model,
            credentialConfigured: values.credential != nil,
            credentialVariable: values.credentialVariable,
            scenario: options.scenario,
            perProviderLimit: perProviderLimit,
            totalLimit: totalLimit
        )
    }

    public static func resolve(
        options: QualificationOptions,
        environment: LiveEnvironment
    ) throws -> Self {
        if options.mode == .fixture {
            guard let endpoint = URL(string: "https://fixture.invalid") else {
                throw LiveConfigurationError.invalidEndpoint
            }
            return .init(
                options: options,
                model: options.modelOverride ?? "fixture",
                endpoint: endpoint,
                reasoning: options.reasoning,
                resolvedModel: nil,
                credential: "fixture"
            )
        }
        let values = try resolveValues(options: options, environment: environment)
        guard options.provider == .local || values.credential != nil else {
            throw LiveConfigurationError.missingCredential(values.credentialVariable)
        }
        guard let model = values.model else {
            throw LiveConfigurationError.missingModel(values.modelVariable)
        }
        return .init(
            options: options,
            model: model,
            endpoint: values.endpoint,
            reasoning: options.reasoning,
            resolvedModel: values.resolvedModel,
            credential: values.credential ?? ""
        )
    }

    private static func resolveValues(
        options: QualificationOptions,
        environment: LiveEnvironment
    ) throws -> ResolvedValues {
        let endpoint: URL
        let model: String?
        let credential: String?
        let credentialVariable: String
        let modelVariable: String
        let resolvedModel: String?

        switch options.provider {
        case .openAI:
            if options.service == .gateway {
                credentialVariable = "CHAINBOW_API_KEY"
                modelVariable = "CHAINBOW_MODEL"
                credential = environment.value(for: credentialVariable)
                model = options.modelOverride ?? environment.value(
                    for: modelVariable,
                    aliases: ["CHAINBOW_MODLE"]
                )
                endpoint = try configuredEndpoint(
                    override: options.endpointOverride,
                    environment: environment,
                    key: "CHAINBOW_BASE_URL",
                    fallback: "https://api.openai.com/v1/responses",
                    suffix: "v1/responses"
                )
                resolvedModel = environment.value(for: "CHAINBOW_RESOLVED_MODEL")
            } else {
                credentialVariable = "OPENAI_API_KEY"
                modelVariable = "OPENAI_MODEL"
                credential = environment.value(for: credentialVariable)
                model = options.modelOverride ?? environment.value(for: modelVariable)
                endpoint = try configuredEndpoint(
                    override: options.endpointOverride,
                    environment: environment,
                    key: "OPENAI_BASE_URL",
                    fallback: "https://api.openai.com/v1/responses",
                    suffix: "v1/responses"
                )
                resolvedModel = environment.value(for: "OPENAI_RESOLVED_MODEL")
            }
        case .deepSeek:
            credentialVariable = "DEEPSEEK_API_KEY"
            modelVariable = "DEEPSEEK_MODEL"
            credential = environment.value(for: credentialVariable)
            model = options.modelOverride ?? environment.value(for: modelVariable, aliases: ["DEEPSEEK_MODLE"])
            endpoint = try configuredEndpoint(
                override: options.endpointOverride,
                environment: environment,
                key: "DEEPSEEK_BASE_URL",
                fallback: "https://api.deepseek.com/responses",
                suffix: "responses"
            )
            resolvedModel = environment.value(for: "DEEPSEEK_RESOLVED_MODEL")
        case .anthropic:
            credentialVariable = "ANTHROPIC_API_KEY"
            modelVariable = "SWIFT_AGENT_ANTHROPIC_MODEL"
            credential = environment.value(for: credentialVariable)
            model = options.modelOverride
                ?? environment.value(for: modelVariable)
                ?? "claude-haiku-4-5-20251001"
            endpoint = try configuredEndpoint(
                override: options.endpointOverride,
                environment: environment,
                key: "ANTHROPIC_BASE_URL",
                fallback: "https://api.anthropic.com/v1/messages",
                suffix: "v1/messages"
            )
            resolvedModel = environment.value(for: "ANTHROPIC_RESOLVED_MODEL")
        case .local:
            credentialVariable = "SWIFTAGENT_LOCAL_API_KEY"
            modelVariable = "SWIFTAGENT_LOCAL_MODEL"
            credential = environment.value(for: credentialVariable)
            model = options.modelOverride ?? environment.value(for: modelVariable)
            endpoint = try configuredLocalBaseURL(
                override: options.endpointOverride,
                environment: environment,
                key: "SWIFTAGENT_LOCAL_BASE_URL",
                fallback: "http://127.0.0.1:1234/v1"
            )
            resolvedModel = nil
        case .jev:
            credentialVariable = "TYPESAFE_API_KEY"
            modelVariable = "TYPESAFE_MODEL"
            credential = environment.value(for: credentialVariable)
            model = options.modelOverride ?? environment.value(for: modelVariable) ?? "jev-latest"
            endpoint = try configuredEndpoint(
                override: options.endpointOverride,
                environment: environment,
                key: "TYPESAFE_BASE_URL",
                fallback: "https://api.typesafe.ai/v1/systemone",
                suffix: "v1/systemone"
            )
            resolvedModel = nil
        }
        return .init(
            credential: credential,
            credentialVariable: credentialVariable,
            model: model,
            modelVariable: modelVariable,
            endpoint: endpoint,
            resolvedModel: resolvedModel
        )
    }
}

private func configuredLocalBaseURL(
    override: URL?,
    environment: LiveEnvironment,
    key: String,
    fallback: String
) throws -> URL {
    let value = override ?? environment.value(for: key).flatMap(URL.init(string:)) ?? URL(string: fallback)
    guard let value, isSafeEndpointSyntax(value) else {
        throw LiveConfigurationError.invalidEndpoint
    }
    return value
}

private struct ResolvedValues {
    let credential: String?
    let credentialVariable: String
    let model: String?
    let modelVariable: String
    let endpoint: URL
    let resolvedModel: String?
}

private func configuredEndpoint(
    override: URL?,
    environment: LiveEnvironment,
    key: String,
    fallback: String,
    suffix: String
) throws -> URL {
    if let override { return override }
    let source = environment.value(for: key) ?? fallback
    guard var components = URLComponents(string: source), components.query == nil,
          let rawURL = components.url, isAllowedEndpoint(rawURL) else {
        throw LiveConfigurationError.invalidEndpoint
    }
    let normalizedSuffix = "/" + suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if components.path.isEmpty || components.path == "/" {
        components.path = normalizedSuffix
    } else if components.path == "/v1" && normalizedSuffix.hasPrefix("/v1/") {
        components.path = normalizedSuffix
    }
    guard let endpoint = components.url, isAllowedEndpoint(endpoint) else {
        throw LiveConfigurationError.invalidEndpoint
    }
    return endpoint
}

private func redactedOrigin(_ url: URL) -> String {
    guard let scheme = url.scheme, let host = url.host else { return "INVALID" }
    if let port = url.port, port != 80, port != 443 {
        return "\(scheme)://\(host):\(port)"
    }
    return "\(scheme)://\(host)"
}
