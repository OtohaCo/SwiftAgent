import Foundation

/// Trusted harness controls, separate from user input and executable authority.
public enum ModelConversationControl: Hashable, Sendable, Codable {
    case instruction(String)
    case reminder(String)
    case toolAddition(ModelToolDefinition)
    case toolRemoval(String)
}

/// Append-only control at a complete canonical user/client-tool-result boundary.
public struct ModelConversationControlEntry: Hashable, Sendable, Codable {
    public let id: UUID
    public let canonicalMessageCount: Int
    public let boundaryDigest: String
    public let control: ModelConversationControl
    public init(id: UUID = UUID(), canonicalMessageCount: Int, boundaryDigest: String, control: ModelConversationControl) throws {
        guard canonicalMessageCount > 0, !boundaryDigest.isEmpty else { throw Self.invalid }
        switch control {
        case .instruction(let text), .reminder(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 65_536 else { throw Self.invalid }
        case .toolAddition(let tool):
            guard !tool.name.isEmpty, case .object = tool.inputSchema else { throw Self.invalid }
        case .toolRemoval(let name): guard !name.isEmpty else { throw Self.invalid }
        }
        self.id = id; self.canonicalMessageCount = canonicalMessageCount
        self.boundaryDigest = boundaryDigest; self.control = control
    }
    private static var invalid: ModelProviderError { .init(kind: .invalidRequest, message: "Invalid trusted control boundary or payload.") }
    private enum CodingKeys: String, CodingKey { case id, canonicalMessageCount, boundaryDigest, control }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), canonicalMessageCount: c.decode(Int.self, forKey: .canonicalMessageCount),
            boundaryDigest: c.decode(String.self, forKey: .boundaryDigest), control: c.decode(ModelConversationControl.self, forKey: .control))
    }
}

/// Persistent wire state. Its definitions never grant tool execution permission.
public struct ModelConversationControlState: Hashable, Sendable, Codable {
    public let generation: UInt64
    public let origin: ModelProviderContinuationOrigin
    public let rootConfigurationDigest: String
    public let toolBaseline: [ModelToolDefinition]
    public let deferredBaselineToolNames: Set<String>
    public let activeTools: [ModelToolDefinition]
    public let entries: [ModelConversationControlEntry]
    public let lastBoundaryMessageCount: Int
    public init(generation: UInt64, origin: ModelProviderContinuationOrigin, rootConfigurationDigest: String,
                toolBaseline: [ModelToolDefinition], activeTools: [ModelToolDefinition], entries: [ModelConversationControlEntry], lastBoundaryMessageCount: Int, deferredBaselineToolNames: Set<String> = []) throws {
        guard deferredBaselineToolNames.isSubset(of: Set(toolBaseline.map(\.name))), generation > 0, lastBoundaryMessageCount > 0, entries.allSatisfy({ $0.canonicalMessageCount <= lastBoundaryMessageCount }), !rootConfigurationDigest.isEmpty, entries.count <= 10_000,
              Set(entries.map(\.id)).count == entries.count,
              Set(toolBaseline.map(\.name)).count == toolBaseline.count,
              Set(activeTools.map(\.name)).count == activeTools.count,
              zip(entries, entries.dropFirst()).allSatisfy({ $0.canonicalMessageCount <= $1.canonicalMessageCount }) else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid trusted control snapshot.")
        }
        self.generation = generation; self.origin = origin; self.rootConfigurationDigest = rootConfigurationDigest
        self.toolBaseline = toolBaseline; self.deferredBaselineToolNames = deferredBaselineToolNames; self.activeTools = activeTools; self.entries = entries; self.lastBoundaryMessageCount = lastBoundaryMessageCount
    }
    private enum CodingKeys: String, CodingKey { case generation, origin, rootConfigurationDigest, toolBaseline, activeTools, entries, lastBoundaryMessageCount, deferredBaselineToolNames }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(generation: c.decode(UInt64.self, forKey: .generation), origin: c.decode(ModelProviderContinuationOrigin.self, forKey: .origin),
            rootConfigurationDigest: c.decode(String.self, forKey: .rootConfigurationDigest), toolBaseline: c.decode([ModelToolDefinition].self, forKey: .toolBaseline),
            activeTools: c.decode([ModelToolDefinition].self, forKey: .activeTools), entries: c.decode([ModelConversationControlEntry].self, forKey: .entries), lastBoundaryMessageCount: c.decode(Int.self, forKey: .lastBoundaryMessageCount), deferredBaselineToolNames: c.decodeIfPresent(Set<String>.self, forKey: .deferredBaselineToolNames) ?? [])
    }
}

/// Exact request positions prepared and checked by Core, never canonical indices.
public struct ModelRequestConversationControl: Hashable, Sendable, Codable {
    public let entry: ModelConversationControlEntry
    public let afterMessageIndex: Int
    public init(entry: ModelConversationControlEntry, afterMessageIndex: Int) {
        self.entry = entry; self.afterMessageIndex = afterMessageIndex
    }
}

public struct ModelConversationControlView: Hashable, Sendable, Codable {
    public let toolBaseline: [ModelToolDefinition]
    public let deferredBaselineToolNames: Set<String>
    public let activeTools: [ModelToolDefinition]
    public let controls: [ModelRequestConversationControl]
    /// Trusted state at the covered boundary for validation of native tool_changes.
    public let coveredTools: [ModelToolDefinition]
    public let coveredToolChanges: Bool
    public let containsPersistentInstructions: Bool
    public init(toolBaseline: [ModelToolDefinition], activeTools: [ModelToolDefinition], controls: [ModelRequestConversationControl],
                coveredTools: [ModelToolDefinition], coveredToolChanges: Bool, deferredBaselineToolNames: Set<String> = [], containsPersistentInstructions: Bool = false) {
        self.toolBaseline = toolBaseline; self.deferredBaselineToolNames = deferredBaselineToolNames; self.activeTools = activeTools; self.controls = controls
        self.coveredTools = coveredTools; self.coveredToolChanges = coveredToolChanges
        self.containsPersistentInstructions = containsPersistentInstructions
    }
}

public struct ModelConversationControlCapabilities: Hashable, Sendable, Codable {
    public let inlineTools: Bool
    public let reminders: Bool
    public init(inlineTools: Bool, reminders: Bool) { self.inlineTools = inlineTools; self.reminders = reminders }
}

/// Optional adapter capability; old Provider conformers acquire no new requirements.
public protocol ModelProviderConversationControls: ModelProvider {
    var conversationControlCapabilities: ModelConversationControlCapabilities? { get }
}
