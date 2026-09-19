import AgentModels
import Foundation

struct OpenAIResponsesStreamDecoder {
    private struct PendingCall {
        let itemID: String
        let id: ToolCallID
        let name: String
        var arguments: String
        var argumentsDone = false
        var completed = false
    }

    let model: ModelID
    let responseModelName: String
    private var info: ResponseInfo?
    private var content: [ModelContent] = []
    private var calls: [Int: PendingCall] = [:]
    private var callOrder: [Int] = []
    private var completedItems: [Int: JSONValue] = [:]
    private var usage = ModelUsage()
    private var refusal = false
    private var ended = false

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
        guard !ended else { throw ProviderJSON.invalid() }
        switch type {
        case "response.created":
            guard info == nil else { throw ProviderJSON.invalid() }
            let response = try ProviderJSON.object(object["response"])
            guard try ProviderJSON.string(response["status"]) == "in_progress" else { throw ProviderJSON.invalid() }
            let id = try ProviderJSON.string(response["id"])
            let responseModel = try ProviderJSON.string(response["model"])
            guard !id.isEmpty else { throw ProviderJSON.invalid() }
            try validateResponseModel(responseModel)
            let value = ResponseInfo(id: id, model: model)
            info = value
            return [.responseStarted(value)]
        case "error":
            throw classifyFailure(code: try ProviderJSON.string(object["code"]))
        case "response.failed":
            let response = try ProviderJSON.object(object["response"])
            let error = try ProviderJSON.object(response["error"])
            throw classifyFailure(code: try ProviderJSON.string(error["code"]))
        default:
            break
        }
        guard let info else { throw ProviderJSON.invalid() }

