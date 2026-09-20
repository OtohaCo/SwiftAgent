import AgentModels
import Foundation

public struct AgentModelDeployment: Hashable, Sendable, Codable {
    public let serviceInstanceID: String
    public let endpointScope: String
    public let apiDialect: String
    public let apiVersion: String?

    public init(
        serviceInstanceID: String,
        endpointScope: String,
        apiDialect: String,
        apiVersion: String? = nil
    ) throws {
        for (field, value) in [
            ("serviceInstanceID", serviceInstanceID),
            ("endpointScope", endpointScope),
            ("apiDialect", apiDialect),
        ] where !Self.valid(value) {
            throw AgentModelBindingError.invalidIdentity(field)
        }
        if let apiVersion, !Self.valid(apiVersion) {
            throw AgentModelBindingError.invalidIdentity("apiVersion")
        }
        self.serviceInstanceID = serviceInstanceID
        self.endpointScope = endpointScope
        self.apiDialect = apiDialect
        self.apiVersion = apiVersion
    }

    private static func valid(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public struct AgentModelBindingInfo: Hashable, Sendable, Codable {
    public let profileID: String
    public let profileRevision: String
    public let model: ModelID
    public let deployment: AgentModelDeployment
    /// Sanitized Host description. Do not include credentials or opaque provider state.
    public let configurationSummary: [String: JSONValue]

    public init(
        profileID: String,
        profileRevision: String,
        model: ModelID,
        deployment: AgentModelDeployment,
        configurationSummary: [String: JSONValue] = [:]
    ) {
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.model = model
        self.deployment = deployment
        self.configurationSummary = configurationSummary
    }
}

public struct AgentLegacyContinuationPolicy: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Reject continuation payloads written before deployment scope was recorded.
    public static let reject = Self(rawValue: "reject")
    /// Compatibility mode used by the original `Agent(model:provider:)` API.
    public static let allowMatchingModel = Self(rawValue: "allow_matching_model")

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Immutable model/provider/configuration target captured by one Run.
public struct AgentModelBinding: Sendable {
    public let info: AgentModelBindingInfo
    public let provider: any ModelProvider
    public let projector: any AgentContextProjector
    public let tokenBudget: AgentContextTokenBudget?
    public let legacyContinuationPolicy: AgentLegacyContinuationPolicy

    public var profileID: String { info.profileID }
    public var profileRevision: String { info.profileRevision }
    public var model: ModelID { info.model }
    public var deployment: AgentModelDeployment { info.deployment }
    public var configurationSummary: [String: JSONValue] { info.configurationSummary }

    public init(
        profileID: String,
        profileRevision: String,
        model: ModelID,
        provider: any ModelProvider,
        deployment: AgentModelDeployment,
        configurationSummary: [String: JSONValue] = [:],
        projector: any AgentContextProjector = AgentIdentityContextProjector(),
        tokenBudget: AgentContextTokenBudget? = nil,
        legacyContinuationPolicy: AgentLegacyContinuationPolicy = .reject
    ) throws {
        guard Self.valid(profileID) else { throw AgentModelBindingError.invalidIdentity("profileID") }
        guard Self.valid(profileRevision) else { throw AgentModelBindingError.invalidIdentity("profileRevision") }
        guard provider.descriptor.id.utf8.elementsEqual(model.provider.utf8) else {
            throw AgentModelBindingError.providerMismatch
        }
        self.info = .init(
            profileID: profileID,
            profileRevision: profileRevision,
            model: model,
            deployment: deployment,
            configurationSummary: configurationSummary
        )
        self.provider = provider
        self.projector = projector
        self.tokenBudget = tokenBudget
        self.legacyContinuationPolicy = legacyContinuationPolicy
    }

    private init(
        info: AgentModelBindingInfo,
        provider: any ModelProvider,
        projector: any AgentContextProjector,
        tokenBudget: AgentContextTokenBudget?,
        legacyContinuationPolicy: AgentLegacyContinuationPolicy
    ) {
        self.info = info
        self.provider = provider
        self.projector = projector
        self.tokenBudget = tokenBudget
        self.legacyContinuationPolicy = legacyContinuationPolicy
    }

    var continuationOrigin: ModelProviderContinuationOrigin {
        .init(
            providerID: model.provider,
            serviceInstanceID: deployment.serviceInstanceID,
            endpointScope: deployment.endpointScope,
            apiDialect: deployment.apiDialect,
            apiVersion: deployment.apiVersion,
            configurationRevision: profileRevision
        )
    }

    static func legacy(model: ModelID, provider: any ModelProvider) -> Self {
        let providerDialect = valid(provider.descriptor.id) ? provider.descriptor.id : "provider-managed"
        let deployment = AgentModelDeployment(
            uncheckedServiceInstanceID: "agent-default",
            endpointScope: "provider-managed",
            apiDialect: providerDialect,
            apiVersion: nil
        )
        return .init(
            info: .init(
                profileID: "agent-default",
                profileRevision: "legacy-v1",
                model: model,
                deployment: deployment
            ),
            provider: provider,
            projector: AgentIdentityContextProjector(),
            tokenBudget: nil,
            legacyContinuationPolicy: .allowMatchingModel
        )
    }

    private static func valid(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

private extension AgentModelDeployment {
    init(
        uncheckedServiceInstanceID serviceInstanceID: String,
        endpointScope: String,
        apiDialect: String,
        apiVersion: String?
    ) {
        self.serviceInstanceID = serviceInstanceID
        self.endpointScope = endpointScope
        self.apiDialect = apiDialect
        self.apiVersion = apiVersion
    }
}

public enum AgentModelBindingError: Error, Equatable, Sendable {
    case invalidIdentity(String)
    case providerMismatch
    case staleConversationRevision
    case incompatibleContinuation
    case invalidProjection
    case contextWindowUnknown
    case invalidTokenBudget
    case invalidTokenEstimate
    case contextBudgetExceeded(estimatedInputTokens: Int, availableInputTokens: Int)
}

public struct AgentConversationSnapshot: Hashable, Sendable, Codable {
    public let revision: UInt64
    public let messages: [ModelMessage]

    public init(revision: UInt64, messages: [ModelMessage]) {
        self.revision = revision
        self.messages = messages
    }
}
