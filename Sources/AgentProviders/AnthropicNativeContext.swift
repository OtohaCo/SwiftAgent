import AgentModels
import Foundation

enum AnthropicNativeContext {
    static func validateBlock(_ value: JSONValue, mode: ModelCompactionMode) throws -> Bool {
        let block = try ProviderJSON.object(value)
        guard block["type"] == .string("compaction") else { throw ProviderJSON.invalid() }
        guard let content = block["content"] else { throw ProviderJSON.invalid() }
        if content == .null { return false }
        let text = try ProviderJSON.string(content)
        guard !text.isEmpty else { return false }
        if mode == .anthropicOnDemand {
            guard !(try ProviderJSON.string(block["signature"])).isEmpty else { throw ProviderJSON.invalid() }
        } else if let signature = block["signature"], signature != .null {
            guard !(try ProviderJSON.string(signature)).isEmpty else { throw ProviderJSON.invalid() }
        }
        if let encrypted = block["encrypted_content"], encrypted != .null {
            guard !(try ProviderJSON.string(encrypted)).isEmpty else { throw ProviderJSON.invalid() }
        }
        if let changes = block["tool_changes"], changes != .null {
            guard case .array = changes else { throw ProviderJSON.invalid() }
        }
        return true
    }

    static func window(_ checkpoint: ModelNativeContextCheckpoint, model: ModelID) throws -> [JSONValue] {
        let state = checkpoint.continuation, mode = checkpoint.transition.mode
        guard [.anthropicThreshold, .anthropicOnDemand].contains(mode), state.model == model,
              state.format == AnthropicContinuation.format, state.contextTransition == checkpoint.transition,
              case .array(let blocks) = try ProviderJSON.object(try JSONDecoder().decode(JSONValue.self, from: state.payload))["content"],
              let latest = blocks.lastIndex(where: { $0["type"] == .string("compaction") }),
              latest == checkpoint.transition.replayPosition,
              try validateBlock(blocks[latest], mode: mode) else { throw ProviderJSON.invalid() }
        // A compaction point may be inside an assistant response. Preserve every later
        // native block, including thinking, text and client tool proposals.
        let window = Array(blocks.dropFirst(latest))
        _ = try AnthropicContinuation.make(blocks: window, model: model)
        if mode == .anthropicOnDemand, window.count != 1 { throw ProviderJSON.invalid() }
        return window
    }

    static func configure(_ body: JSONValue, request: ModelRequest, mode: ModelCompactionMode?,
                          configuration: AnthropicNativeContextConfiguration?, endpoint: URL,
                          resolvedModelName: String, thinking: AnthropicThinking) throws -> JSONValue {
        var fields = try ProviderJSON.object(body)
        let activeMode = mode ?? configuration?.automatic?.mode ?? request.nativeContext?.transition.mode
        if let activeMode {
            guard let configuration else {
                throw ModelProviderError(kind: .unsupportedCapability, message: "Anthropic native context requires deployment qualification.")
            }
            try configuration.qualification.validate(endpoint: endpoint, model: resolvedModelName, mode: activeMode)
        }
        if let mode {
            guard mode == .anthropicOnDemand, configuration?.automatic == nil,
                  request.structuredOutput == nil else {
                throw ModelProviderError(kind: .unsupportedCapability, message: "On-demand compaction cannot use threshold compaction or structured output.")
            }
            try closedToolHistory(request.messages)
            fields["compaction"] = .object(["type": .string("summarize")])
        } else if let automatic = configuration?.automatic {
            guard request.nativeContext?.transition.mode != .anthropicOnDemand else {
                throw ModelProviderError(kind: .unsupportedCapability, message: "Signed on-demand blocks cannot be combined with context_management.")
            }
            if case .array(let messages) = fields["messages"], messages.contains(where: { message in
                guard case .array(let blocks) = message["content"] else { return false }
                return blocks.contains { block in
                    guard block["type"] == .string("compaction"), let signature = block["signature"], signature != .null else { return false }
                    return true
                }
            }) {
                throw ModelProviderError(kind: .unsupportedCapability, message: "Signed compaction blocks cannot be combined with threshold context_management.")
            }
            fields["context_management"] = .object(["edits": .array([.object([
                "type": .string("compact_20260112"),
                "trigger": .object(["type": .string("input_tokens"), "value": .number(Decimal(automatic.triggerInputTokens))]),
                "pause_after_compaction": .bool(automatic.pauseAfterCompaction),
            ])])])
        }
        if let mismatch = configuration?.thinkingPrefixMismatch {
            guard configuration?.qualification.endpoint == endpoint,
                  configuration?.qualification.resolvedModelNames.contains(resolvedModelName) == true,
                  thinking != .disabled else {
                throw ModelProviderError(kind: .unsupportedCapability, message: "Thinking binding controls require a qualified thinking configuration.")
            }
            // These families only accept block_binding with adaptive thinking. The Host
            // qualifies deployment support; no account age or credentials are inferred.
            if (resolvedModelName.contains("sonnet-5-5") || resolvedModelName.contains("haiku-5-5")), thinking != .adaptive {
                throw ModelProviderError(kind: .unsupportedCapability, message: "This thinking model requires adaptive binding controls.")
            }
            var parameters = try ProviderJSON.object(fields["thinking"])
            parameters["block_binding"] = .object(["prefix_mismatch_behavior": .string(mismatch.rawValue)])
            fields["thinking"] = .object(parameters)
        }
        return .object(fields)
    }

    static func betas(request: ModelRequest, mode: ModelCompactionMode?, configuration: AnthropicNativeContextConfiguration?) -> [String] {
        var values: [String] = []
        if mode == .anthropicOnDemand || request.nativeContext?.transition.mode == .anthropicOnDemand { values.append("compact-2026-09-04") }
        if configuration?.automatic != nil || request.nativeContext?.transition.mode == .anthropicThreshold { values.append("compact-2026-01-12") }
        if configuration?.thinkingPrefixMismatch != nil { values.append("thinking-binding-controls-2026-08-01") }
        return values
    }

    private static func closedToolHistory(_ messages: [ModelMessage]) throws {
        var pending: Set<ToolCallID> = []
        for message in messages {
            switch message {
            case .assistant(_, let calls):
                guard pending.isEmpty else { throw ProviderJSON.invalid() }
                for call in calls { guard call.completeness == .complete, pending.insert(call.id).inserted else { throw ProviderJSON.invalid() } }
            case .tool(let result):
                guard pending.remove(result.callID) != nil else { throw ProviderJSON.invalid() }
            default:
                guard pending.isEmpty else { throw ProviderJSON.invalid() }
            }
        }
        guard pending.isEmpty else {
            throw ModelProviderError(kind: .invalidRequest, message: "On-demand compaction requires a closed client-tool history.")
        }
    }
}
