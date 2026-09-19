import AgentModels
import Foundation

struct AnthropicStreamDecoder {
    private struct PendingCall {
        let id: ToolCallID
        let name: String
        let initialInput: JSONValue
        let blockIndex: Int
        var arguments: String?
    }
    let model: ModelID
    let responseModelName: String
    private var info: ResponseInfo?
    private var content: [ModelContent] = []
    private var nativeBlocks: [[String: JSONValue]] = []
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var cachedInputTokens: Int?
    private var cacheWriteInputTokens: Int?
    private var reasoningTokens: Int?
    private var usage = ModelUsage()
    private var stopReason: StopReason?
    private var ended = false
    private var activeIndex: Int?
    private var blockCount = 0
    private var calls: [PendingCall] = []
    private var activeCall: Int?
    private var signaturesStarted = Set<Int>()

    private static let knownEventTypes: Set<String> = [
        "ping", "error", "message_start", "content_block_start", "content_block_delta",
        "content_block_stop", "message_delta", "message_stop",
    ]

    init(model: ModelID, responseModelName: String? = nil) {
        self.model = model
        self.responseModelName = responseModelName ?? model.name
    }

    mutating func consume(_ event: ProviderSSEEvent) throws -> [ModelEvent] {
        let object = try ProviderJSON.decode(event.data)
        let type = try ProviderJSON.string(object["type"])
        if let name = event.name, !name.isEmpty, name != "message", !name.utf8.elementsEqual(type.utf8) {
            throw ProviderJSON.invalid()
        }
        if type == "ping" { return [] }
        guard !ended else { throw ProviderJSON.invalid() }
        if type == "error" {
            let error = try ProviderJSON.object(object["error"])
            let kind: ModelProviderError.Kind
            switch try ProviderJSON.string(error["type"]) {
            case "authentication_error": kind = .authentication
            case "permission_error": kind = .permissionDenied
            case "invalid_request_error", "not_found_error": kind = .invalidRequest
            case "rate_limit_error": kind = .rateLimited
            case "overloaded_error", "api_error": kind = .unavailable
            default: kind = .invalidResponse
            }
            throw ModelProviderError(kind: kind, message: "Anthropic generation failed (\(kind.rawValue)).")
        }
        if type == "message_start" {
            guard info == nil else { throw ProviderJSON.invalid() }
            let message = try ProviderJSON.object(object["message"])
            let id = try ProviderJSON.string(message["id"])
            let responseModel = try ProviderJSON.string(message["model"])
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message["type"] == .string("message"), message["role"] == .string("assistant"),
                  message["content"] == .array([]),
                  !responseModel.isEmpty,
                  responseModel.utf8.elementsEqual(responseModelName.utf8) else { throw ProviderJSON.invalid() }
            let value = ResponseInfo(id: id, model: model)
            info = value
            return [.responseStarted(value)] + (try usageEvents(message["usage"]))
        }
        guard let info else {
            if Self.knownEventTypes.contains(type) { throw ProviderJSON.invalid() }
            return []
        }
        switch type {
        case "content_block_start":
            guard stopReason == nil, activeIndex == nil, try ProviderJSON.count(object["index"]) == blockCount else { throw ProviderJSON.invalid() }
            let block = try ProviderJSON.object(object["content_block"])
            activeIndex = blockCount
            nativeBlocks.append(block)
            blockCount += 1
            switch try ProviderJSON.string(block["type"]) {
            case "text": return append(try ProviderJSON.string(block["text"]))
            case "thinking":
                if let signature = block["signature"], !(try ProviderJSON.string(signature)).isEmpty { signaturesStarted.insert(blockCount - 1) }
                return append(try ProviderJSON.string(block["thinking"]), reasoning: true)
            case "redacted_thinking":
                guard !(try ProviderJSON.string(block["data"])).isEmpty else { throw ProviderJSON.invalid() }
                return []
            case "tool_use":
                let call = PendingCall(id: .init(rawValue: try ProviderJSON.string(block["id"])),
                                       name: try ProviderJSON.string(block["name"]),
                                       initialInput: .object(try ProviderJSON.object(block["input"])), blockIndex: blockCount - 1)
                activeCall = calls.count
                calls.append(call)
                return [.toolCallStarted(call.id, name: call.name)]
            default: throw ProviderJSON.invalid()
            }
        case "content_block_delta":
            guard stopReason == nil, let activeIndex, try ProviderJSON.count(object["index"]) == activeIndex else { throw ProviderJSON.invalid() }
            let delta = try ProviderJSON.object(object["delta"])
            if let activeCall {
                guard try ProviderJSON.string(delta["type"]) == "input_json_delta",
                      calls[activeCall].initialInput == .object([:]) else { throw ProviderJSON.invalid() }
                let fragment = try ProviderJSON.string(delta["partial_json"])
                calls[activeCall].arguments = (calls[activeCall].arguments ?? "") + fragment
                return [.toolCallArgumentsDelta(calls[activeCall].id, fragment)]
            }
            if nativeBlocks[activeIndex]["type"] == .string("thinking") {
                switch try ProviderJSON.string(delta["type"]) {
                case "thinking_delta":
                    guard !signaturesStarted.contains(activeIndex) else { throw ProviderJSON.invalid() }
                    let fragment = try ProviderJSON.string(delta["thinking"])
                    nativeBlocks[activeIndex]["thinking"] = .string(try ProviderJSON.string(nativeBlocks[activeIndex]["thinking"]) + fragment)
                    return append(fragment, reasoning: true)
                case "signature_delta":
                    signaturesStarted.insert(activeIndex)
                    let previous = try nativeBlocks[activeIndex]["signature"].map(ProviderJSON.string) ?? ""
                    nativeBlocks[activeIndex]["signature"] = .string(previous + (try ProviderJSON.string(delta["signature"])))
                    return []
                default: throw ProviderJSON.invalid()
                }
            }
            guard try ProviderJSON.string(delta["type"]) == "text_delta" else { throw ProviderJSON.invalid() }
            let fragment = try ProviderJSON.string(delta["text"])
            nativeBlocks[activeIndex]["text"] = .string(try ProviderJSON.string(nativeBlocks[activeIndex]["text"]) + fragment)
            return append(fragment)
        case "content_block_stop":
            guard let activeIndex, try ProviderJSON.count(object["index"]) == activeIndex else { throw ProviderJSON.invalid() }
            self.activeIndex = nil
            activeCall = nil
            return []
        case "message_delta":
            let delta = try ProviderJSON.object(object["delta"])
            if let value = delta["stop_reason"], value != .null {
                let reason = try ProviderJSON.string(value)
                let mapped: StopReason
                switch reason {
                case "end_turn": mapped = .endTurn
                case "tool_use": mapped = .toolCalls
                case "max_tokens": mapped = .maxOutputTokens
                case "stop_sequence": mapped = .stopSequence
                case "refusal": mapped = .refusal
                default: mapped = .unknown(reason)
                }
                guard activeIndex == nil, stopReason == nil || stopReason == mapped else { throw ProviderJSON.invalid() }
                stopReason = mapped
            }
            return try usageEvents(object["usage"])
        case "message_stop":
            guard activeIndex == nil, let stopReason else { throw ProviderJSON.invalid() }
            ended = true
            var events: [ModelEvent] = []
            let completed = stopReason == .toolCalls
            var modelCalls: [ToolCall] = []
            for call in calls {
                let arguments = try call.arguments ?? String(decoding: JSONEncoder().encode(call.initialInput), as: UTF8.self)
                if call.arguments == nil { events.append(.toolCallArgumentsDelta(call.id, arguments)) }
                let value = ToolCall(id: call.id, name: call.name, argumentsJSON: arguments, completeness: completed ? .complete : .incomplete)
                if completed {
                    guard let input = try? JSONValue.decodeToolArguments(arguments) else { throw ProviderJSON.invalid() }
                    nativeBlocks[call.blockIndex]["input"] = input
                    events.append(.toolCallCompleted(value))
                }
                modelCalls.append(value)
            }
            if stopReason == .endTurn || stopReason == .stopSequence || completed {
                let state = try AnthropicContinuation.make(blocks: nativeBlocks.map(JSONValue.object), model: model)
                content.append(.providerContinuation(state))
                events.append(.providerContinuation(state))
            }
            events.append(.responseCompleted(.init(info: info, content: content, toolCalls: modelCalls, usage: usage, stopReason: stopReason)))
            return events
        default:
            return []
        }
    }

