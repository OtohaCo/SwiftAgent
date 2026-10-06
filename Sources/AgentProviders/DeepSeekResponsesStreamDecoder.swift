import AgentModels
import Foundation

struct DeepSeekResponsesStreamDecoder {
    private enum ItemKind { case message, reasoning, functionCall }
    private enum ItemTerminalStatus: String { case completed, incomplete }
    private enum PartKind: String { case outputText = "output_text", reasoningText = "reasoning_text" }

    private struct PartState {
        let kind: PartKind
        var value = ""
        var announced = false
        var finalized = false

        mutating func seed(_ text: String) throws -> String {
            guard !finalized else { throw DeepSeekResponseJSON.invalid() }
            guard value.isEmpty || value.utf8.elementsEqual(text.utf8) else { throw DeepSeekResponseJSON.invalid() }
            let suffix = value.isEmpty ? text : ""
            value = text
            return suffix
        }

        mutating func announce(_ text: String) throws -> String {
            guard !announced, !finalized else { throw DeepSeekResponseJSON.invalid() }
            announced = true
            return try seed(text)
        }

        mutating func append(_ delta: String) throws -> String {
            guard !finalized else { throw DeepSeekResponseJSON.invalid() }
            value += delta
            return delta
        }

        mutating func finish(_ text: String) throws -> String {
            guard !finalized, text.utf8.starts(with: value.utf8) else { throw DeepSeekResponseJSON.invalid() }
            let suffix = String(decoding: text.utf8.dropFirst(value.utf8.count), as: UTF8.self)
            value = text
            finalized = true
            return suffix
        }

        mutating func reconcile(_ text: String) throws -> String {
            if finalized {
                guard value.utf8.elementsEqual(text.utf8) else { throw DeepSeekResponseJSON.invalid() }
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
        var terminalStatus: ItemTerminalStatus?
    }

    let model: ModelID
    let responseModelName: String
    private var info: ResponseInfo?
    private var content: [ModelContent] = []
    private var items: [Int: ItemState] = [:]
    private var itemIDs = Set<String>()
    private var usage = ModelUsage()
    private var ended = false
    private var lastSequenceNumber: Int?

    init(model: ModelID, responseModelName: String? = nil) {
        self.model = model
        self.responseModelName = responseModelName ?? model.name
    }

    mutating func consume(_ event: ProviderSSEEvent) throws -> [ModelEvent] {
        do { return try consumeShape(event) }
        catch is DeepSeekResponseShapeError { throw deepSeekEventDiagnostic(frame: event) }
    }

    private mutating func consumeShape(_ event: ProviderSSEEvent) throws -> [ModelEvent] {
        let object = try DeepSeekResponseJSON.decode(event.data)
        let type = try DeepSeekResponseJSON.string(object["type"])
        if let name = event.name, !name.isEmpty, name != "message", name != type {
            throw DeepSeekResponseJSON.invalid()
        }
        try validateSequence(object)
        guard !ended else { throw DeepSeekResponseJSON.invalid() }

        switch type {
        case "response.created", "response.in_progress": return try lifecycle(object)
        case "response.failed": throw try responseFailure(object)
        case "error": throw failure(code: try optionalString(object["code"]))
        default: break
        }
        guard info != nil else { throw DeepSeekResponseJSON.invalid() }

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
            throw DeepSeekResponseJSON.invalid()
        default:
            return []
        }
    }

    func finish() throws {
        guard ended else {
            throw ModelProviderError(kind: .invalidResponse, message: "DeepSeek stream ended without a terminal response.",
                                     diagnostic: .init(stage: .streamLifecycle, reason: .invalidLifecycle))
        }
    }

    private mutating func validateSequence(_ object: [String: JSONValue]) throws {
        guard let sequence = try DeepSeekResponseJSON.count(object["sequence_number"]) else {
            throw DeepSeekResponseJSON.invalid()
        }
        if let lastSequenceNumber, sequence <= lastSequenceNumber { throw DeepSeekResponseJSON.invalid() }
        lastSequenceNumber = sequence
    }

    private mutating func lifecycle(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let response = try DeepSeekResponseJSON.object(object["response"])
        let id = try DeepSeekResponseJSON.string(response["id"])
        let observedModel = try DeepSeekResponseJSON.string(response["model"])
        guard !id.isEmpty, try DeepSeekResponseJSON.string(response["status"]) == "in_progress" else {
            throw DeepSeekResponseJSON.invalid()
        }
        try validateModel(observedModel)
        if let info {
            guard info.id.utf8.elementsEqual(id.utf8) else { throw DeepSeekResponseJSON.invalid() }
            return []
        }
        let started = ResponseInfo(id: id, model: model)
        info = started
        return [.responseStarted(started)]
    }