        switch type {
        case "response.output_item.added":
            let index = try requiredIndex(object["output_index"])
            let item = try ProviderJSON.object(object["item"])
            switch try ProviderJSON.string(item["type"]) {
            case "message", "reasoning": return []
            case "function_call":
                guard calls[index] == nil else { throw ProviderJSON.invalid() }
                let itemID = try ProviderJSON.string(item["id"])
                let callID = ToolCallID(rawValue: try ProviderJSON.string(item["call_id"]))
                let name = try ProviderJSON.string(item["name"])
                let arguments = try ProviderJSON.string(item["arguments"])
                guard !itemID.isEmpty, !callID.rawValue.isEmpty, !name.isEmpty else { throw ProviderJSON.invalid() }
                calls[index] = .init(itemID: itemID, id: callID, name: name, arguments: arguments)
                callOrder.append(index)
                var events: [ModelEvent] = [.toolCallStarted(callID, name: name)]
                if !arguments.isEmpty { events.append(.toolCallArgumentsDelta(callID, arguments)) }
                return events
            case "web_search_call", "file_search_call", "code_interpreter_call", "mcp_call", "computer_call",
                 "local_shell_call", "shell_call", "apply_patch_call", "custom_tool_call":
                throw ModelProviderError(kind: .unsupportedCapability,
                                         message: "Provider-hosted tools are not supported by this adapter.")
            default:
                throw ModelProviderError(kind: .unsupportedCapability,
                                         message: "OpenAI returned an unsupported output item type.")
            }
        case "response.output_text.delta":
            let delta = try ProviderJSON.string(object["delta"])
            return append(delta)
        case "response.refusal.delta":
            refusal = true
            return append(try ProviderJSON.string(object["delta"]))
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            return append(try ProviderJSON.string(object["delta"]), reasoning: true)
        case "response.function_call_arguments.delta":
            let index = try requiredIndex(object["output_index"])
            guard var call = calls[index], call.itemID == (try ProviderJSON.string(object["item_id"])),
                  !call.argumentsDone, !call.completed else { throw ProviderJSON.invalid() }
            let delta = try ProviderJSON.string(object["delta"])
            call.arguments += delta
            calls[index] = call
            return [.toolCallArgumentsDelta(call.id, delta)]
        case "response.function_call_arguments.done":
            let index = try requiredIndex(object["output_index"])
            guard var call = calls[index], call.itemID == (try ProviderJSON.string(object["item_id"])),
                  !call.argumentsDone, call.arguments == (try ProviderJSON.string(object["arguments"])) else {
                throw ProviderJSON.invalid()
            }
            call.argumentsDone = true
            calls[index] = call
            return []
        case "response.output_item.done":
            let index = try requiredIndex(object["output_index"])
            let item = try ProviderJSON.object(object["item"])
            let itemType = try ProviderJSON.string(item["type"])
            if itemType == "reasoning" {
                guard !(try ProviderJSON.string(item["id"])).isEmpty,
                      case .array = item["summary"] else { throw ProviderJSON.invalid() }
                if let encrypted = item["encrypted_content"], encrypted != .null {
                    _ = try ProviderJSON.string(encrypted)
                }
                completedItems[index] = .object(item)
                return []
            }
            if itemType == "message" {
                guard !(try ProviderJSON.string(item["id"])).isEmpty,
                      try ProviderJSON.string(item["role"]) == "assistant",
                      case .array = item["content"] else { throw ProviderJSON.invalid() }
                completedItems[index] = .object(item)
                return []
            }
            guard itemType == "function_call" else { throw ProviderJSON.invalid() }
            guard var call = calls[index], !call.completed,
                  call.itemID == (try ProviderJSON.string(item["id"])),
                  call.id.rawValue == (try ProviderJSON.string(item["call_id"])),
                  call.name == (try ProviderJSON.string(item["name"])),
                  call.arguments == (try ProviderJSON.string(item["arguments"])),
                  call.argumentsDone, (try? JSONValue.decodeToolArguments(call.arguments)) != nil else {
                throw ProviderJSON.invalid()
            }
            call.completed = true
            calls[index] = call
            completedItems[index] = .object(item)
            return [.toolCallCompleted(.init(id: call.id, name: call.name,
                                             argumentsJSON: call.arguments, completeness: .complete))]
        case "response.completed":
            let response = try ProviderJSON.object(object["response"])
            guard try ProviderJSON.string(response["id"]) == info.id,
                  try ProviderJSON.string(response["status"]) == "completed",
                  calls.values.allSatisfy({ $0.completed }) else { throw ProviderJSON.invalid() }
            try validateResponseModel(try ProviderJSON.string(response["model"]))
            try validateFinalOutput(response["output"])
            let usageEvents = try updateUsage(response["usage"])
            ended = true
            let modelCalls = callOrder.compactMap { index -> ToolCall? in
                guard let call = calls[index] else { return nil }
                return .init(id: call.id, name: call.name, argumentsJSON: call.arguments, completeness: .complete)
            }
            let stop: StopReason = !modelCalls.isEmpty ? .toolCalls : (refusal ? .refusal : .endTurn)
            var events = usageEvents
            let nativeItems = completedItems.keys.sorted().compactMap { completedItems[$0] }
            if canCreateContinuation(from: nativeItems),
               let continuation = try OpenAIResponsesContinuation.make(
                   items: nativeItems, content: content, calls: modelCalls, model: model
               ) {
                content.append(.providerContinuation(continuation))
                events.append(.providerContinuation(continuation))
            }
            events.append(.responseCompleted(.init(info: info, content: content,
                                                    toolCalls: modelCalls, usage: usage, stopReason: stop)))
            return events
        case "response.incomplete":
            let response = try ProviderJSON.object(object["response"])
            guard try ProviderJSON.string(response["id"]) == info.id,
                  try ProviderJSON.string(response["status"]) == "incomplete" else { throw ProviderJSON.invalid() }
            try validateResponseModel(try ProviderJSON.string(response["model"]))
            let usageEvents = try updateUsage(response["usage"])
            let details = try ProviderJSON.object(response["incomplete_details"])
            let reason = try ProviderJSON.string(details["reason"])
            let stop: StopReason = reason == "max_output_tokens" ? .maxOutputTokens :
                (reason == "content_filter" ? .refusal : .unknown(reason))
            ended = true
            let modelCalls = callOrder.compactMap { index -> ToolCall? in
                guard let call = calls[index] else { return nil }
                return .init(id: call.id, name: call.name, argumentsJSON: call.arguments,
                             completeness: call.completed ? .complete : .incomplete)
            }
            return usageEvents + [.responseCompleted(.init(info: info, content: content,
                                                            toolCalls: modelCalls, usage: usage, stopReason: stop))]
        case "response.created", "error", "response.failed":
            throw ProviderJSON.invalid()
        default:
            return []
        }
    }

    func finish() throws { guard ended else { throw ProviderJSON.invalid() } }

    private func requiredIndex(_ value: JSONValue?) throws -> Int {
        guard let value = try ProviderJSON.count(value) else { throw ProviderJSON.invalid() }
        return value
    }

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

    private mutating func updateUsage(_ value: JSONValue?) throws -> [ModelEvent] {
        guard let value, value != .null else { return [] }
        let object = try ProviderJSON.object(value)
        let input = try ProviderJSON.count(object["input_tokens"])
        let output = try ProviderJSON.count(object["output_tokens"])
        var cached: Int?
        if let details = object["input_tokens_details"], details != .null {
            let details = try ProviderJSON.object(details)
            cached = try ProviderJSON.count(details["cached_tokens"])
        }
        var reasoning: Int?
        if let details = object["output_tokens_details"], details != .null {
            reasoning = try ProviderJSON.count(ProviderJSON.object(details)["reasoning_tokens"])
        }
        usage = .init(inputTokens: input, outputTokens: output, cachedInputTokens: cached,
                      reasoningTokens: reasoning)
        return [.usage(usage)]
    }

    private func validateResponseModel(_ observed: String) throws {
        guard observed.utf8.elementsEqual(responseModelName.utf8) else {
            throw ModelProviderError(
                kind: .invalidResponse,
                message: "OpenAI returned model '\(diagnostic(observed))' but expected '\(diagnostic(responseModelName))'."
            )
        }
    }

    private func classifyFailure(code: String) -> ModelProviderError {
        let kind: ModelProviderError.Kind
        switch code {
        case "rate_limit_exceeded": kind = .rateLimited
        case "server_error", "vector_store_timeout": kind = .unavailable
        case "invalid_prompt", "invalid_request_error", "data_residency_mismatch", "bio_policy",
             "misalignment_policy_violation": kind = .invalidRequest
        case "insufficient_quota": kind = .permissionDenied
        default: kind = .invalidResponse
        }
        return .init(kind: kind, message: "OpenAI generation failed with code '\(diagnostic(code))'.")
    }

    private func validateFinalOutput(_ value: JSONValue?) throws {
        guard case .array(let output) = value else { throw ProviderJSON.invalid() }
        guard output.count == completedItems.count,
              completedItems.keys.sorted() == Array(output.indices) else { throw ProviderJSON.invalid() }
        for index in output.indices {
            guard let streamed = completedItems[index] else { throw ProviderJSON.invalid() }
            try validateFinalItem(output[index], matches: streamed)
        }
    }

    private func validateFinalItem(_ final: JSONValue, matches streamed: JSONValue) throws {
        let final = try ProviderJSON.object(final)
        let streamed = try ProviderJSON.object(streamed)
        let type = try ProviderJSON.string(streamed["type"])
        guard try ProviderJSON.string(final["type"]) == type,
              try ProviderJSON.string(final["id"]) == ProviderJSON.string(streamed["id"]) else {
            throw ProviderJSON.invalid()
        }
        switch type {
        case "message":
            guard try ProviderJSON.string(final["role"]) == ProviderJSON.string(streamed["role"]),
                  try messageText(final["content"]) == messageText(streamed["content"]) else {
                throw ProviderJSON.invalid()
            }
        case "reasoning":
            let finalEncrypted = try optionalString(final["encrypted_content"])
            let streamedEncrypted = try optionalString(streamed["encrypted_content"])
            guard finalEncrypted == streamedEncrypted else { throw ProviderJSON.invalid() }
        case "function_call":
            for field in ["call_id", "name", "arguments"] {
                guard try ProviderJSON.string(final[field]) == ProviderJSON.string(streamed[field]) else {
                    throw ProviderJSON.invalid()
                }
            }
        default:
            throw ProviderJSON.invalid()
        }
    }

    private func messageText(_ value: JSONValue?) throws -> String {
        guard case .array(let parts) = value else { throw ProviderJSON.invalid() }
        return try parts.map { part in
            let part = try ProviderJSON.object(part)
            switch try ProviderJSON.string(part["type"]) {
            case "output_text": return try ProviderJSON.string(part["text"])
            case "refusal": return try ProviderJSON.string(part["refusal"])
            default: throw ProviderJSON.invalid()
            }
        }.joined()
    }

    private func optionalString(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        return try ProviderJSON.string(value)
    }

    private func canCreateContinuation(from items: [JSONValue]) -> Bool {
        let reasoning = items.compactMap { item -> [String: JSONValue]? in
            guard case .object(let object) = item, object["type"] == .string("reasoning") else { return nil }
            return object
        }
        guard !reasoning.isEmpty else { return false }
        return reasoning.allSatisfy { object in
            guard case .string(let encrypted) = object["encrypted_content"] else { return false }
            return !encrypted.isEmpty
        }
    }

    private func diagnostic(_ value: String) -> String {
        let filtered = value.unicodeScalars.lazy.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128)
        return String(String.UnicodeScalarView(filtered))
    }
}
