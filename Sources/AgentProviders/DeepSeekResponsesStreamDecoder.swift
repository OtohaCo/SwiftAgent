import AgentModels
import Foundation

struct DeepSeekResponsesStreamDecoder {
    private enum ItemKind { case message, reasoning, functionCall }
    private enum PartKind: String { case outputText = "output_text", reasoningText = "reasoning_text" }

    private struct PartState {
        let kind: PartKind
        var value = ""
        var announced = false
        var finalized = false

        mutating func seed(_ text: String) throws -> String {
            guard !finalized else { throw ProviderJSON.invalid() }
            guard value.isEmpty || value == text else { throw ProviderJSON.invalid() }
            let suffix = value.isEmpty ? text : ""
            value = text
            return suffix
        }

        mutating func announce(_ text: String) throws -> String {
            guard !announced, !finalized else { throw ProviderJSON.invalid() }
            announced = true
            return try seed(text)
        }

        mutating func append(_ delta: String) throws -> String {
            guard !finalized else { throw ProviderJSON.invalid() }
            value += delta
            return delta
        }

        mutating func finish(_ text: String) throws -> String {
            guard !finalized, text.hasPrefix(value) else { throw ProviderJSON.invalid() }
            let suffix = String(text.dropFirst(value.count))
            value = text
            finalized = true
            return suffix
        }

        mutating func reconcile(_ text: String) throws -> String {
            if finalized {
                guard value == text else { throw ProviderJSON.invalid() }
                return ""
            }
            return try finish(text)
        }
    }

    private struct CallState {
        let id: ToolCallID
        let name: String
        var arguments: String
        var argumentsDone = false
        var completed = false
    }

    private struct ItemState {
        let index: Int
        let id: String
        let kind: ItemKind
        var parts: [Int: PartState] = [:]
        var call: CallState?
        var native: JSONValue?
        var done = false
    }

    let model: ModelID
    let responseModelName: String
    let requiresReasoningForTools: Bool
    private var info: ResponseInfo?
    private var content: [ModelContent] = []
    private var items: [Int: ItemState] = [:]
    private var itemIDs = Set<String>()
    private var usage = ModelUsage()
    private var ended = false
    private var lastSequenceNumber: Int?

    init(model: ModelID, responseModelName: String? = nil, requiresReasoningForTools: Bool = false) {
        self.model = model
        self.responseModelName = responseModelName ?? model.name
        self.requiresReasoningForTools = requiresReasoningForTools
    }

    mutating func consume(_ event: ProviderSSEEvent) throws -> [ModelEvent] {
        let object = try ProviderJSON.decode(event.data)
        let type = try ProviderJSON.string(object["type"])
        if let name = event.name, !name.isEmpty, name != "message", name != type {
            throw ProviderJSON.invalid()
        }
        try validateSequence(object)
        guard !ended else { throw ProviderJSON.invalid() }

        switch type {
        case "response.created", "response.in_progress": return try lifecycle(object)
        case "response.failed": throw try responseFailure(object)
        case "error": throw failure(code: try optionalString(object["code"]))
        default: break
        }
        guard info != nil else { throw ProviderJSON.invalid() }

        switch type {
        case "response.output_item.added": return try itemAdded(object)
        case "response.content_part.added": return try partAdded(object)
        case "response.reasoning_text.delta": return try partDelta(object, kind: .reasoningText)
        case "response.output_text.delta": return try partDelta(object, kind: .outputText)
        case "response.reasoning_text.done": return try partTextDone(object, kind: .reasoningText)
        case "response.output_text.done": return try partTextDone(object, kind: .outputText)
        case "response.content_part.done": return try partDone(object)
        case "response.function_call_arguments.delta": return try argumentsDelta(object)
        case "response.function_call_arguments.done": return try argumentsDone(object)
        case "response.output_item.done": return try itemDone(object)
        case "response.completed": return try completed(object)
        case "response.incomplete": return try incomplete(object)
        case "response.created", "response.in_progress", "response.failed", "error":
            throw ProviderJSON.invalid()
        default:
            return []
        }
    }