    private mutating func itemAdded(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let index = try index(object["output_index"])
        guard items[index] == nil else { throw DeepSeekResponseJSON.invalid() }
        let item = try DeepSeekResponseJSON.object(object["item"])
        let id = try DeepSeekResponseJSON.string(item["id"])
        guard !id.isEmpty, itemIDs.insert(id).inserted else { throw DeepSeekResponseJSON.invalid() }
        switch try DeepSeekResponseJSON.string(item["type"]) {
        case "message":
            try validateItemStatus(item["status"], expected: "in_progress")
            guard try DeepSeekResponseJSON.string(item["role"]) == "assistant",
                  case .array(let parts) = item["content"] else { throw DeepSeekResponseJSON.invalid() }
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
            guard case .array(let parts) = item["content"] else { throw DeepSeekResponseJSON.invalid() }
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
            let callID = ToolCallID(rawValue: try DeepSeekResponseJSON.string(item["call_id"]))
            let name = try DeepSeekResponseJSON.string(item["name"])
            let arguments = try DeepSeekResponseJSON.string(item["arguments"])
            guard !callID.rawValue.isEmpty, !name.isEmpty else { throw DeepSeekResponseJSON.invalid() }
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
        let itemID = try DeepSeekResponseJSON.string(object["item_id"])
        guard var state = items[itemIndex], state.id.utf8.elementsEqual(itemID.utf8), !state.done else { throw DeepSeekResponseJSON.invalid() }
        let expected: PartKind = state.kind == .reasoning ? .reasoningText : .outputText
        guard state.kind != .functionCall else { throw DeepSeekResponseJSON.invalid() }
        let part = try DeepSeekResponseJSON.object(object["part"])
        guard PartKind(rawValue: try DeepSeekResponseJSON.string(part["type"])) == expected else {
            throw DeepSeekResponseJSON.invalid()
        }
        var value = state.parts[partIndex] ?? .init(kind: expected)
        guard value.kind == expected else { throw DeepSeekResponseJSON.invalid() }
        let appended = try value.announce(try DeepSeekResponseJSON.string(part["text"]))
        state.parts[partIndex] = value
        items[itemIndex] = state
        return expected == .reasoningText ? appendReasoning(appended) : appendText(appended)
    }

    private mutating func partDelta(_ object: [String: JSONValue], kind: PartKind) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        let partIndex = try index(object["content_index"])
        let itemID = try DeepSeekResponseJSON.string(object["item_id"])
        guard var state = items[itemIndex], state.id.utf8.elementsEqual(itemID.utf8), !state.done,
              var part = state.parts[partIndex], part.kind == kind else { throw DeepSeekResponseJSON.invalid() }
        let appended = try part.append(try DeepSeekResponseJSON.string(object["delta"]))
        state.parts[partIndex] = part
        items[itemIndex] = state
        return kind == .reasoningText ? appendReasoning(appended) : appendText(appended)
    }

    private mutating func partTextDone(_ object: [String: JSONValue], kind: PartKind) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        let partIndex = try index(object["content_index"])
        let itemID = try DeepSeekResponseJSON.string(object["item_id"])
        guard var state = items[itemIndex], state.id.utf8.elementsEqual(itemID.utf8), !state.done,
              var part = state.parts[partIndex], part.kind == kind else { throw DeepSeekResponseJSON.invalid() }
        let appended = try part.finish(try DeepSeekResponseJSON.string(object["text"]))
        state.parts[partIndex] = part
        items[itemIndex] = state
        return kind == .reasoningText ? appendReasoning(appended) : appendText(appended)
    }

    private mutating func partDone(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        let partIndex = try index(object["content_index"])
        let itemID = try DeepSeekResponseJSON.string(object["item_id"])
        guard var state = items[itemIndex], state.id.utf8.elementsEqual(itemID.utf8), !state.done,
              state.kind != .functionCall, var existing = state.parts[partIndex] else {
            throw DeepSeekResponseJSON.invalid()
        }
        let part = try DeepSeekResponseJSON.object(object["part"])
        guard PartKind(rawValue: try DeepSeekResponseJSON.string(part["type"])) == existing.kind else {
            throw DeepSeekResponseJSON.invalid()
        }
        let appended = try existing.reconcile(try DeepSeekResponseJSON.string(part["text"]))
        state.parts[partIndex] = existing
        items[itemIndex] = state
        return existing.kind == .reasoningText ? appendReasoning(appended) : appendText(appended)
    }

