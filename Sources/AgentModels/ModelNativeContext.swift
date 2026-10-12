import Foundation

/// Shared classification used before deadline settlement and by runtime continuation.
/// Vendor maintenance reasons never masquerade as final user answers.
public enum ModelResponseClassification: Hashable, Sendable, Codable {
    case finalResponse, toolWork, maintenance, cancelled, unrecognized
}

extension StopReason {
    public var responseClassification: ModelResponseClassification {
        switch self {
        case .endTurn, .stopSequence, .maxOutputTokens, .refusal: .finalResponse
        case .toolCalls: .toolWork
        case .cancelled: .cancelled
        case .unknown(let reason): ["compaction", "pause_turn"].contains(reason) ? .maintenance : .unrecognized
        }
    }
}

extension ModelResponse {
    public var classification: ModelResponseClassification { stopReason.responseClassification }
}

/// Host-selected service trigger. A trigger is not a pre-dispatch hard context limit.
public struct ModelAutomaticCompaction: Hashable, Sendable, Codable {
    public let mode: ModelCompactionMode
    public let triggerInputTokens: Int
    public let pauseAfterCompaction: Bool
    public let maximumMaintenanceRounds: Int
    public init(mode: ModelCompactionMode, triggerInputTokens: Int,
                pauseAfterCompaction: Bool = false, maximumMaintenanceRounds: Int = 4) throws {
        let minimum: Int
        switch mode {
        case .anthropicThreshold: minimum = 50_000
        case .openAIAutomatic: minimum = 1_000
        default: throw ModelProviderError(kind: .unsupportedCapability, message: "This mode is not an implemented automatic compaction policy.")
        }
        guard triggerInputTokens >= minimum, maximumMaintenanceRounds > 0,
              mode == .anthropicThreshold || !pauseAfterCompaction else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid automatic compaction trigger or maintenance policy.")
        }
        self.mode = mode; self.triggerInputTokens = triggerInputTokens
        self.pauseAfterCompaction = pauseAfterCompaction; self.maximumMaintenanceRounds = maximumMaintenanceRounds
    }
    private enum CodingKeys: String, CodingKey { case mode, triggerInputTokens, pauseAfterCompaction, maximumMaintenanceRounds }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(mode: c.decode(ModelCompactionMode.self, forKey: .mode), triggerInputTokens: c.decode(Int.self, forKey: .triggerInputTokens),
                      pauseAfterCompaction: c.decode(Bool.self, forKey: .pauseAfterCompaction), maximumMaintenanceRounds: c.decode(Int.self, forKey: .maximumMaintenanceRounds))
    }
}

/// The immutable source Core actually validated for an HTTP request. Digest is
/// correspondence evidence, not a claim about summary quality or vendor signatures.
public struct ModelNativeContextSource: Hashable, Sendable, Codable {
    public let sessionID: UUID
    public let canonicalMessageCount: Int
    public let lastMessageID: UUID?
    public let canonicalDigest: String
    public let requestDigest: String
    public let projectionID: String
    public let projectionVersion: String
    public let previousCheckpointID: UUID?
    public init(sessionID: UUID, canonicalMessageCount: Int, lastMessageID: UUID?, canonicalDigest: String,
                requestDigest: String, projectionID: String, projectionVersion: String, previousCheckpointID: UUID?) {
        self.sessionID = sessionID; self.canonicalMessageCount = canonicalMessageCount
        self.lastMessageID = lastMessageID; self.canonicalDigest = canonicalDigest; self.requestDigest = requestDigest
        self.projectionID = projectionID; self.projectionVersion = projectionVersion; self.previousCheckpointID = previousCheckpointID
    }
}

/// A complete provider candidate bound to the exact request source. Core only
/// publishes it when the associated native output remains accepted in full.
public struct ModelNativeContextTransition: Hashable, Sendable, Codable {
    public let mode: ModelCompactionMode
    public let source: ModelNativeContextSource
    /// Index of the latest complete native item/block; standalone windows replay all items.
    public let replayPosition: Int
    public let invocationID: UUID
    public let responseID: String
    public let itemID: String?
    public init(mode: ModelCompactionMode, source: ModelNativeContextSource, replayPosition: Int,
                invocationID: UUID, responseID: String, itemID: String? = nil) {
        self.mode = mode; self.source = source; self.replayPosition = replayPosition
        self.invocationID = invocationID; self.responseID = responseID; self.itemID = itemID
    }
}

/// Core-published effective context, independent of canonical execution history.
public struct ModelNativeContextCheckpoint: Hashable, Sendable, Codable {
    public let id: UUID
    public let generation: UInt64
    public let continuation: ModelProviderContinuation
    public let transition: ModelNativeContextTransition
    public let rootConfigurationDigest: String
    public let toolBaseline: [ModelToolDefinition]
    public let usage: ModelUsage
    public init(id: UUID, generation: UInt64, continuation: ModelProviderContinuation,
                transition: ModelNativeContextTransition, rootConfigurationDigest: String,
                toolBaseline: [ModelToolDefinition], usage: ModelUsage) {
        self.id = id; self.generation = generation; self.continuation = continuation
        self.transition = transition; self.rootConfigurationDigest = rootConfigurationDigest
        self.toolBaseline = toolBaseline; self.usage = usage
    }
}

/// Optional adapter capability. Existing ModelProvider conformers remain source compatible.
/// Only explicitly qualified deployment modes may be advertised as usable.
public protocol ModelProviderCompaction: ModelProvider {
    var compactionModes: Set<ModelCompactionMode> { get }
    func validateCompaction(request: ModelCompactionRequest) throws
    func compact(request: ModelCompactionRequest) -> AsyncThrowingStream<ModelCompactionEvent, Error>
    func waitForCompactionToDrain(sessionID: UUID, operationID: UUID) async
}

extension ModelProviderCompaction {
    public func waitForCompactionToDrain(sessionID: UUID, operationID: UUID) async {}
}

public struct ModelCompactionRequest: Hashable, Sendable, Codable {
    public let request: ModelRequest
    public let mode: ModelCompactionMode
    public let operationID: UUID
    public let invocationID: UUID
    public init(request: ModelRequest, mode: ModelCompactionMode, operationID: UUID, invocationID: UUID) {
        self.request = request; self.mode = mode; self.operationID = operationID; self.invocationID = invocationID
    }
}

/// Standalone native summary is context state, never an assistant final answer.
public struct ModelCompactionResponse: Hashable, Sendable, Codable {
    public let info: ResponseInfo
    public let continuation: ModelProviderContinuation?
    public let usage: ModelUsage
    public init(info: ResponseInfo, continuation: ModelProviderContinuation?, usage: ModelUsage) {
        self.info = info; self.continuation = continuation; self.usage = usage
    }
}

public enum ModelCompactionEvent: Hashable, Sendable, Codable {
    case usage(ModelUsage)
    case completed(ModelCompactionResponse)
}