    func finish() throws { guard ended else { throw ProviderJSON.invalid() } }

    private mutating func validateSequence(_ object: [String: JSONValue]) throws {
        guard let sequence = try ProviderJSON.count(object["sequence_number"]) else {
            throw ProviderJSON.invalid()
        }
        if let lastSequenceNumber, sequence <= lastSequenceNumber { throw ProviderJSON.invalid() }
        lastSequenceNumber = sequence
    }

    private mutating func lifecycle(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let response = try ProviderJSON.object(object["response"])
        let id = try ProviderJSON.string(response["id"])
        let observedModel = try ProviderJSON.string(response["model"])
        guard !id.isEmpty, try ProviderJSON.string(response["status"]) == "in_progress" else {
            throw ProviderJSON.invalid()
        }
        try validateModel(observedModel)
        if let info {
            guard info.id == id else { throw ProviderJSON.invalid() }
            return []
        }
        let started = ResponseInfo(id: id, model: model)
        info = started
        return [.responseStarted(started)]
    }

    private mutating func itemAdded(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let index = try index(object["output_index"])
        guard items[index] == nil else { throw ProviderJSON.invalid() }
        let item = try ProviderJSON.object(object["item"])
        let id = try ProviderJSON.string(item["id"])
        guard !id.isEmpty, itemIDs.insert(id).inserted else { throw ProviderJSON.invalid() }
        switch try ProviderJSON.string(item["type"]) {
        case "message":
            try validateItemStatus(item["status"], expected: "in_progress")
            guard try ProviderJSON.string(item["role"]) == "assistant",
                  case .array(let parts) = item["content"] else { throw ProviderJSON.invalid() }
            var state = ItemState(index: index, id: id, kind: .message)
            var events: [ModelEvent] = []
            for (partIndex, value) in parts.enumerated() {
                let text = try seedPart(&state, partIndex: partIndex, value: value, expected: .outputText)
                events.append(contentsOf: appendText(text))
            }
            items[index] = state
            return events
        case "reasoning":
            try validateItemStatus(item["status"], expected: "in_progress")
            guard case .array(let parts) = item["content"] else { throw ProviderJSON.invalid() }
            var state = ItemState(index: index, id: id, kind: .reasoning)
            var events: [ModelEvent] = []
            for (partIndex, value) in parts.enumerated() {
                let text = try seedPart(&state, partIndex: partIndex, value: value, expected: .reasoningText)
                events.append(contentsOf: appendReasoning(text))
            }
            items[index] = state
            return events
        case "function_call":
            try validateItemStatus(item["status"], expected: "in_progress")
            let callID = ToolCallID(rawValue: try ProviderJSON.string(item["call_id"]))
            let name = try ProviderJSON.string(item["name"])
            let arguments = try ProviderJSON.string(item["arguments"])
            guard !callID.rawValue.isEmpty, !name.isEmpty else { throw ProviderJSON.invalid() }
            items[index] = .init(index: index, id: id, kind: .functionCall,
                                 call: .init(id: callID, name: name, arguments: arguments))
            return [.toolCallStarted(callID, name: name)]
                + (arguments.isEmpty ? [] : [.toolCallArgumentsDelta(callID, arguments)])
        case "custom_tool_call", "web_search_call", "file_search_call", "code_interpreter_call",
             "computer_call", "mcp_call", "apply_patch_call":
            throw ModelProviderError(kind: .unsupportedCapability,
                                     message: "Provider-hosted and custom tools are not supported by this adapter.")
        default:
            throw ModelProviderError(kind: .unsupportedCapability,
                                     message: "DeepSeek returned an unsupported output item type.")
        }
    }