    private mutating func argumentsDelta(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        let itemID = try DeepSeekResponseJSON.string(object["item_id"])
        guard var state = items[itemIndex], state.id.utf8.elementsEqual(itemID.utf8), !state.done,
              var call = state.call, !call.argumentsDone, !call.completed else { throw DeepSeekResponseJSON.invalid() }
        let delta = try DeepSeekResponseJSON.string(object["delta"])
        call.arguments += delta
        state.call = call
        items[itemIndex] = state
        return delta.isEmpty ? [] : [.toolCallArgumentsDelta(call.id, delta)]
    }

    private mutating func argumentsDone(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        let itemID = try DeepSeekResponseJSON.string(object["item_id"])
        guard var state = items[itemIndex], state.id.utf8.elementsEqual(itemID.utf8), !state.done,
              var call = state.call, !call.argumentsDone, !call.completed else { throw DeepSeekResponseJSON.invalid() }
        let final = try DeepSeekResponseJSON.string(object["arguments"])
        guard final.utf8.starts(with: call.arguments.utf8) else { throw DeepSeekResponseJSON.invalid() }
        let suffix = String(decoding: final.utf8.dropFirst(call.arguments.utf8.count), as: UTF8.self)
        call.arguments = final
        call.argumentsDone = true
        state.call = call
        items[itemIndex] = state
        return suffix.isEmpty ? [] : [.toolCallArgumentsDelta(call.id, suffix)]
    }

    private mutating func itemDone(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let itemIndex = try index(object["output_index"])
        guard var state = items[itemIndex], !state.done else { throw DeepSeekResponseJSON.invalid() }
        let item = try DeepSeekResponseJSON.object(object["item"])
        guard try DeepSeekResponseJSON.string(item["id"]).utf8.elementsEqual(state.id.utf8) else { throw DeepSeekResponseJSON.invalid() }
        var events: [ModelEvent] = []
        let status = try optionalString(item["status"])
        let terminalStatus = status.flatMap(ItemTerminalStatus.init(rawValue:))
        guard status == nil || terminalStatus != nil else { throw DeepSeekResponseJSON.invalid() }
        let incomplete = terminalStatus == .incomplete
        switch state.kind {
        case .message:
            try validateItemStatus(item["status"], expected: status ?? "completed")
            try reconcileParts(item, state: &state, expected: .outputText, events: &events)
        case .reasoning:
            try validateItemStatus(item["status"], expected: status ?? "completed")
            try reconcileParts(item, state: &state, expected: .reasoningText, events: &events)
            guard incomplete
                || (!state.parts.isEmpty && state.parts.values.contains(where: { !$0.value.isEmpty })) else {
                throw DeepSeekResponseJSON.invalid()
            }
        case .functionCall:
            try validateItemStatus(item["status"], expected: status ?? "completed")
            guard try DeepSeekResponseJSON.string(item["type"]) == "function_call", var call = state.call,
                  try DeepSeekResponseJSON.string(item["call_id"]).utf8.elementsEqual(call.id.rawValue.utf8),
                  try DeepSeekResponseJSON.string(item["name"]).utf8.elementsEqual(call.name.utf8) else { throw DeepSeekResponseJSON.invalid() }
            let final = try DeepSeekResponseJSON.string(item["arguments"])
            guard final.utf8.starts(with: call.arguments.utf8) else { throw DeepSeekResponseJSON.invalid() }
            call.arguments = final
            if !incomplete {
                // Arguments that are not one JSON object are the model's mistake; the runtime reports them to the model.
                guard call.argumentsDone else { throw DeepSeekResponseJSON.invalid() }
                call.completed = true
            }
            state.call = call
            if !incomplete {
                events.append(.toolCallCompleted(.init(id: call.id, name: call.name,
                                                       argumentsJSON: final, completeness: .complete)))
            }
        }
        state.native = .object(item)
        state.done = true
        state.terminalStatus = terminalStatus
        items[itemIndex] = state
        return events
    }

