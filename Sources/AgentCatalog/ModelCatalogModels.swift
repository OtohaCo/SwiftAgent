import AgentModels
import Foundation

/// A tri-state catalog fact. `unknown` is not equivalent to `unsupported`.
public struct ModelCatalogSupport: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let supported = Self(rawValue: "supported")
    public static let unsupported = Self(rawValue: "unsupported")
    public static let unknown = Self(rawValue: "unknown")

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Whether the installed adapter can encode a discovered control.
public struct ModelCatalogExecutability: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let executable = Self(rawValue: "executable")
    public static let adapterUpgradeRequired = Self(rawValue: "adapter_upgrade_required")
    public static let unknown = Self(rawValue: "unknown")

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A non-secret deployment boundary for catalog caches and execution policy.
public struct ModelServiceScope: Hashable, Sendable, Codable {
    public let provider: String
    public let serviceInstanceID: String
    public let endpointScope: String
    public let apiDialect: String
    public let apiVersion: String?
    public let authorizationScopeID: String?

    public init(
        provider: String,
        serviceInstanceID: String,
        endpointScope: String,
        apiDialect: String,
        apiVersion: String? = nil,
        authorizationScopeID: String? = nil
    ) throws {
        for (field, value) in [
            ("provider", provider),
            ("serviceInstanceID", serviceInstanceID),
            ("endpointScope", endpointScope),
            ("apiDialect", apiDialect),
        ] {
            guard isValidCatalogIdentity(value) else {
                throw ModelCatalogValidationError(kind: .invalidIdentity, field: field)
            }
        }
        if let apiVersion, !isValidCatalogIdentity(apiVersion) {
            throw ModelCatalogValidationError(kind: .invalidIdentity, field: "apiVersion")
        }
        if let authorizationScopeID, !isValidCatalogIdentity(authorizationScopeID) {
            throw ModelCatalogValidationError(kind: .invalidIdentity, field: "authorizationScopeID")
        }
        self.provider = provider
        self.serviceInstanceID = serviceInstanceID
        self.endpointScope = endpointScope
        self.apiDialect = apiDialect
        self.apiVersion = apiVersion
        self.authorizationScopeID = authorizationScopeID
    }
}

public struct ModelCatalogSourceKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let upstreamAPI = Self(rawValue: "upstream_api")
    public static let documentedContract = Self(rawValue: "documented_contract")
    public static let hostOverride = Self(rawValue: "host_override")
    public static let explicitProbe = Self(rawValue: "explicit_probe")

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Provenance for one catalog statement. `reference` must not contain credentials.
public struct ModelCatalogSource: Hashable, Sendable, Codable {
    public let kind: ModelCatalogSourceKind
    public let reference: String?
    public let revision: String?
    public let fetchedAt: Date?

    public init(
        kind: ModelCatalogSourceKind,
        reference: String? = nil,
        revision: String? = nil,
        fetchedAt: Date? = nil
    ) {
        self.kind = kind
        self.reference = reference
        self.revision = revision
        self.fetchedAt = fetchedAt
    }
}