    private mutating func partAdded(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        let partIndex = try index(object["content_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[itemIndex], state.id == itemID, !state.done else { throw ProviderJSON.invalid() }
        let expected: PartKind = state.kind == .reasoning ? .reasoningText : .outputText
        guard state.kind != .functionCall else { throw ProviderJSON.invalid() }
        let part = try ProviderJSON.object(object["part"])
        guard PartKind(rawValue: try ProviderJSON.string(part["type"])) == expected else {
            throw ProviderJSON.invalid()
        }
        var value = state.parts[partIndex] ?? .init(kind: expected)
        guard value.kind == expected else { throw ProviderJSON.invalid() }
        let appended = try value.announce(try ProviderJSON.string(part["text"]))
        state.parts[partIndex] = value
        items[itemIndex] = state
        return expected == .reasoningText ? appendReasoning(appended) : appendText(appended)
    }

    private mutating func partDelta(_ object: [String: JSONValue], kind: PartKind) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        let partIndex = try index(object["content_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[itemIndex], state.id == itemID, !state.done,
              var part = state.parts[partIndex], part.kind == kind else { throw ProviderJSON.invalid() }
        let appended = try part.append(try ProviderJSON.string(object["delta"]))
        state.parts[partIndex] = part
        items[itemIndex] = state
        return kind == .reasoningText ? appendReasoning(appended) : appendText(appended)
    }

    private mutating func partTextDone(_ object: [String: JSONValue], kind: PartKind) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        let partIndex = try index(object["content_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[itemIndex], state.id == itemID, !state.done,
              var part = state.parts[partIndex], part.kind == kind else { throw ProviderJSON.invalid() }
        let appended = try part.finish(try ProviderJSON.string(object["text"]))
        state.parts[partIndex] = part
        items[itemIndex] = state
        return kind == .reasoningText ? appendReasoning(appended) : appendText(appended)
    }

    private mutating func partDone(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        let partIndex = try index(object["content_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[itemIndex], state.id == itemID, !state.done,
              state.kind != .functionCall, var existing = state.parts[partIndex] else {
            throw ProviderJSON.invalid()
        }
        let part = try ProviderJSON.object(object["part"])
        guard PartKind(rawValue: try ProviderJSON.string(part["type"])) == existing.kind else {
            throw ProviderJSON.invalid()
        }
        let appended = try existing.reconcile(try ProviderJSON.string(part["text"]))
        state.parts[partIndex] = existing
        items[itemIndex] = state
        return existing.kind == .reasoningText ? appendReasoning(appended) : appendText(appended)
    }

    private mutating func argumentsDelta(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[itemIndex], state.id == itemID, !state.done,
              var call = state.call, !call.argumentsDone, !call.completed else { throw ProviderJSON.invalid() }
        let delta = try ProviderJSON.string(object["delta"])
        call.arguments += delta
        state.call = call
        items[itemIndex] = state
        return delta.isEmpty ? [] : [.toolCallArgumentsDelta(call.id, delta)]
    }

    private mutating func argumentsDone(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[itemIndex], state.id == itemID, !state.done,
              var call = state.call, !call.argumentsDone, !call.completed else { throw ProviderJSON.invalid() }
        let final = try ProviderJSON.string(object["arguments"])
        guard final.hasPrefix(call.arguments) else { throw ProviderJSON.invalid() }
        let suffix = String(final.dropFirst(call.arguments.count))
        call.arguments = final
        call.argumentsDone = true
        state.call = call
        items[itemIndex] = state
        return suffix.isEmpty ? [] : [.toolCallArgumentsDelta(call.id, suffix)]
    }

    private mutating func itemDone(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        guard var state = items[itemIndex], !state.done else { throw ProviderJSON.invalid() }
        let item = try ProviderJSON.object(object["item"])
        guard try ProviderJSON.string(item["id"]) == state.id else { throw ProviderJSON.invalid() }
        var events: [ModelEvent] = []
        switch state.kind {
        case .message:
            try validateItemStatus(item["status"], expected: "completed")
            try reconcileParts(item, state: &state, expected: .outputText, events: &events)
        case .reasoning:
            try validateItemStatus(item["status"], expected: "completed")
            try reconcileParts(item, state: &state, expected: .reasoningText, events: &events)
            guard !state.parts.isEmpty, state.parts.values.contains(where: { !$0.value.isEmpty }) else {
                throw ProviderJSON.invalid()
            }
        case .functionCall:
            try validateItemStatus(item["status"], expected: "completed")
            guard try ProviderJSON.string(item["type"]) == "function_call", var call = state.call,
                  call.argumentsDone,
                  try ProviderJSON.string(item["call_id"]) == call.id.rawValue,
                  try ProviderJSON.string(item["name"]) == call.name else { throw ProviderJSON.invalid() }
            let final = try ProviderJSON.string(item["arguments"])
            guard final == call.arguments,
                  (try? JSONValue.decodeToolArguments(final)) != nil else { throw ProviderJSON.invalid() }
            call.completed = true
            state.call = call
            events.append(.toolCallCompleted(.init(id: call.id, name: call.name,
                                                   argumentsJSON: final, completeness: .complete)))
        }
        state.native = .object(item)
        state.done = true
        items[itemIndex] = state
        return events
    }

    private mutating func completed(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let response = try ProviderJSON.object(object["response"])
        guard let info, try ProviderJSON.string(response["id"]) == info.id,
              try ProviderJSON.string(response["status"]) == "completed" else {
            throw deepSeekCompletedInvalid("identity")
        }
        try validateModel(try ProviderJSON.string(response["model"]))
        guard items.values.allSatisfy(\.done), items.values.allSatisfy({ $0.call?.completed != false }) else {
            throw deepSeekCompletedInvalid("lifecycle")
        }
        do {
            try validateFinalOutput(response["output"], completed: true)
        } catch let error as ModelProviderError where error.message == "Invalid provider response." {
            throw deepSeekCompletedInvalid("output snapshot")
        }
        let usageEvents: [ModelEvent]
        do {
            usageEvents = try updateUsage(response["usage"])
        } catch let error as ModelProviderError where error.message == "Invalid provider response." {
            throw deepSeekCompletedInvalid("usage")
        }
        let calls = orderedCalls()
        if requiresReasoningForTools {
            let reasoning = items.values.filter { $0.kind == .reasoning }.flatMap(\.parts.values).map(\.value).joined()
            guard !reasoning.isEmpty else { throw ProviderJSON.invalid() }
        }
        ended = true
        var events = usageEvents
        let nativeItems = items.keys.sorted().compactMap { items[$0]?.native }
        do {
            if let continuation = try DeepSeekResponsesContinuation.make(
                items: nativeItems, content: content, calls: calls, model: model
            ) {
                content.append(.providerContinuation(continuation))
                events.append(.providerContinuation(continuation))
            }
        } catch let error as ModelProviderError where error.message == "Invalid provider response." {
            throw deepSeekCompletedInvalid("continuation")
        }
        events.append(.responseCompleted(.init(
            info: info, content: content, toolCalls: calls, usage: usage,
            stopReason: calls.isEmpty ? .endTurn : .toolCalls
        )))
        return events
    }

    private func deepSeekCompletedInvalid(_ stage: String) -> ModelProviderError {
        .init(kind: .invalidResponse, message: "Invalid DeepSeek completed \(stage).")
    }

    private mutating func incomplete(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let response = try ProviderJSON.object(object["response"])
        guard let info, try ProviderJSON.string(response["id"]) == info.id,
              try ProviderJSON.string(response["status"]) == "incomplete" else { throw ProviderJSON.invalid() }
        try validateModel(try ProviderJSON.string(response["model"]))
        try validateFinalOutput(response["output"], completed: false)
        let usageEvents = try updateUsage(response["usage"])
        let details = try ProviderJSON.object(response["incomplete_details"])
        let reason = try ProviderJSON.string(details["reason"])
        let stop: StopReason = reason == "max_output_tokens" ? .maxOutputTokens
            : (reason == "content_filter" ? .refusal : .unknown(reason))
        let calls = items.keys.sorted().compactMap { item -> ToolCall? in
            guard let call = items[item]?.call else { return nil }
            return .init(id: call.id, name: call.name, argumentsJSON: call.arguments,
                         completeness: call.completed ? .complete : .incomplete)
        }
        ended = true
        return usageEvents + [.responseCompleted(.init(info: info, content: content, toolCalls: calls,
                                                       usage: usage, stopReason: stop))]
    }

    private func seedPart(
        _ state: inout ItemState, partIndex: Int, value: JSONValue, expected: PartKind
    ) throws -> String {
        let object = try ProviderJSON.object(value)
        guard PartKind(rawValue: try ProviderJSON.string(object["type"])) == expected else {
            throw ProviderJSON.invalid()
        }
        var part = state.parts[partIndex] ?? .init(kind: expected)
        let appended = try part.seed(try ProviderJSON.string(object["text"]))
        state.parts[partIndex] = part
        return appended
    }

    private mutating func reconcileParts(
        _ item: [String: JSONValue], state: inout ItemState, expected: PartKind,
        events: inout [ModelEvent]
    ) throws {
        guard try ProviderJSON.string(item["type"]) == (expected == .reasoningText ? "reasoning" : "message"),
              case .array(let parts) = item["content"], state.parts.keys.sorted() == Array(parts.indices) else {
            throw ProviderJSON.invalid()
        }
        if expected == .outputText, try ProviderJSON.string(item["role"]) != "assistant" {
            throw ProviderJSON.invalid()
        }
        for index in parts.indices {
            let value = try ProviderJSON.object(parts[index])
            guard PartKind(rawValue: try ProviderJSON.string(value["type"])) == expected,
                  var part = state.parts[index] else { throw ProviderJSON.invalid() }
            let appended = try part.reconcile(try ProviderJSON.string(value["text"]))
            state.parts[index] = part
            events.append(contentsOf: expected == .reasoningText ? appendReasoning(appended) : appendText(appended))
        }
    }

    private func validateFinalOutput(_ value: JSONValue?, completed: Bool) throws {
        guard case .array(let output) = value, output.count == items.count,
              items.keys.sorted() == Array(output.indices) else { throw ProviderJSON.invalid() }
        for index in output.indices {
            guard let state = items[index] else { throw ProviderJSON.invalid() }
            if completed && !state.done { throw ProviderJSON.invalid() }
            let item = try ProviderJSON.object(output[index])
            guard try ProviderJSON.string(item["id"]) == state.id else { throw ProviderJSON.invalid() }
            try validateFinalItem(item, against: state)
        }
    }

    private func validateFinalItem(_ item: [String: JSONValue], against state: ItemState) throws {
        try validateItemStatus(item["status"], expected: state.done ? "completed" : "incomplete")
        switch state.kind {
        case .message, .reasoning:
            let expectedType = state.kind == .message ? "message" : "reasoning"
            let expectedPart: PartKind = state.kind == .message ? .outputText : .reasoningText
            guard try ProviderJSON.string(item["type"]) == expectedType,
                  case .array(let parts) = item["content"],
                  state.parts.keys.sorted() == Array(parts.indices) else {
                throw ProviderJSON.invalid()
            }
            if state.kind == .message, try ProviderJSON.string(item["role"]) != "assistant" {
                throw ProviderJSON.invalid()
            }
            for index in parts.indices {
                let part = try ProviderJSON.object(parts[index])
                guard PartKind(rawValue: try ProviderJSON.string(part["type"])) == expectedPart,
                      try ProviderJSON.string(part["text"]) == state.parts[index]?.value else {
                    throw ProviderJSON.invalid()
                }
            }
        case .functionCall:
            guard try ProviderJSON.string(item["type"]) == "function_call",
                  let call = state.call,
                  try ProviderJSON.string(item["call_id"]) == call.id.rawValue,
                  try ProviderJSON.string(item["name"]) == call.name,
                  try ProviderJSON.string(item["arguments"]) == call.arguments else {
                throw ProviderJSON.invalid()
            }
        }
    }

    private func validateItemStatus(_ value: JSONValue?, expected: String) throws {
        guard let value else { return }
        guard value != .null else { throw ProviderJSON.invalid() }
        let status = try ProviderJSON.string(value)
        guard ["in_progress", "completed", "incomplete"].contains(status), status == expected else {
            throw ProviderJSON.invalid()
        }
    }

    private func orderedCalls() -> [ToolCall] {
        items.keys.sorted().compactMap { key in
            guard let call = items[key]?.call else { return nil }
            return .init(id: call.id, name: call.name, argumentsJSON: call.arguments, completeness: .complete)
        }
    }

    private mutating func appendText(_ delta: String) -> [ModelEvent] {
        guard !delta.isEmpty else { return [] }
        if case .text(let prior) = content.last { content[content.count - 1] = .text(prior + delta) }
        else { content.append(.text(delta)) }
        return [.textDelta(delta)]
    }

    private mutating func appendReasoning(_ delta: String) -> [ModelEvent] {
        guard !delta.isEmpty else { return [] }
        if case .reasoning(let prior) = content.last { content[content.count - 1] = .reasoning(prior + delta) }
        else { content.append(.reasoning(delta)) }
        return [.reasoningDelta(delta)]
    }

    private mutating func updateUsage(_ value: JSONValue?) throws -> [ModelEvent] {
        guard let value, value != .null else { return [] }
        let object = try ProviderJSON.object(value)
        let input = try ProviderJSON.count(object["input_tokens"])
        let output = try ProviderJSON.count(object["output_tokens"])
        let cached = try optionalCount(object["input_tokens_details"], field: "cached_tokens")
        let reasoning = try optionalCount(object["output_tokens_details"], field: "reasoning_tokens")
        usage = .init(inputTokens: input, outputTokens: output, cachedInputTokens: cached,
                      reasoningTokens: reasoning)
        return [.usage(usage)]
    }

    private func optionalCount(_ value: JSONValue?, field: String) throws -> Int? {
        guard let value, value != .null else { return nil }
        return try ProviderJSON.count(ProviderJSON.object(value)[field])
    }

    private func responseFailure(_ object: [String: JSONValue]) throws -> ModelProviderError {
        let response = try ProviderJSON.object(object["response"])
        let error = try ProviderJSON.object(response["error"])
        return failure(code: try optionalString(error["code"]))
    }

    private func failure(code: String?) -> ModelProviderError {
        let code = code ?? ""
        let kind: ModelProviderError.Kind
        switch code {
        case "rate_limit_exceeded": kind = .rateLimited
        case "server_error": kind = .unavailable
        case "invalid_request_error", "invalid_prompt": kind = .invalidRequest
        case "insufficient_quota": kind = .permissionDenied
        default: kind = .invalidResponse
        }
        return .init(kind: kind, message: "DeepSeek generation failed with code '\(diagnostic(code))'.")
    }

    private func validateModel(_ observed: String) throws {
        guard observed == responseModelName else {
            throw ModelProviderError(
                kind: .invalidResponse,
                message: "DeepSeek returned model '\(diagnostic(observed))' but expected '\(diagnostic(responseModelName))'."
            )
        }
    }

    private func index(_ value: JSONValue?) throws -> Int {
        guard let value = try ProviderJSON.count(value) else { throw ProviderJSON.invalid() }
        return value
    }

    private func optionalString(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        return try ProviderJSON.string(value)
    }

    private func diagnostic(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.lazy
            .filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128)))
    }
}