    private mutating func completed(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let response = try DeepSeekResponseJSON.object(object["response"])
        guard let info, try DeepSeekResponseJSON.string(response["id"]).utf8.elementsEqual(info.id.utf8),
              try DeepSeekResponseJSON.string(response["status"]) == "completed" else {
            throw deepSeekCompletedInvalid("identity", reason: .invalidTerminal)
        }
        try validateModel(try DeepSeekResponseJSON.string(response["model"]))
        guard items.values.allSatisfy({ $0.done && $0.terminalStatus != .incomplete }),
              items.values.allSatisfy({ $0.call?.completed != false }) else {
            throw deepSeekCompletedInvalid("lifecycle", reason: .invalidLifecycle)
        }
        do {
            try validateFinalOutput(response["output"], completed: true)
        } catch is DeepSeekResponseShapeError {
            throw deepSeekCompletedInvalid("output snapshot", reason: .finalSnapshotMismatch)
        }
        let usageEvents: [ModelEvent]
        do {
            usageEvents = try updateUsage(response["usage"])
        } catch is DeepSeekResponseShapeError {
            throw deepSeekCompletedInvalid("usage", reason: .invalidUsage)
        }
        let calls = orderedCalls()
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
        } catch let error as ModelProviderError where error.kind == .invalidResponse {
            throw deepSeekCompletedInvalid("continuation", reason: .continuationMismatch)
        }
        events.append(.responseCompleted(.init(
            info: info, content: content, toolCalls: calls, usage: usage,
            stopReason: calls.isEmpty ? .endTurn : .toolCalls
        )))
        return events
    }

    private func deepSeekCompletedInvalid(_ stage: String, reason: ModelProviderError.Diagnostic.Reason) -> ModelProviderError {
        .init(kind: .invalidResponse, message: "Invalid DeepSeek completed \(stage).",
              diagnostic: .init(stage: .responseValidation, reason: reason))
    }

    private mutating func incomplete(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let response = try DeepSeekResponseJSON.object(object["response"])
        guard let info, try DeepSeekResponseJSON.string(response["id"]).utf8.elementsEqual(info.id.utf8),
              try DeepSeekResponseJSON.string(response["status"]) == "incomplete" else { throw DeepSeekResponseJSON.invalid() }
        try validateModel(try DeepSeekResponseJSON.string(response["model"]))
        try validateFinalOutput(response["output"], completed: false)
        let usageEvents = try updateUsage(response["usage"])
        let details = try DeepSeekResponseJSON.object(response["incomplete_details"])
        let reason = try DeepSeekResponseJSON.string(details["reason"])
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
        let object = try DeepSeekResponseJSON.object(value)
        guard PartKind(rawValue: try DeepSeekResponseJSON.string(object["type"])) == expected else {
            throw DeepSeekResponseJSON.invalid()
        }
        var part = state.parts[partIndex] ?? .init(kind: expected)
        let appended = try part.seed(try DeepSeekResponseJSON.string(object["text"]))
        state.parts[partIndex] = part
        return appended
    }

    private mutating func reconcileParts(
        _ item: [String: JSONValue], state: inout ItemState, expected: PartKind,
        events: inout [ModelEvent]
    ) throws {
        guard try DeepSeekResponseJSON.string(item["type"]) == (expected == .reasoningText ? "reasoning" : "message"),
              case .array(let parts) = item["content"], state.parts.keys.sorted() == Array(parts.indices) else {
            throw DeepSeekResponseJSON.invalid()
        }
        if expected == .outputText, try DeepSeekResponseJSON.string(item["role"]) != "assistant" {
            throw DeepSeekResponseJSON.invalid()
        }
        for index in parts.indices {
            let value = try DeepSeekResponseJSON.object(parts[index])
            guard PartKind(rawValue: try DeepSeekResponseJSON.string(value["type"])) == expected,
                  var part = state.parts[index] else { throw DeepSeekResponseJSON.invalid() }
            let appended = try part.reconcile(try DeepSeekResponseJSON.string(value["text"]))
            state.parts[index] = part
            events.append(contentsOf: expected == .reasoningText ? appendReasoning(appended) : appendText(appended))
        }
    }

    private func validateFinalOutput(_ value: JSONValue?, completed: Bool) throws {
        guard case .array(let output) = value, output.count == items.count,
              items.keys.sorted() == Array(output.indices) else { throw DeepSeekResponseJSON.invalid() }
        for index in output.indices {
            guard let state = items[index] else { throw DeepSeekResponseJSON.invalid() }
            if completed && !state.done { throw DeepSeekResponseJSON.invalid() }
            let item = try DeepSeekResponseJSON.object(output[index])
            guard try DeepSeekResponseJSON.string(item["id"]).utf8.elementsEqual(state.id.utf8) else { throw DeepSeekResponseJSON.invalid() }
            try validateFinalItem(item, against: state, completed: completed)
        }
    }

    private func validateFinalItem(_ item: [String: JSONValue], against state: ItemState, completed: Bool) throws {
        try validateItemStatus(
            item["status"],
            expected: state.terminalStatus?.rawValue ?? (completed ? "completed" : "incomplete")
        )
        switch state.kind {
        case .message, .reasoning:
            let expectedType = state.kind == .message ? "message" : "reasoning"
            let expectedPart: PartKind = state.kind == .message ? .outputText : .reasoningText
            guard try DeepSeekResponseJSON.string(item["type"]) == expectedType,
                  case .array(let parts) = item["content"],
                  state.parts.keys.sorted() == Array(parts.indices) else {
                throw DeepSeekResponseJSON.invalid()
            }
            if state.kind == .message, try DeepSeekResponseJSON.string(item["role"]) != "assistant" {
                throw DeepSeekResponseJSON.invalid()
            }
            for index in parts.indices {
                let part = try DeepSeekResponseJSON.object(parts[index])
                guard PartKind(rawValue: try DeepSeekResponseJSON.string(part["type"])) == expectedPart,
                      try DeepSeekResponseJSON.string(part["text"]).utf8.elementsEqual((state.parts[index]?.value ?? "").utf8) else {
                    throw DeepSeekResponseJSON.invalid()
                }
            }
        case .functionCall:
            guard try DeepSeekResponseJSON.string(item["type"]) == "function_call",
                  let call = state.call,
                  try DeepSeekResponseJSON.string(item["call_id"]).utf8.elementsEqual(call.id.rawValue.utf8),
                  try DeepSeekResponseJSON.string(item["name"]).utf8.elementsEqual(call.name.utf8),
                  try DeepSeekResponseJSON.string(item["arguments"]).utf8.elementsEqual(call.arguments.utf8) else {
                throw DeepSeekResponseJSON.invalid()
            }
        }
    }

    private func validateItemStatus(_ value: JSONValue?, expected: String) throws {
        guard let value else { return }
        guard value != .null else { throw DeepSeekResponseJSON.invalid() }
        let status = try DeepSeekResponseJSON.string(value)
        guard ["in_progress", "completed", "incomplete"].contains(status), status == expected else {
            throw DeepSeekResponseJSON.invalid()
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
        let object = try DeepSeekResponseJSON.object(value)
        let input = try DeepSeekResponseJSON.count(object["input_tokens"])
        let output = try DeepSeekResponseJSON.count(object["output_tokens"])
        let cached = try optionalCount(object["input_tokens_details"], field: "cached_tokens")
        let reasoning = try optionalCount(object["output_tokens_details"], field: "reasoning_tokens")
        usage = .init(inputTokens: input, outputTokens: output, cachedInputTokens: cached,
                      reasoningTokens: reasoning)
        return [.usage(usage)]
    }

    private func optionalCount(_ value: JSONValue?, field: String) throws -> Int? {
        guard let value, value != .null else { return nil }
        return try DeepSeekResponseJSON.count(DeepSeekResponseJSON.object(value)[field])
    }

    private func responseFailure(_ object: [String: JSONValue]) throws -> ModelProviderError {
        let response = try DeepSeekResponseJSON.object(object["response"])
        let error = try DeepSeekResponseJSON.object(response["error"])
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
        return .init(kind: kind, message: "DeepSeek generation failed with code '\(diagnostic(code))'.",
                     diagnostic: .init(stage: .server, reason: .serverFailure))
    }

    private func validateModel(_ observed: String) throws {
        guard observed.utf8.elementsEqual(responseModelName.utf8) else {
            throw ModelProviderError(
                kind: .invalidResponse,
                message: "DeepSeek returned model '\(diagnostic(observed))' but expected '\(diagnostic(responseModelName))'.",
                diagnostic: .init(stage: .responseValidation, reason: .modelMismatch)
            )
        }
    }

    private func index(_ value: JSONValue?) throws -> Int {
        guard let value = try DeepSeekResponseJSON.count(value) else { throw DeepSeekResponseJSON.invalid() }
        return value
    }

    private func optionalString(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        return try DeepSeekResponseJSON.string(value)
    }

    private func diagnostic(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.lazy
            .filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128)))
    }
}