public struct ModelReasoningControlKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let effort = Self(rawValue: "effort")
    public static let thinkingMode = Self(rawValue: "thinking_mode")
    public static let tokenBudget = Self(rawValue: "token_budget")

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ModelIntegerRange: Hashable, Sendable, Codable {
    public let minimum: Int
    public let maximum: Int

    public init(minimum: Int, maximum: Int) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// A provider-native reasoning control. Controls are intentionally independent.
public struct ModelReasoningControlDescriptor: Hashable, Sendable, Codable {
    public let parameter: String
    public let kind: ModelReasoningControlKind
    public let support: ModelCatalogSupport
    public let allowedValues: [String]?
    public let valuesAreExhaustive: Bool
    public let integerRange: ModelIntegerRange?
    public let defaultValue: JSONValue?
    public let requires: [String: JSONValue]
    public let excludes: [String: JSONValue]
    public let executability: ModelCatalogExecutability

    public init(
        parameter: String,
        kind: ModelReasoningControlKind,
        support: ModelCatalogSupport,
        allowedValues: [String]? = nil,
        valuesAreExhaustive: Bool = false,
        integerRange: ModelIntegerRange? = nil,
        defaultValue: JSONValue? = nil,
        requires: [String: JSONValue] = [:],
        excludes: [String: JSONValue] = [:],
        executability: ModelCatalogExecutability
    ) {
        self.parameter = parameter
        self.kind = kind
        self.support = support
        self.allowedValues = allowedValues
        self.valuesAreExhaustive = valuesAreExhaustive
        self.integerRange = integerRange
        self.defaultValue = defaultValue
        self.requires = requires
        self.excludes = excludes
        self.executability = executability
    }
}

/// Model capabilities reported by a catalog, preserving unreported values.
public struct ModelCatalogCapabilities: Hashable, Sendable, Codable {
    public let multiTurn: ModelCatalogSupport
    public let tools: ModelCatalogSupport
    public let structuredOutput: ModelCatalogSupport
    public let reasoning: ModelCatalogSupport
    public let configurableReasoning: ModelCatalogSupport

    public static let unknown = Self()

    public init(
        multiTurn: ModelCatalogSupport = .unknown,
        tools: ModelCatalogSupport = .unknown,
        structuredOutput: ModelCatalogSupport = .unknown,
        reasoning: ModelCatalogSupport = .unknown,
        configurableReasoning: ModelCatalogSupport = .unknown
    ) {
        self.multiTurn = multiTurn
        self.tools = tools
        self.structuredOutput = structuredOutput
        self.reasoning = reasoning
        self.configurableReasoning = configurableReasoning
    }
}

public struct ModelCatalogConflict: Hashable, Sendable, Codable {
    public let field: String
    public let values: [JSONValue]
    public let sources: [ModelCatalogSource]

    public init(field: String, values: [JSONValue], sources: [ModelCatalogSource]) {
        self.field = field
        self.values = values
        self.sources = sources
    }
}

/// An open catalog record. Presence does not make a model an executable candidate.
public struct ModelCatalogEntry: Hashable, Sendable, Codable {
    public let model: ModelID
    public let deploymentID: String
    public let serviceScope: ModelServiceScope
    public let displayName: String?
    public let aliases: [String]
    public let resolvedModel: ModelID?
    public let capabilities: ModelCatalogCapabilities
    public let reasoningControls: [ModelReasoningControlDescriptor]
    public let maximumInputTokens: Int?
    public let maximumOutputTokens: Int?
    public let metadataComplete: Bool
    public let sources: [ModelCatalogSource]
    public let conflicts: [ModelCatalogConflict]

    public init(
        model: ModelID,
        deploymentID: String,
        serviceScope: ModelServiceScope,
        displayName: String? = nil,
        aliases: [String] = [],
        resolvedModel: ModelID? = nil,
        capabilities: ModelCatalogCapabilities = .unknown,
        reasoningControls: [ModelReasoningControlDescriptor] = [],
        maximumInputTokens: Int? = nil,
        maximumOutputTokens: Int? = nil,
        metadataComplete: Bool = false,
        sources: [ModelCatalogSource],
        conflicts: [ModelCatalogConflict] = []
    ) {
        self.model = model
        self.deploymentID = deploymentID
        self.serviceScope = serviceScope
        self.displayName = displayName
        self.aliases = aliases
        self.resolvedModel = resolvedModel
        self.capabilities = capabilities
        self.reasoningControls = reasoningControls
        self.maximumInputTokens = maximumInputTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.metadataComplete = metadataComplete
        self.sources = sources
        self.conflicts = conflicts
    }
}

public struct ModelCatalogValidationError: Error, Equatable, Sendable {
    public struct Kind: RawRepresentable, Hashable, Sendable, Codable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let invalidIdentity = Self(rawValue: "invalid_identity")
    }

    public let kind: Kind
    public let field: String

    public init(kind: Kind, field: String) {
        self.kind = kind
        self.field = field
    }
}

private func isValidCatalogIdentity(_ value: String) -> Bool {
    value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        && !value.isEmpty
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}
