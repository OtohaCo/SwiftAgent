import AgentModels
import Foundation

/// Trusted harness input. Steering remains user content; these strings must not
/// contain untrusted retrieved/tool text promoted to instruction authority.
public struct AgentRunContextControls: Hashable, Sendable, Codable {
    public let instructions: [String]
    public let reminder: String?
    public init(instructions: [String] = [], reminder: String? = nil) throws {
        guard instructions.count <= 16,
              (instructions + (reminder.map { [$0] } ?? [])).allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 65_536
              }) else { throw ModelProviderError(kind: .invalidRequest, message: "Invalid trusted Run instructions.") }
        self.instructions = instructions; self.reminder = reminder
    }
    private enum CodingKeys: String, CodingKey { case instructions, reminder }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(instructions: c.decodeIfPresent([String].self, forKey: .instructions) ?? [],
                      reminder: c.decodeIfPresent(String.self, forKey: .reminder))
    }
}

package actor AgentConversationControlState {
    private var state: ModelConversationControlState?
    private var restored = false
    func restore(_ value: ModelConversationControlState?, history: [ModelMessage]) throws {
        guard !restored else { return }
        if let value {
            // A restored snapshot is checked once. Later appends use the same
            // publication witness and only validate newly uncovered groups.
            let formal = history.dropFirst(history.prefix { $0.role == .system || $0.role == .developer }.count)
            guard value.lastBoundaryMessageCount <= formal.count else { throw AgentJournalError.invalidRecord }
            var active = Dictionary(uniqueKeysWithValues: value.toolBaseline.filter { !value.deferredBaselineToolNames.contains($0.name) }.map { ($0.name, $0) })
            var checked = 0
            for entry in value.entries {
                let boundary = formal.startIndex + entry.canonicalMessageCount - 1
                guard formal.indices.contains(boundary), formal[boundary].role == .user || formal[boundary].role == .tool,
                      entry.boundaryDigest == ModelImageDigest.sha256Hex(try Self.encode(formal[boundary])) else { throw AgentJournalError.invalidRecord }
                if entry.canonicalMessageCount > checked {
                    try Self.requireClosed(Array(formal.dropFirst(checked).prefix(entry.canonicalMessageCount - checked)))
                    checked = entry.canonicalMessageCount
                }
                switch entry.control {
                case .toolAddition(let tool): active[tool.name] = tool
                case .toolRemoval(let name): guard active.removeValue(forKey: name) != nil else { throw AgentJournalError.invalidRecord }
                default: break
                }
            }
            guard active.values.sorted(by: { $0.name < $1.name }) == value.activeTools else { throw AgentJournalError.invalidRecord }
        }
        restored = true; state = value
    }
    func current() -> ModelConversationControlState? { state }
    func install(_ value: ModelConversationControlState) { state = value; restored = true }

    func prepare(canonical: [ModelMessage], binding: AgentModelBinding, definitions: [ModelToolDefinition],
                 baselineDefinitions: [ModelToolDefinition], baselineDeclaredNames: Set<String>, instructions: AgentRunContextControls?, structuredOutput: StructuredOutputSchema?) throws -> ModelConversationControlState? {
        let capabilities = (binding.provider as? any ModelProviderConversationControls)?.conversationControlCapabilities
        guard capabilities != nil || state != nil || instructions != nil else { return nil }
        guard let capabilities, !binding.isLegacyBinding else { throw unsupported }
        if instructions?.reminder != nil, !capabilities.reminders { throw unsupported }
        let leading = canonical.prefix { $0.role == .system || $0.role == .developer }.count
        let formal = canonical.dropFirst(leading)
        let root = try AgentNativeContextState.rootDigest(canonical, binding: binding, structuredOutput: structuredOutput)
        if let state {
            guard state.origin == binding.continuationOrigin, state.rootConfigurationDigest == root,
                  state.lastBoundaryMessageCount <= formal.count else { throw AgentModelBindingError.incompatibleContinuation }
        } else {
            // Enabling on a previously sent conversation cannot guess its tool baseline.
            guard !formal.contains(where: { $0.role == .assistant || $0.role == .tool }) else { throw unsupported }
        }
        let previous = state
        let desired = definitions.sorted { $0.name < $1.name }
        let active = previous?.activeTools ?? desired
        let lastCount = previous?.lastBoundaryMessageCount ?? 0
        if formal.count == lastCount { return previous }
        let additions = desired.filter { definition in !active.contains(definition) }
        let removals = active.filter { old in !desired.contains(where: { $0.name == old.name }) }.map(\.name)
        if !additions.isEmpty || !removals.isEmpty, !capabilities.inlineTools { throw unsupported }
        guard let last = formal.last, last.role == .user || last.role == .tool else {
            guard additions.isEmpty, removals.isEmpty else { throw unsupported }
            return previous
        }
        try Self.requireClosed(Array(formal.dropFirst(lastCount)))
        let digest = ModelImageDigest.sha256Hex(try Self.encode(last))
        var entries = previous?.entries ?? []
        for name in removals { entries.append(try .init(canonicalMessageCount: formal.count, boundaryDigest: digest, control: .toolRemoval(name))) }
        for tool in additions { entries.append(try .init(canonicalMessageCount: formal.count, boundaryDigest: digest, control: .toolAddition(tool))) }
        // Persistent instructions are supplied once at the first boundary of this Run.
        // The caller passes them only for the first request; reminders recur per new group.
        for text in instructions?.instructions ?? [] { entries.append(try .init(canonicalMessageCount: formal.count, boundaryDigest: digest, control: .instruction(text))) }
        if let text = instructions?.reminder { entries.append(try .init(canonicalMessageCount: formal.count, boundaryDigest: digest, control: .reminder(text))) }
        guard previous?.generation != .max else { throw AgentJournalError.invalidRecord }
        return try .init(generation: (previous?.generation ?? 0) + 1, origin: binding.continuationOrigin,
            rootConfigurationDigest: root, toolBaseline: previous?.toolBaseline ?? baselineDefinitions, activeTools: desired,
            entries: entries, lastBoundaryMessageCount: formal.count, deferredBaselineToolNames: previous?.deferredBaselineToolNames ?? Set(baselineDefinitions.map(\.name)).subtracting(baselineDeclaredNames))
    }

    static func view(_ state: ModelConversationControlState, canonical: [ModelMessage], effective: [ModelMessage],
                     native: ModelNativeContextCheckpoint?) throws -> ModelConversationControlView {
        let leading = canonical.prefix { $0.role == .system || $0.role == .developer }.count
        let covered = native?.canonicalTailStart ?? 0
        let expected = Array(canonical.prefix(leading)) + canonical.dropFirst(leading + covered)
        guard effective == expected else { throw AgentModelBindingError.invalidProjection }
        var coveredTools = Dictionary(uniqueKeysWithValues: state.toolBaseline.filter { !state.deferredBaselineToolNames.contains($0.name) }.map { ($0.name, $0) })
        var coveredChanges = false
        var controls: [ModelRequestConversationControl] = []
        for entry in state.entries {
            if entry.canonicalMessageCount <= covered {
                switch entry.control {
                case .toolAddition(let tool): coveredTools[tool.name] = tool; coveredChanges = true
                case .toolRemoval(let name): coveredTools.removeValue(forKey: name); coveredChanges = true
                case .instruction: throw ModelProviderError(kind: .unsupportedCapability, message: "A native summary cannot preserve trusted instruction authority.")
                default: break
                }
                continue
            }
            let index = leading + entry.canonicalMessageCount - covered - 1
            guard effective.indices.contains(index),
                  entry.boundaryDigest == ModelImageDigest.sha256Hex(try encode(effective[index])) else { throw AgentJournalError.concurrentWriter }
            controls.append(.init(entry: entry, afterMessageIndex: index))
        }
        return .init(toolBaseline: state.toolBaseline, activeTools: state.activeTools, controls: controls,
            coveredTools: coveredTools.values.sorted { $0.name < $1.name }, coveredToolChanges: coveredChanges, deferredBaselineToolNames: state.deferredBaselineToolNames,
            containsPersistentInstructions: state.entries.contains { if case .instruction = $0.control { true } else { false } })
    }

    func hasPersistentInstructions() -> Bool { state?.entries.contains { if case .instruction = $0.control { true } else { false } } == true }

    func hasActiveReminder(in canonical: [ModelMessage]) -> Bool {
        guard let last = state?.entries.last(where: { if case .reminder = $0.control { true } else { false } }) else { return false }
        let leading = canonical.prefix { $0.role == .system || $0.role == .developer }.count
        return !canonical.dropFirst(leading + last.canonicalMessageCount).contains { $0.role == .user || $0.role == .tool }
    }

    func activeReminderBoundary(in canonical: [ModelMessage]) -> Int? {
        guard hasActiveReminder(in: canonical) else { return nil }
        return state?.entries.last(where: { if case .reminder = $0.control { true } else { false } })?.canonicalMessageCount
    }

    static func requireClosed(_ messages: [ModelMessage]) throws {
        var pending: Set<ToolCallID> = []
        for message in messages {
            switch message {
            case .assistant(_, let calls):
                guard pending.isEmpty else { throw AgentJournalError.invalidRecord }
                for call in calls { guard pending.insert(call.id).inserted else { throw AgentJournalError.invalidRecord } }
            case .tool(let result): guard pending.remove(result.callID) != nil else { throw AgentJournalError.invalidRecord }
            default: guard pending.isEmpty else { throw AgentJournalError.invalidRecord }
            }
        }
        guard pending.isEmpty else { throw AgentJournalError.invalidRecord }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private var unsupported: ModelProviderError { .init(kind: .unsupportedCapability, message: "Trusted conversation controls are not qualified for this binding or boundary.") }
}
