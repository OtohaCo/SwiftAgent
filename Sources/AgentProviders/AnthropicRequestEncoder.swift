import AgentModels
import Foundation

enum AnthropicRequestEncoder {
    private struct Message {
        let role: String
        var content: [JSONValue]
        var identities: [ModelInputSourceIdentity]
        var clearAt: String? = nil
        var json: JSONValue {
            var fields: [String: JSONValue] = ["role": .string(role), "content": .array(content)]
            if let clearAt { fields["clear_at"] = .string(clearAt) }
            return .object(fields)
        }
    }
    static func encode(
        _ request: ModelRequest,
        maximumOutputTokens: Int,
        thinking: AnthropicThinking,
        effort: AnthropicEffort? = nil,
        promptCaching: AnthropicPromptCaching? = nil,
        resolvedModelName: String? = nil,
        nativeContext: AnthropicNativeContextConfiguration? = nil
    ) throws -> JSONValue {
        try encodeWithMapping(request, maximumOutputTokens: maximumOutputTokens, thinking: thinking, effort: effort,
            promptCaching: promptCaching, resolvedModelName: resolvedModelName, nativeContext: nativeContext).body
    }

    static func encodeWithMapping(_ request: ModelRequest, maximumOutputTokens: Int, thinking: AnthropicThinking,
        effort: AnthropicEffort? = nil, promptCaching: AnthropicPromptCaching? = nil, resolvedModelName: String? = nil,
        nativeContext: AnthropicNativeContextConfiguration? = nil,
        preparingPreservedReplacement: Bool = false, forceThinkingPrefixValidation: Bool = false, replacementSink: (([ModelThinkingPrefixReplacement]) -> Void)? = nil) throws -> (body: JSONValue, sources: [String: ModelInputSourceIdentity]) {
        guard request.model.provider == "anthropic", !request.model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid Anthropic model identifier.")
        }
        try AnthropicConversationControls.validate(request, configuration: nativeContext)
        try promptCaching?.validate(modelName: resolvedModelName ?? request.model.name)
        var system: [String] = []
        var messages: [Message] = []
        var insertedNative = false
        let nativeBlocks = try request.nativeContext.map { try AnthropicNativeContext.window($0, model: request.model) } ?? []
        var thinkingPrefixes: [(content: [ModelContent], blocks: [JSONValue], messages: [JSONValue])] = []
        for (messageIndex, message) in request.messages.enumerated() {
            let messageDigest = ModelImageDigest.sha256Hex(try ProviderJSON.encode(message))
            if message.role != .system && message.role != .developer, !insertedNative {
                if !nativeBlocks.isEmpty { try append(role: "assistant", content: nativeBlocks, to: &messages, messageDigest: request.nativeContext.map { ModelImageDigest.sha256Hex($0.continuation.payload) } ?? "", nativeCheckpointID: request.nativeContext?.id) }
                insertedNative = true
            }
            switch message {
            case .system(let text), .developer(let text):
                guard messages.isEmpty else {
                    throw ModelProviderError(kind: .unsupportedCapability, message: "This adapter requires instructions before conversation messages.")
                }
                system.append(text)
            case .user(let content):
                try append(role: "user", content: marked(try textBlocks(content), at: messageIndex, configuration: promptCaching), to: &messages, messageDigest: messageDigest)
            case .assistant(let content, let calls):
                guard !content.contains(where: { if case .providerContinuation(let state) = $0 { state.contextTransition != nil } else { false } }) else {
                    throw ModelProviderError(kind: .unsupportedCapability, message: "Native transition replay requires its published context checkpoint.")
                }
                guard !content.contains(where: \.isImage) else { throw ImageEncoding.assistantImage() }
                if let restored = try AnthropicContinuation.restore(content: content, calls: calls, model: request.model) {
                    guard !restored.contains(where: { $0["type"] == .string("compaction") }) else {
                        throw ModelProviderError(kind: .unsupportedCapability, message: "Compaction replay requires its published native context checkpoint.")
                    }
                    thinkingPrefixes.append((content, restored, messages.map(\.json)))
                    try append(role: "assistant", content: marked(restored, at: messageIndex, configuration: promptCaching), to: &messages, messageDigest: messageDigest)
                    continue
                }
                var blocks = try textBlocks(content)
                for call in calls {
                    guard call.completeness == .complete,
                          let arguments = try? JSONValue.decodeToolArguments(call.argumentsJSON) else {
                        throw ModelProviderError(kind: .invalidRequest, message: "Invalid tool history.")
                    }
                    blocks.append(.object(["type": .string("tool_use"), "id": .string(call.id.rawValue),
                                            "name": .string(call.name), "input": arguments]))
                }
                try append(role: "assistant", content: marked(blocks, at: messageIndex, configuration: promptCaching), to: &messages, messageDigest: messageDigest)
            case .tool(let result):
                let text = try result.content.compactMap { part -> String? in
                    switch part {
                    case .text(let value): return value
                    case .json(let value): return try ProviderJSON.text(value)
                    case .reasoning, .providerContinuation, .image: return nil
                    }
                }.joined(separator: "\n")
                let pictures = result.content.filter(\.isImage)
                let value: JSONValue = pictures.isEmpty ? .string(text) : .array(
                    (text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])])
                        + (try textBlocks(pictures)))
                try append(role: "user", content: marked([.object([
                    "type": .string("tool_result"), "tool_use_id": .string(result.callID.rawValue),
                    "content": value, "is_error": .bool(result.isError),
                ])], at: messageIndex, configuration: promptCaching), to: &messages, messageDigest: messageDigest)
            }
            for control in request.conversationControls?.controls.filter({ $0.afterMessageIndex == messageIndex }) ?? [] {
                let clearAt: String? = if case .reminder = control.entry.control { "next_user_message" } else { nil }
                try append(role: "system", content: [AnthropicConversationControls.block(control.entry.control, baseline: request.tools)], to: &messages,
                    messageDigest: ModelImageDigest.sha256Hex(try ProviderJSON.encode(control.entry)), clearAt: clearAt)
            }
        }
        if !insertedNative, !nativeBlocks.isEmpty { try append(role: "assistant", content: nativeBlocks, to: &messages, messageDigest: request.nativeContext.map { ModelImageDigest.sha256Hex($0.continuation.payload) } ?? "", nativeCheckpointID: request.nativeContext?.id) }
        guard !messages.isEmpty else { throw ModelProviderError(kind: .invalidRequest, message: "Conversation messages are required.") }
        var body: [String: JSONValue] = ["model": .string(request.model.name), "max_tokens": .number(Decimal(maximumOutputTokens)),
                                        "stream": .bool(true), "messages": .array(messages.map(\.json))]
        if !system.isEmpty {
            if let promptCaching, promptCaching.breakpoints.contains(where: { if case .system = $0.target { true } else { false } }) {
                var blocks = system.enumerated().map { index, text in
                    JSONValue.object(["type": .string("text"), "text": .string((index == 0 ? "" : "\n") + text)])
                }
                for breakpoint in promptCaching.breakpoints {
                    guard case .system(let index) = breakpoint.target else { continue }
                    guard blocks.indices.contains(index), !system[index].isEmpty, case .object(var block) = blocks[index] else {
                        throw PromptCacheQualification.invalid("The Anthropic system cache breakpoint is absent or empty.")
                    }
                    block["cache_control"] = promptCaching.control(breakpoint.ttl)
                    blocks[index] = .object(block)
                }
                body["system"] = .array(blocks)
            } else { body["system"] = .string(system.joined(separator: "\n")) }
        }
        switch thinking {
        case .disabled: body["thinking"] = .object(["type": .string("disabled")])
        case .adaptive: body["thinking"] = .object(["type": .string("adaptive")])
        case .enabled(let budget): body["thinking"] = .object(["type": .string("enabled"), "budget_tokens": .number(Decimal(budget))])
        }
        var outputConfiguration: [String: JSONValue] = [:]
        if let effort { outputConfiguration["effort"] = .string(effort.rawValue) }
        if let schema = request.structuredOutput {
            outputConfiguration["format"] = .object(["type": .string("json_schema"), "schema": schema.schema])
        }
        if !outputConfiguration.isEmpty { body["output_config"] = .object(outputConfiguration) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                var fields: [String: JSONValue] = ["name": .string(tool.name), "description": .string(tool.description), "input_schema": tool.inputSchema]
                if request.conversationControls?.deferredBaselineToolNames.contains(tool.name) == true { fields["defer_loading"] = .bool(true) }
                return .object(fields)
            })
        }
        if let promptCaching {
            for breakpoint in promptCaching.breakpoints {
                switch breakpoint.target {
                case .lastTool:
                    guard case .array(var tools) = body["tools"], case .object(var last) = tools.last else {
                        throw PromptCacheQualification.invalid("The Anthropic tool cache breakpoint is absent.")
                    }
                    last["cache_control"] = promptCaching.control(breakpoint.ttl)
                    tools[tools.count - 1] = .object(last)
                    body["tools"] = .array(tools)
                case .system(let index):
                    guard system.indices.contains(index) else { throw PromptCacheQualification.invalid("The Anthropic instruction cache breakpoint is absent.") }
                case .message(let index, _):
                    guard request.messages.indices.contains(index) else { throw PromptCacheQualification.invalid("The Anthropic message cache breakpoint is absent.") }
                    switch request.messages[index] {
                    case .system, .developer: throw PromptCacheQualification.invalid("Use a system cache target for leading instructions.")
                    default: break
                    }
                }
            }
            if let ttl = promptCaching.automaticTTL { body["cache_control"] = promptCaching.control(ttl) }
            try promptCaching.validateTTLOrder(in: body)
        }
        if thinkingPrefixes.contains(where: { AnthropicContinuation.containsThinking($0.blocks) }), (nativeContext?.thinkingPrefixMismatch == nil || forceThinkingPrefixValidation),
           let controls = request.conversationControls,
           controls.toolBaseline.allSatisfy({ controls.deferredBaselineToolNames.contains($0.name) }),
           controls.controls.contains(where: {
               if case .toolAddition(let tool) = $0.entry.control { return !controls.toolBaseline.contains(tool) }
               return false
           }) {
            throw ModelProviderError(kind: .unsupportedCapability,
                message: "A by-value inline tool without a non-deferred baseline anchor changes the signed thinking prefix.")
        }
        var replacements: [ModelThinkingPrefixReplacement] = []
        for prior in thinkingPrefixes where nativeContext?.thinkingPrefixMismatch == nil || preparingPreservedReplacement || forceThinkingPrefixValidation {
            let prefix = AnthropicContinuation.prefix(system: body["system"], tools: body["tools"], messages: prior.messages)
            if preparingPreservedReplacement {
                if let replacement = try AnthropicContinuation.prefixReplacement(content: prior.content, blocks: prior.blocks, prefix: prefix) { replacements.append(replacement) }
            } else {
                try AnthropicContinuation.validatePrefix(content: prior.content, blocks: prior.blocks, prefix: prefix,
                    replacements: request.nativeContext?.preservedThinkingLineage?.replacements ?? [])
            }
        }
        replacementSink?(replacements)
        var sources: [String: ModelInputSourceIdentity] = [:]
        for (index, message) in messages.enumerated() {
            for (block, identity) in message.identities.enumerated() { sources["messages.\(index).content.\(block)"] = identity }
        }
        return (.object(body), sources)
    }

    private static func marked(_ blocks: [JSONValue], at index: Int, configuration: AnthropicPromptCaching?) throws -> [JSONValue] {
        try configuration?.mark(blocks, atMessage: index) ?? blocks
    }

    private static func append(role: String, content: [JSONValue], to messages: inout [Message],
                               messageDigest: String, nativeCheckpointID: UUID? = nil, clearAt: String? = nil) throws {
        if role == "assistant", content.isEmpty { return }
        guard !content.isEmpty else { throw ModelProviderError(kind: .invalidRequest, message: "Message content is required.") }
        let identities = try content.map { value in
            var fields = try ProviderJSON.object(value)
            fields.removeValue(forKey: "cache_control")
            return ModelInputSourceIdentity(messageDigest: messageDigest,
                contentDigest: ModelImageDigest.sha256Hex(try ProviderJSON.encode(JSONValue.object(fields))), nativeCheckpointID: nativeCheckpointID)
        }
        if role != "system", messages.last?.role == role {
            messages[messages.count - 1].content.append(contentsOf: content)
            messages[messages.count - 1].identities.append(contentsOf: identities)
        } else { messages.append(.init(role: role, content: content, identities: identities, clearAt: clearAt)) }
    }

    /// Text blocks, and images as base64 image blocks in their place.
    private static func textBlocks(_ content: [ModelContent]) throws -> [JSONValue] {
        try content.compactMap { part in
            let text: String
            switch part {
            case .text(let value): text = value
            case .json(let value): text = try ProviderJSON.text(value)
            case .reasoning, .providerContinuation: return nil
            case .image(let image):
                return .object(["type": .string("image"), "source": .object([
                    "type": .string("base64"), "media_type": .string(image.mediaType.rawValue),
                    "data": .string(image.data.base64EncodedString()),
                ])])
            }
            return .object(["type": .string("text"), "text": .string(text)])
        }
    }
}