    func finish() throws { guard ended else { throw ProviderJSON.invalid() } }

    private mutating func append(_ delta: String, reasoning: Bool = false) -> [ModelEvent] {
        guard !delta.isEmpty else { return [] }
        if reasoning {
            if case .reasoning(let previous) = content.last { content[content.count - 1] = .reasoning(previous + delta) }
            else { content.append(.reasoning(delta)) }
            return [.reasoningDelta(delta)]
        }
        if case .text(let previous) = content.last { content[content.count - 1] = .text(previous + delta) }
        else { content.append(.text(delta)) }
        return [.textDelta(delta)]
    }

    private mutating func usageEvents(_ value: JSONValue?) throws -> [ModelEvent] {
        guard let value, value != .null else { return [] }
        let usage = try ProviderJSON.object(value)
        inputTokens = try ProviderJSON.count(usage["input_tokens"]) ?? inputTokens
        outputTokens = try ProviderJSON.count(usage["output_tokens"]) ?? outputTokens
        cachedInputTokens = try ProviderJSON.count(usage["cache_read_input_tokens"]) ?? cachedInputTokens
        cacheWriteInputTokens = try ProviderJSON.count(usage["cache_creation_input_tokens"]) ?? cacheWriteInputTokens
        if let details = usage["output_tokens_details"], details != .null {
            reasoningTokens = try ProviderJSON.count(ProviderJSON.object(details)["thinking_tokens"]) ?? reasoningTokens
        }
        var total: Int?
        if let inputTokens {
            let (withRead, readOverflow) = inputTokens.addingReportingOverflow(cachedInputTokens ?? 0)
            let (withWrite, writeOverflow) = withRead.addingReportingOverflow(cacheWriteInputTokens ?? 0)
            guard !readOverflow, !writeOverflow else { throw ProviderJSON.invalid() }
            total = withWrite
        }
        self.usage = .init(inputTokens: total, outputTokens: outputTokens, cachedInputTokens: cachedInputTokens,
                           cacheWriteInputTokens: cacheWriteInputTokens, reasoningTokens: reasoningTokens)
        return [.usage(self.usage)]
    }
}
