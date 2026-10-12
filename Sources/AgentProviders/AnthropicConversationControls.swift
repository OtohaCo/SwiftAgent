import AgentModels
import Foundation

extension AnthropicProvider: ModelProviderConversationControls {
    public var conversationControlCapabilities: ModelConversationControlCapabilities? {
        guard let nativeContext, nativeContext.inlineToolChanges || nativeContext.runReminders else { return nil }
        return .init(inlineTools: nativeContext.inlineToolChanges, reminders: nativeContext.runReminders)
    }
}

enum AnthropicConversationControls {
    static func definition(_ tool: ModelToolDefinition) -> JSONValue {
        .object(["name": .string(tool.name), "description": .string(tool.description), "input_schema": tool.inputSchema])
    }
    static func block(_ value: ModelConversationControl, baseline: [ModelToolDefinition]) -> JSONValue {
        switch value {
        case .instruction(let text), .reminder(let text): return .object(["type": .string("text"), "text": .string(text)])
        case .toolAddition(let tool):
            if baseline.contains(tool) { return .object(["type": .string("tool_addition"), "tool": .object(["type": .string("tool_reference"), "name": .string(tool.name)])]) }
            return .object(["type": .string("tool_addition"), "tool": .object([
            "type": .string("tool_definition"), "definition": definition(tool)])])
        case .toolRemoval(let name): return .object(["type": .string("tool_removal"), "tool": .object(["type": .string("tool_reference"), "name": .string(name)])])
        }
    }
    static func validate(_ request: ModelRequest, configuration: AnthropicNativeContextConfiguration?) throws {
        guard let view = request.conversationControls else { return }
        guard let configuration, request.tools == view.toolBaseline,
              Set(view.toolBaseline.map(\.name)).count == view.toolBaseline.count,
              Set(view.coveredTools.map(\.name)).count == view.coveredTools.count,
              Set(view.activeTools.map(\.name)).count == view.activeTools.count,
              view.deferredBaselineToolNames.isSubset(of: Set(view.toolBaseline.map(\.name))),
              view.controls.count <= 10_000, Set(view.controls.map { $0.entry.id }).count == view.controls.count,
              zip(view.controls, view.controls.dropFirst()).allSatisfy({ $0.afterMessageIndex <= $1.afterMessageIndex }) else { throw invalid }
        var active = Dictionary(uniqueKeysWithValues: view.coveredTools.map { ($0.name, $0) })
        try validateAvailableTools(Array(active.values), baseline: view.toolBaseline, deferred: view.deferredBaselineToolNames)
        if request.nativeContext == nil, view.coveredTools != view.toolBaseline.filter { !view.deferredBaselineToolNames.contains($0.name) } { throw invalid }
        var pending = Set<ToolCallID>()
        if let checkpoint = request.nativeContext {
            let blocks = try AnthropicNativeContext.window(checkpoint, model: request.model)
            for block in blocks where block["type"] == .string("tool_use") {
                pending.insert(.init(rawValue: try ProviderJSON.string(block["id"])))
            }
            try validateNativeChanges(blocks[0], view: view, expectedTools: view.coveredTools, changed: view.coveredToolChanges)
        }
        for (index, message) in request.messages.enumerated() {
            switch message {
            case .assistant(_, let calls):
                guard pending.isEmpty else { throw invalid }
                for call in calls { guard pending.insert(call.id).inserted else { throw invalid } }
            case .tool(let result): guard pending.remove(result.callID) != nil else { throw invalid }
            default: guard pending.isEmpty else { throw invalid }
            }
            for control in view.controls where control.afterMessageIndex == index {
                guard pending.isEmpty, message.role == .user || message.role == .tool,
                      control.entry.boundaryDigest == ModelImageDigest.sha256Hex(try ProviderJSON.encode(message)) else { throw invalid }
                guard index == request.messages.count - 1 || request.messages[index + 1].role == .assistant else {
                    throw ModelProviderError(kind: .unsupportedCapability,
                        message: "A trusted system control cannot precede a new user without a real assistant boundary; resume of this failed turn is not supported.")
                }
                switch control.entry.control {
                case .reminder:
                    guard configuration.runReminders, configuration.automatic == nil else { throw unsupported }
                case .instruction: break
                case .toolAddition(let tool):
                    guard configuration.inlineToolChanges else { throw unsupported }
                    active[tool.name] = tool
                case .toolRemoval(let name):
                    guard configuration.inlineToolChanges, active.removeValue(forKey: name) != nil else { throw invalid }
                }
                try validateAvailableTools(Array(active.values), baseline: view.toolBaseline, deferred: view.deferredBaselineToolNames)
            }
        }
        guard view.controls.allSatisfy({ request.messages.indices.contains($0.afterMessageIndex) }),
              active.values.sorted(by: { $0.name < $1.name }) == view.activeTools.sorted(by: { $0.name < $1.name }) else { throw invalid }
    }

