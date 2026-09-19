import Foundation

public enum QualificationProvider: String, CaseIterable, Codable, Sendable {
    case openAI = "openai"
    case deepSeek = "deepseek"
    case anthropic
    case jev
}

public enum QualificationMode: String, Codable, Sendable {
    case fixture
    case live
}

public enum QualificationScenario: String, CaseIterable, Codable, Sendable {
    case preflight
    case text
    case tool
    case restart
    case structured
    case usage
    case cancel
    case noul
    case choice
    case score
    case mixed
    case all
}

public enum QualificationService: String, Codable, Sendable {
    case official
    case gateway
}

public enum LiveConfigurationError: Error, Equatable, Sendable {
    case invalidArgument(String)
    case unsafeEnvironmentFile(line: Int)
    case unreadableEnvironmentFile
    case invalidEndpoint
    case missingBudgetFile
    case missingCredential(String)
    case missingModel(String)
    case unsupportedCombination(provider: QualificationProvider, scenario: QualificationScenario)
}

public func resolvedBudgetFile(
    options: QualificationOptions,
    environment: LiveEnvironment,
    required: Bool
) throws -> URL? {
    let file = options.budgetFile
        ?? environment.value(for: "SWIFT_AGENT_LIVE_BUDGET_FILE")
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
    if options.mode == .live, required, file == nil {
        throw LiveConfigurationError.missingBudgetFile
    }
    return file
}

public func resolvedEnvironmentFile(
    options: QualificationOptions,
    process: [String: String]
) -> URL? {
    if let explicit = options.environmentFile { return explicit }
    guard let path = normalized(process["SWIFT_AGENT_LIVE_ENV_FILE"]) else { return nil }
    return URL(fileURLWithPath: path).standardizedFileURL
}

public struct QualificationOptions: Equatable, Sendable {
    public let provider: QualificationProvider
    public let mode: QualificationMode
    public let scenario: QualificationScenario
    public let modelOverride: String?
    public let endpointOverride: URL?
    public let environmentFile: URL?
    public let budgetFile: URL?
    public let service: QualificationService
    public let reasoning: String?

    public init(
        provider: QualificationProvider,
        mode: QualificationMode,
        scenario: QualificationScenario,
        modelOverride: String?,
        endpointOverride: URL?,
        environmentFile: URL?,
        budgetFile: URL?,
        service: QualificationService,
        reasoning: String? = nil
    ) {
        self.provider = provider
        self.mode = mode
        self.scenario = scenario
        self.modelOverride = modelOverride
        self.endpointOverride = endpointOverride
        self.environmentFile = environmentFile
        self.budgetFile = budgetFile
        self.service = service
        self.reasoning = normalized(reasoning)
    }

    public static func parse(_ arguments: [String]) throws -> Self {
        var provider = QualificationProvider.openAI
        var mode = QualificationMode.fixture
        var scenario = QualificationScenario.preflight
        var model: String?
        var endpoint: URL?
        var environmentFile: URL?
        var budgetFile: URL?
        var service = QualificationService.official
        var reasoning: String?
        var index = 0

        func value(after flag: String) throws -> String {
            guard arguments.indices.contains(index + 1) else {
                throw LiveConfigurationError.invalidArgument("Missing value for \(flag).")
            }
            return arguments[index + 1]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--provider":
                let raw = try value(after: argument)
                guard let parsed = QualificationProvider(rawValue: raw) else {
                    throw LiveConfigurationError.invalidArgument("Unknown provider.")
                }
                provider = parsed
                index += 2
            case "--mode":
                let raw = try value(after: argument)
                guard let parsed = QualificationMode(rawValue: raw) else {
                    throw LiveConfigurationError.invalidArgument("Mode must be fixture or live.")
                }
                mode = parsed
                index += 2
            case "--case":
                let raw = try value(after: argument)
                guard let parsed = QualificationScenario(rawValue: raw) else {
                    throw LiveConfigurationError.invalidArgument("Unknown qualification case.")
                }
                scenario = parsed
                index += 2
            case "--model":
                model = try value(after: argument)
                index += 2
            case "--endpoint":
                let raw = try value(after: argument)
                guard let parsed = URL(string: raw), isAllowedEndpoint(parsed) else {
                    throw LiveConfigurationError.invalidEndpoint
                }
                endpoint = parsed
                index += 2
            case "--env-file":
                environmentFile = URL(fileURLWithPath: try value(after: argument)).standardizedFileURL
                index += 2
            case "--budget-file":
                budgetFile = URL(fileURLWithPath: try value(after: argument)).standardizedFileURL
                index += 2
            case "--service":
                let raw = try value(after: argument)
                guard let parsed = QualificationService(rawValue: raw) else {
                    throw LiveConfigurationError.invalidArgument("Service must be official or gateway.")
                }
                service = parsed
                index += 2
            case "--reasoning":
                reasoning = try value(after: argument)
                index += 2
            default:
                throw LiveConfigurationError.invalidArgument("Unknown argument: \(argument)")
            }
        }

        return .init(
            provider: provider,
            mode: mode,
            scenario: scenario,
            modelOverride: normalized(model),
            endpointOverride: endpoint,
            environmentFile: environmentFile,
            budgetFile: budgetFile,
            service: service,
            reasoning: normalized(reasoning)
        )
    }
}

func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func isAllowedEndpoint(_ url: URL) -> Bool {
    guard url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
          let host = url.host?.lowercased(), !host.isEmpty else { return false }
    if url.scheme?.lowercased() == "https" { return true }
    let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"]
    return url.scheme?.lowercased() == "http" && loopback.contains(host)
}
