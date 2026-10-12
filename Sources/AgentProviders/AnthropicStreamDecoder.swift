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
    let requestPrefix: JSONValue?
    let nativeRequest: ModelRequest?
    let compactionMode: ModelCompactionMode?
    let nativeIterationUsage: Bool
    private var compactionDeltas: Set<Int> = []
    private var info: ResponseInfo?
    private var content: [ModelContent] = []
    private var nativeBlocks: [[String: JSONValue]] = []
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var cachedInputTokens: Int?
    private var cacheWriteInputTokens: Int?
    private var reasoningTokens: Int?
    private var cacheWriteTTL: CacheWriteTTLUsage?
    private var iterations: [ModelUsageIteration]?
    private var publishedParentUsage = false
    private var usage = ModelUsage()
    private var stopReason: StopReason?
    private var inputTransformations: [ModelInputTransformation]?
    let inputSources: [String: ModelInputSourceIdentity]
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

    init(model: ModelID, responseModelName: String? = nil, requestPrefix: JSONValue? = nil,
         nativeRequest: ModelRequest? = nil, compactionMode: ModelCompactionMode? = nil, inputSources: [String: ModelInputSourceIdentity] = [:], nativeIterationUsage: Bool = false) {
        self.model = model
        self.requestPrefix = requestPrefix
        self.nativeRequest = nativeRequest
        self.compactionMode = compactionMode
        self.inputSources = inputSources
        self.nativeIterationUsage = nativeIterationUsage || compactionMode != nil
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
            case _ where ProviderContextOverflow.isAnthropicOverflow(error): kind = .contextWindowExceeded
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
            return [.responseStarted(value)] + (try transformationEvents(message["input_transformations"])) + (try usageEvents(message["usage"]))
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
            case "compaction":
                guard nativeRequest?.nativeContextSource != nil, let compactionMode else { throw ProviderJSON.invalid() }
                if compactionMode == .anthropicOnDemand { _ = try AnthropicNativeContext.validateBlock(.object(block), mode: compactionMode) }
                else { guard block["content"] == .null else { throw ProviderJSON.invalid() } }
                return []
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
            if nativeBlocks[activeIndex]["type"] == .string("compaction") {
                guard compactionMode == .anthropicThreshold, delta["type"] == .string("compaction_delta"),
                      compactionDeltas.insert(activeIndex).inserted, delta["content"] != nil else { throw ProviderJSON.invalid() }
                // The one delta replaces the complete summary; it is never concatenated.
                for (key, value) in delta where key != "type" { nativeBlocks[activeIndex][key] = value }
                _ = try AnthropicNativeContext.validateBlock(.object(nativeBlocks[activeIndex]), mode: .anthropicThreshold)
                return []
            }
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
            if nativeBlocks[activeIndex]["type"] == .string("compaction") {
                guard let compactionMode, compactionMode != .anthropicThreshold || compactionDeltas.contains(activeIndex) else { throw ProviderJSON.invalid() }
                _ = try AnthropicNativeContext.validateBlock(.object(nativeBlocks[activeIndex]), mode: compactionMode)
            }
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
            return try transformationEvents(object["input_transformations"]) + usageEvents(object["usage"])
        case "message_stop":
            guard activeIndex == nil, var stopReason else { throw ProviderJSON.invalid() }
            let validBlocks = try nativeBlocks.filter { block in
                if block["type"] != .string("compaction") { return true }
                guard let compactionMode else { throw ProviderJSON.invalid() }
                return try AnthropicNativeContext.validateBlock(.object(block), mode: compactionMode)
            }
            let latestCompaction = validBlocks.lastIndex(where: { $0["type"] == .string("compaction") })
            if let latestCompaction {
                guard !validBlocks.prefix(latestCompaction).contains(where: { $0["type"] == .string("tool_use") }) else { throw ProviderJSON.invalid() }
                if stopReason == .endTurn, !validBlocks.dropFirst(latestCompaction + 1).contains(where: { $0["type"] == .string("text") || $0["type"] == .string("tool_use") }) {
                    stopReason = .unknown("compaction")
                }
            }
            if compactionMode == .anthropicOnDemand {
                guard nativeBlocks.count <= 1, calls.isEmpty, content.isEmpty,
                      latestCompaction == nil || stopReason == .unknown("compaction") else { throw ProviderJSON.invalid() }
                // A billed no-summary stage may stop with tool_use without proposing a
                // tool. Preserve that raw reason without treating it as generation work.
                if latestCompaction == nil, stopReason == .toolCalls { stopReason = .unknown("tool_use") }
            }
            ended = true
            var events: [ModelEvent] = try iterationUsageEvents(complete: true)
            let completed = stopReason == .toolCalls
            var modelCalls: [ToolCall] = []
            for call in calls {
                let arguments = try call.arguments ?? ProviderJSON.text(call.initialInput)
                if call.arguments == nil { events.append(.toolCallArgumentsDelta(call.id, arguments)) }
                let value = ToolCall(id: call.id, name: call.name, argumentsJSON: arguments, completeness: completed ? .complete : .incomplete)
                if completed {
                    // Input that is not one JSON object is the model's mistake; the runtime reports it to the
                    // model and replays the call with `{}`. The native block keeps its initial `{}` input
                    // (deltas require it), so the continuation still matches that replay.
                    if let input = try? JSONValue.decodeToolArguments(arguments) { nativeBlocks[call.blockIndex]["input"] = input }
                    events.append(.toolCallCompleted(value))
                }
                modelCalls.append(value)
            }
            if latestCompaction != nil || stopReason == .endTurn || stopReason == .stopSequence || completed {
                let replayBlocks = try nativeBlocks.filter { block in
                    if block["type"] != .string("compaction") { return true }
                    return try AnthropicNativeContext.validateBlock(.object(block), mode: compactionMode!)
                }.map(JSONValue.object)
                if !replayBlocks.isEmpty {
                    let ordinary = try AnthropicContinuation.make(blocks: replayBlocks, model: model, requestPrefix: requestPrefix)
                    let state: ModelProviderContinuation
                    if let latestCompaction {
                        guard let request = nativeRequest, let source = request.nativeContextSource, let invocation = request.invocationID,
                              let compactionMode else { throw ProviderJSON.invalid() }
                        if let view = request.conversationControls {
                            let changed = view.coveredToolChanges || view.controls.contains {
                                switch $0.entry.control { case .toolAddition, .toolRemoval: true; default: false }
                            }
                            do {
                                try AnthropicConversationControls.validateNativeChanges(replayBlocks[latestCompaction], view: view,
                                    expectedTools: view.activeTools, changed: changed)
                            } catch {
                                throw ModelProviderError(kind: .invalidResponse, message: "Native compaction tool changes cannot establish the trusted active tool state.")
                            }
                        }
                        let transition = ModelNativeContextTransition(mode: compactionMode, source: source,
                            replayPosition: latestCompaction, invocationID: invocation, responseID: info.id)
                        state = .init(model: model, format: ordinary.format, payload: ordinary.payload, contextTransition: transition)
                    } else { state = ordinary }
                    content.append(.providerContinuation(state)); events.append(.providerContinuation(state))
                }
            }
            events.append(.responseCompleted(.init(info: info, content: content, toolCalls: modelCalls, usage: usage, stopReason: stopReason, inputTransformations: inputTransformations)))
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

    private mutating func transformationEvents(_ value: JSONValue?) throws -> [ModelEvent] {
        guard let value, value != .null else { return [] }
        guard case .array(let values) = value, values.count <= 10_000 else { throw ProviderJSON.invalid() }
        let snapshot = try values.map { value in
            let fields = try ProviderJSON.object(value)
            let kind = try ProviderJSON.string(fields["type"]), path = try ProviderJSON.string(fields["path"])
            guard !kind.isEmpty, !path.isEmpty else { throw ProviderJSON.invalid() }
            let reason = try fields["reason"].flatMap { $0 == .null ? nil : try ProviderJSON.string($0) }
            return ModelInputTransformation(kind: kind, reason: reason, path: path, source: inputSources[path])
        }
        inputTransformations = snapshot
        return [.inputTransformations(snapshot)]
    }

    private mutating func usageEvents(_ value: JSONValue?) throws -> [ModelEvent] {
        guard let value, value != .null else { return [] }
        let usage = try ProviderJSON.object(value)
        inputTokens = try ProviderJSON.count(usage["input_tokens"]) ?? inputTokens
        outputTokens = try ProviderJSON.count(usage["output_tokens"]) ?? outputTokens
        cachedInputTokens = try ProviderJSON.count(usage["cache_read_input_tokens"]) ?? cachedInputTokens
        cacheWriteInputTokens = try ProviderJSON.count(usage["cache_creation_input_tokens"]) ?? cacheWriteInputTokens
        if let details = usage["cache_creation"], details != .null {
            let detail = try ProviderJSON.object(details)
            cacheWriteTTL = .init(
                fiveMinuteTokens: try ProviderJSON.count(detail["ephemeral_5m_input_tokens"]) ?? cacheWriteTTL?.fiveMinuteTokens,
                oneHourTokens: try ProviderJSON.count(detail["ephemeral_1h_input_tokens"]) ?? cacheWriteTTL?.oneHourTokens
            )
        }
        if let details = usage["output_tokens_details"], details != .null {
            reasoningTokens = try ProviderJSON.count(ProviderJSON.object(details)["thinking_tokens"]) ?? reasoningTokens
        }
        var total: Int?
        // Native input excludes reads/writes. A missing category cannot be treated
        // as zero to manufacture a complete normalized total.
        if let inputTokens, let cachedInputTokens, let cacheWriteInputTokens {
            let (withRead, readOverflow) = inputTokens.addingReportingOverflow(cachedInputTokens)
            let (withWrite, writeOverflow) = withRead.addingReportingOverflow(cacheWriteInputTokens)
            guard !readOverflow, !writeOverflow else { throw ProviderJSON.invalid() }
            total = withWrite
        }
        if let value = usage["iterations"], value != .null {
            guard !publishedParentUsage else {
                throw ModelProviderError(kind: .invalidResponse,
                    message: "Anthropic changed usage accounting scope after parent counters were published; qualify native iteration accounting before dispatch.")
            }
            guard case .array(let values) = value, values.count <= 1_000 else { throw ProviderJSON.invalid() }
            iterations = try values.enumerated().map { ordinal, value in
                let child = try ProviderJSON.object(value)
                let kind = try ProviderJSON.string(child["type"])
                let nativeInput = try ProviderJSON.count(child["input_tokens"])
                let read = try ProviderJSON.count(child["cache_read_input_tokens"])
                let write = try ProviderJSON.count(child["cache_creation_input_tokens"])
                var inclusive: Int?
                if let nativeInput, let read, let write {
                    let first = nativeInput.addingReportingOverflow(read)
                    let second = first.partialValue.addingReportingOverflow(write)
                    guard !first.overflow, !second.overflow else { throw ProviderJSON.invalid() }
                    inclusive = second.partialValue
                }
                let childModel: ModelID?
                if let name = child["model"], name != .null {
                    let name = try ProviderJSON.string(name)
                    guard !name.isEmpty else { throw ProviderJSON.invalid() }
                    childModel = .init(provider: model.provider, name: name)
                } else if ["message", "compaction"].contains(kind) {
                    childModel = .init(provider: model.provider, name: responseModelName)
                } else { childModel = nil }
                let ttl: CacheWriteTTLUsage?
                if let value = child["cache_creation"], value != .null {
                    let detail = try ProviderJSON.object(value)
                    ttl = .init(fiveMinuteTokens: try ProviderJSON.count(detail["ephemeral_5m_input_tokens"]),
                        oneHourTokens: try ProviderJSON.count(detail["ephemeral_1h_input_tokens"]))
                } else { ttl = nil }
                let details = try child["output_tokens_details"].flatMap { $0 == .null ? nil : try ProviderJSON.object($0) }
                return try .init(ordinal: ordinal, kind: kind, model: childModel, inputTokens: inclusive,
                    outputTokens: ProviderJSON.count(child["output_tokens"]), cachedInputTokens: read, cacheWriteInputTokens: write,
                    reasoningTokens: ProviderJSON.count(details?["thinking_tokens"]), cacheWriteTTL: ttl)
            }
        }
        if iterations != nil { return try iterationUsageEvents(complete: false) }
        if nativeIterationUsage {
            // Under the beta, parent counts exclude compaction. Until the complete
            // iteration table arrives they cannot certify whole-invocation consumption.
            self.usage = .init()
        } else {
            self.usage = .init(inputTokens: total, outputTokens: outputTokens, cachedInputTokens: cachedInputTokens,
                cacheWriteInputTokens: cacheWriteInputTokens, reasoningTokens: reasoningTokens, cacheWriteTTL: cacheWriteTTL)
        }
        if !nativeIterationUsage { publishedParentUsage = true }
        return [.usage(self.usage)]
    }
    private mutating func iterationUsageEvents(complete: Bool) throws -> [ModelEvent] {
        guard let iterations else { return [] }
        let table = try ModelIterationUsage(iterations: iterations, coverage: complete ? .complete : .partial)
        usage = try table.aggregate()
        return [.usage(usage)]
    }

}