    static func validateNativeChanges(_ block: JSONValue, view: ModelConversationControlView,
                                      expectedTools: [ModelToolDefinition], changed: Bool) throws {
        guard let field = block["tool_changes"], field != .null else {
            guard !changed else { throw unsupported }
            let initial = view.toolBaseline.filter { !view.deferredBaselineToolNames.contains($0.name) }
            guard initial.sorted(by: { $0.name < $1.name }) == expectedTools.sorted(by: { $0.name < $1.name }) else { throw invalid }
            return
        }
        guard case .array(let changes) = field, changes.count <= 10_000 else { throw invalid }
        var active = Dictionary(uniqueKeysWithValues: view.toolBaseline.filter { !view.deferredBaselineToolNames.contains($0.name) }.map { ($0.name, $0) })
        let known = view.toolBaseline + view.coveredTools + view.activeTools + view.controls.compactMap {
            if case .toolAddition(let tool) = $0.entry.control { return tool }; return nil
        }
        for change in changes {
            let kind = try ProviderJSON.string(change["type"]), tool = try ProviderJSON.object(change["tool"])
            let toolKind = try ProviderJSON.string(tool["type"])
            switch (kind, toolKind) {
            case ("tool_addition", "tool_definition"):
                guard let native = tool["definition"], let trusted = known.first(where: { definition($0) == native }) else { throw invalid }
                active[trusted.name] = trusted
            case ("tool_addition", "tool_reference"):
                let name = try ProviderJSON.string(tool["name"])
                guard let trusted = view.toolBaseline.first(where: { $0.name == name }) else { throw invalid }
                active[name] = trusted
            case ("tool_removal", "tool_reference"):
                guard active.removeValue(forKey: try ProviderJSON.string(tool["name"])) != nil else { throw invalid }
            default: throw unsupported // No new server/MCP execution or guessed definitions.
            }
            try validateAvailableTools(Array(active.values), baseline: view.toolBaseline, deferred: view.deferredBaselineToolNames)
        }
        guard active.values.sorted(by: { $0.name < $1.name }) == expectedTools.sorted(by: { $0.name < $1.name }) else { throw invalid }
    }
    // The native renderer is private to the service. This local bound measures
    // actual serialized client definitions; it does not predict rendered tokens/text.
    private static func validateAvailableTools(_ active: [ModelToolDefinition], baseline: [ModelToolDefinition], deferred: Set<String>) throws {
        let inline = active.filter { !baseline.contains($0) }
        guard inline.count <= 10_000, active.filter({ deferred.contains($0.name) }).count <= 10_000 else {
            throw ModelProviderError(kind: .invalidRequest, message: "Anthropic available inline/deferred tool count exceeds 10,000.")
        }
        var bytes = 0
        for tool in inline {
            let size = try ProviderJSON.encode(definition(tool)).count
            guard size <= 4_194_304 - bytes else {
                throw ModelProviderError(kind: .invalidRequest, message: "Anthropic active inline tool definitions exceed 4,194,304 bytes.")
            }
            bytes += size
        }
    }
    private static var invalid: ModelProviderError { .init(kind: .invalidRequest, message: "Trusted control state, tool changes or placement is inconsistent.") }
    private static var unsupported: ModelProviderError { .init(kind: .unsupportedCapability, message: "This conversation control or compacted tool state is not supported.") }
}
