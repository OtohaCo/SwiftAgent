import AgentModels
import Foundation

struct ResponsesStreamDecoder {
    enum ContinuationPolicy {
        case none
        case openAI
    }

    private enum ItemKind {
        case message
        case reasoning
        case functionCall
    }

    private enum PartKind: String {
        case outputText = "output_text"
        case refusal
        case reasoningText = "reasoning_text"
        case summaryText = "summary_text"
    }

    private struct TextPartState {
        let kind: PartKind
        var value = ""
        var annotations: [JSONValue] = []
        var announced = false
        var textFinalized = false
        var partDone = false

        mutating func seed(_ text: String) throws -> String {
            guard !textFinalized, !partDone else { throw ProviderJSON.invalid() }
            guard value.isEmpty else {
                guard value == text else { throw ProviderJSON.invalid() }
                return ""
            }
            value = text
            return text
        }

        mutating func announce(_ text: String) throws -> String {
            guard !announced, !textFinalized, !partDone else { throw ProviderJSON.invalid() }
            announced = true
            return try seed(text)
        }

        mutating func append(_ delta: String) throws -> String {
            guard !textFinalized, !partDone else { throw ProviderJSON.invalid() }
            value += delta
            return delta
        }

        mutating func finalizeText(_ finalText: String) throws -> String {
            guard !textFinalized, !partDone else { throw ProviderJSON.invalid() }
            guard finalText.hasPrefix(value) else { throw ProviderJSON.invalid() }
            let suffix = String(finalText.dropFirst(value.count))
            value = finalText
            textFinalized = true
            return suffix
        }

        mutating func finalizePart(_ finalText: String) throws -> String {
            guard !partDone else { throw ProviderJSON.invalid() }
            if textFinalized {
                guard value == finalText else { throw ProviderJSON.invalid() }
                partDone = true
                return ""
            }
            let suffix = try finalizeText(finalText)
            partDone = true
            return suffix
        }

        mutating func reconcileItemDone(_ finalText: String) throws -> String {
            guard finalText.hasPrefix(value) else { throw ProviderJSON.invalid() }
            if partDone {
                guard value == finalText else { throw ProviderJSON.invalid() }
                return ""
            }
            let suffix = String(finalText.dropFirst(value.count))
            value = finalText
            textFinalized = true
            partDone = true
            return suffix
        }
    }

    private struct FunctionCallState {
        let itemID: String
        let id: ToolCallID
        let name: String
        var arguments: String
        var argumentsDone = false
        var completed = false
    }

    private struct ItemState {
        let outputIndex: Int
        let itemID: String
        let kind: ItemKind
        var messageParts: [Int: TextPartState] = [:]
        var reasoningSummaryParts: [Int: TextPartState] = [:]
        var reasoningContentParts: [Int: TextPartState] = [:]
        var functionCall: FunctionCallState?
        var native: JSONValue?
        var done = false
    }

    let model: ModelID
    let responseModelName: String
    let providerLabel: String
    let continuationPolicy: ContinuationPolicy
    private var info: ResponseInfo?
    private var content: [ModelContent] = []
    private var items: [Int: ItemState] = [:]
    private var itemIDs: [String: Int] = [:]
    private var usage = ModelUsage()
    private var refusal = false
    private var ended = false
    private var lastSequenceNumber: Int?

    init(
        model: ModelID,
        responseModelName: String? = nil,
        providerLabel: String = "OpenAI",
        continuationPolicy: ContinuationPolicy = .openAI
    ) {
        self.model = model
        self.responseModelName = responseModelName ?? model.name
        self.providerLabel = providerLabel
        self.continuationPolicy = continuationPolicy
    }

    mutating func consume(_ event: ProviderSSEEvent) throws -> [ModelEvent] {
        let object = try ProviderJSON.decode(event.data)
        let type = try ProviderJSON.string(object["type"])
        if let name = event.name, !name.isEmpty, name != "message", !name.utf8.elementsEqual(type.utf8) {
            throw ProviderJSON.invalid()
        }
        try validateSequenceNumber(object)
        guard !ended else { throw ProviderJSON.invalid() }

        switch type {
        case "response.created", "response.queued", "response.in_progress":
            return try consumeLifecycle(object)
        case "error":
            let code = try optionalString(object["code"])
            throw classifyFailure(code: code)
        case "response.failed":
            let response = try ProviderJSON.object(object["response"])
            let error = try ProviderJSON.object(response["error"])
            throw classifyFailure(code: try optionalString(error["code"]))
        default:
            break
        }
        guard info != nil else { throw ProviderJSON.invalid() }

        switch type {
        case "response.output_item.added":
            return try consumeItemAdded(object)
        case "response.content_part.added":
            return try consumeContentPartAdded(object)
        case "response.reasoning_summary_part.added":
            return try consumeReasoningSummaryPartAdded(object)
        case "response.output_text.delta":
            return try consumeTextDelta(object, partKind: .outputText)
        case "response.refusal.delta":
            refusal = true
            return try consumeTextDelta(object, partKind: .refusal)
        case "response.reasoning_summary_text.delta":
            return try consumeReasoningDelta(object, summary: true)
        case "response.reasoning_text.delta":
            return try consumeReasoningDelta(object, summary: false)
        case "response.output_text.annotation.added":
            return try consumeAnnotationAdded(object)
        case "response.function_call_arguments.delta":
            return try consumeFunctionArgumentsDelta(object)
        case "response.output_text.done":
            return try consumeTextDone(object, partKind: .outputText)
        case "response.refusal.done":
            refusal = true
            return try consumeTextDone(object, partKind: .refusal)
        case "response.reasoning_summary_text.done":
            return try consumeReasoningDone(object, summary: true)
        case "response.reasoning_text.done":
            return try consumeReasoningDone(object, summary: false)
        case "response.content_part.done":
            return try consumeContentPartDone(object)
        case "response.reasoning_summary_part.done":
            return try consumeReasoningSummaryPartDone(object)
        case "response.function_call_arguments.done":
            return try consumeFunctionArgumentsDone(object)
        case "response.output_item.done":
            return try consumeItemDone(object)
        case "response.completed":
            return try consumeCompleted(object)
        case "response.incomplete":
            return try consumeIncomplete(object)
        case "response.created", "response.queued", "response.in_progress", "error", "response.failed":
            throw ProviderJSON.invalid()
        default:
            return []
        }
    }

    func finish() throws { guard ended else { throw ProviderJSON.invalid() } }

    private mutating func validateSequenceNumber(_ object: [String: JSONValue]) throws {
        guard let sequence = try ProviderJSON.count(object["sequence_number"]) else { throw ProviderJSON.invalid() }
        if let lastSequenceNumber, sequence <= lastSequenceNumber { throw ProviderJSON.invalid() }
        lastSequenceNumber = sequence
    }

    private mutating func consumeLifecycle(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let response = try ProviderJSON.object(object["response"])
        let id = try ProviderJSON.string(response["id"])
        let responseModel = try ProviderJSON.string(response["model"])
        let status = try ProviderJSON.string(response["status"])
        guard !id.isEmpty, status == "queued" || status == "in_progress" else { throw ProviderJSON.invalid() }
        try validateResponseModel(responseModel)
        if let info {
            guard info.id.utf8.elementsEqual(id.utf8) else { throw ProviderJSON.invalid() }
            return []
        }
        let value = ResponseInfo(id: id, model: model)
        info = value
        return [.responseStarted(value)]
    }

    private mutating func consumeItemAdded(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        guard items[index] == nil else { throw ProviderJSON.invalid() }
        let item = try ProviderJSON.object(object["item"])
        let itemID = try ProviderJSON.string(item["id"])
        guard !itemID.isEmpty, itemIDs[itemID] == nil else { throw ProviderJSON.invalid() }
        itemIDs[itemID] = index

        switch try ProviderJSON.string(item["type"]) {
        case "message":
            try validateItemStatus(item["status"], expected: "in_progress", required: true)
            guard try ProviderJSON.string(item["role"]) == "assistant",
                  case .array(let parts) = item["content"] else { throw ProviderJSON.invalid() }
            var state = ItemState(outputIndex: index, itemID: itemID, kind: .message)
            var events: [ModelEvent] = []
            for (partIndex, value) in parts.enumerated() {
                let part = try ProviderJSON.object(value)
                let text = try seedMessagePart(&state, index: partIndex, part: part)
                events.append(contentsOf: appendText(text))
            }
            items[index] = state
            return events
        case "reasoning":
            try validateItemStatus(item["status"], expected: "in_progress", required: false)
            guard case .array(let summary) = item["summary"] else { throw ProviderJSON.invalid() }
            var state = ItemState(outputIndex: index, itemID: itemID, kind: .reasoning)
            var events: [ModelEvent] = []
            for (partIndex, value) in summary.enumerated() {
                let part = try ProviderJSON.object(value)
                let text = try seedReasoningPart(&state, index: partIndex, summary: true, part: part)
                events.append(contentsOf: appendReasoning(text))
            }
            if let value = item["content"], value != .null {
                guard case .array(let parts) = value else { throw ProviderJSON.invalid() }
                for (partIndex, value) in parts.enumerated() {
                    let part = try ProviderJSON.object(value)
                    let text = try seedReasoningPart(&state, index: partIndex, summary: false, part: part)
                    events.append(contentsOf: appendReasoning(text))
                }
            }
            items[index] = state
            return events
        case "function_call":
            try validateItemStatus(item["status"], expected: "in_progress", required: false)
            let callID = ToolCallID(rawValue: try ProviderJSON.string(item["call_id"]))
            let name = try ProviderJSON.string(item["name"])
            let arguments = try ProviderJSON.string(item["arguments"])
            guard !callID.rawValue.isEmpty, !name.isEmpty else { throw ProviderJSON.invalid() }
            let state = ItemState(
                outputIndex: index, itemID: itemID, kind: .functionCall,
                functionCall: .init(itemID: itemID, id: callID, name: name, arguments: arguments)
            )
            items[index] = state
            var events: [ModelEvent] = [.toolCallStarted(callID, name: name)]
            if !arguments.isEmpty { events.append(.toolCallArgumentsDelta(callID, arguments)) }
            return events
        case "web_search_call", "file_search_call", "code_interpreter_call", "mcp_call", "computer_call",
             "local_shell_call", "shell_call", "apply_patch_call", "custom_tool_call":
            throw ModelProviderError(kind: .unsupportedCapability,
                                     message: "Provider-hosted tools are not supported by this adapter.")
        default:
            throw ModelProviderError(kind: .unsupportedCapability,
                                     message: "\(providerLabel) returned an unsupported output item type.")
        }
    }

    private mutating func consumeContentPartAdded(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        let contentIndex = try requiredIndex(object["content_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[index], state.itemID == itemID, !state.done else { throw ProviderJSON.invalid() }
        let part = try ProviderJSON.object(object["part"])

        switch state.kind {
        case .message:
            let text = try announceMessagePart(&state, index: contentIndex, part: part)
            items[index] = state
            return appendText(text)
        case .reasoning:
            let text = try announceReasoningPart(&state, index: contentIndex, summary: false, part: part)
            items[index] = state
            return appendReasoning(text)
        case .functionCall:
            throw ProviderJSON.invalid()
        }
    }

    private mutating func consumeReasoningSummaryPartAdded(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        let summaryIndex = try requiredIndex(object["summary_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[index], state.itemID == itemID, state.kind == .reasoning, !state.done else {
            throw ProviderJSON.invalid()
        }
        let part = try ProviderJSON.object(object["part"])
        let text = try announceReasoningPart(&state, index: summaryIndex, summary: true, part: part)
        items[index] = state
        return appendReasoning(text)
    }

    private mutating func consumeTextDelta(_ object: [String: JSONValue], partKind: PartKind) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        let contentIndex = try requiredIndex(object["content_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[index], state.itemID == itemID, state.kind == .message, !state.done,
              var part = state.messageParts[contentIndex], part.kind == partKind else { throw ProviderJSON.invalid() }
        let delta = try ProviderJSON.string(object["delta"])
        let appended = try part.append(delta)
        state.messageParts[contentIndex] = part
        items[index] = state
        return appendText(appended)
    }

    private mutating func consumeReasoningDelta(_ object: [String: JSONValue], summary: Bool) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        let partIndex = try requiredIndex(object[summary ? "summary_index" : "content_index"])
        guard var state = items[index], state.itemID == itemID, state.kind == .reasoning, !state.done else {
            throw ProviderJSON.invalid()
        }
        let keyPath = summary ? \ItemState.reasoningSummaryParts : \ItemState.reasoningContentParts
        guard var part = state[keyPath: keyPath][partIndex] else { throw ProviderJSON.invalid() }
        let appended = try part.append(try ProviderJSON.string(object["delta"]))
        state[keyPath: keyPath][partIndex] = part
        items[index] = state
        return appendReasoning(appended)
    }

    private mutating func consumeAnnotationAdded(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        let contentIndex = try requiredIndex(object["content_index"])
        let annotationIndex = try requiredIndex(object["annotation_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[index], state.itemID == itemID, state.kind == .message, !state.done,
              var part = state.messageParts[contentIndex], part.kind == .outputText,
              !part.textFinalized, !part.partDone else {
            throw ProviderJSON.invalid()
        }
        guard let annotation = object["annotation"], annotation != .null else { return [] }
        _ = try ProviderJSON.object(annotation)
        guard annotationIndex == part.annotations.count else { throw ProviderJSON.invalid() }
        part.annotations.append(annotation)
        state.messageParts[contentIndex] = part
        items[index] = state
        return []
    }

    private mutating func consumeFunctionArgumentsDelta(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[index], state.itemID == itemID, state.kind == .functionCall, !state.done,
              var call = state.functionCall, !call.argumentsDone, !call.completed else { throw ProviderJSON.invalid() }
        let delta = try ProviderJSON.string(object["delta"])
        call.arguments += delta
        state.functionCall = call
        items[index] = state
        return delta.isEmpty ? [] : [.toolCallArgumentsDelta(call.id, delta)]
    }

    private mutating func consumeTextDone(_ object: [String: JSONValue], partKind: PartKind) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        let contentIndex = try requiredIndex(object["content_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[index], state.itemID == itemID, state.kind == .message, !state.done,
              var part = state.messageParts[contentIndex], part.kind == partKind else { throw ProviderJSON.invalid() }
        let final = partKind == .outputText
            ? try ProviderJSON.string(object["text"])
            : try ProviderJSON.string(object["refusal"])
        let appended = try part.finalizeText(final)
        state.messageParts[contentIndex] = part
        items[index] = state
        return appendText(appended)
    }

    private mutating func consumeReasoningDone(_ object: [String: JSONValue], summary: Bool) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        let partIndex = try requiredIndex(object[summary ? "summary_index" : "content_index"])
        guard var state = items[index], state.itemID == itemID, state.kind == .reasoning, !state.done else {
            throw ProviderJSON.invalid()
        }
        let keyPath = summary ? \ItemState.reasoningSummaryParts : \ItemState.reasoningContentParts
        guard var part = state[keyPath: keyPath][partIndex] else { throw ProviderJSON.invalid() }
        let appended = try part.finalizeText(try ProviderJSON.string(object["text"]))
        state[keyPath: keyPath][partIndex] = part
        items[index] = state
        return appendReasoning(appended)
    }

    private mutating func consumeContentPartDone(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        let contentIndex = try requiredIndex(object["content_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[index], state.itemID == itemID, !state.done else { throw ProviderJSON.invalid() }
        let part = try ProviderJSON.object(object["part"])
        switch state.kind {
        case .message:
            let kind = try partKind(part)
            guard kind == .outputText || kind == .refusal,
                  var statePart = state.messageParts[contentIndex], statePart.kind == kind else {
                throw ProviderJSON.invalid()
            }
            if kind == .outputText {
                try validateAnnotations(part, against: statePart.annotations)
            }
            let final = kind == .outputText
                ? try ProviderJSON.string(part["text"])
                : try ProviderJSON.string(part["refusal"])
            let appended = try statePart.finalizePart(final)
            state.messageParts[contentIndex] = statePart
            items[index] = state
            return appendText(appended)
        case .reasoning:
            guard try partKind(part) == .reasoningText,
                  var statePart = state.reasoningContentParts[contentIndex] else { throw ProviderJSON.invalid() }
            let appended = try statePart.finalizePart(try ProviderJSON.string(part["text"]))
            state.reasoningContentParts[contentIndex] = statePart
            items[index] = state
            return appendReasoning(appended)
        case .functionCall:
            throw ProviderJSON.invalid()
        }
    }

    private mutating func consumeReasoningSummaryPartDone(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        let summaryIndex = try requiredIndex(object["summary_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[index], state.itemID == itemID, state.kind == .reasoning, !state.done,
              var part = state.reasoningSummaryParts[summaryIndex] else { throw ProviderJSON.invalid() }
        let value = try ProviderJSON.object(object["part"])
        guard try partKind(value) == .summaryText else { throw ProviderJSON.invalid() }
        let appended = try part.finalizePart(try ProviderJSON.string(value["text"]))
        state.reasoningSummaryParts[summaryIndex] = part
        items[index] = state
        return appendReasoning(appended)
    }

    private mutating func consumeFunctionArgumentsDone(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        let itemID = try ProviderJSON.string(object["item_id"])
        guard var state = items[index], state.itemID == itemID, state.kind == .functionCall, !state.done,
              var call = state.functionCall, !call.argumentsDone, !call.completed else { throw ProviderJSON.invalid() }
        let final = try ProviderJSON.string(object["arguments"])
        guard final.hasPrefix(call.arguments) else { throw ProviderJSON.invalid() }
        let suffix = String(final.dropFirst(call.arguments.count))
        call.arguments = final
        call.argumentsDone = true
        state.functionCall = call
        items[index] = state
        return suffix.isEmpty ? [] : [.toolCallArgumentsDelta(call.id, suffix)]
    }

    private mutating func consumeItemDone(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let index = try requiredIndex(object["output_index"])
        guard var state = items[index], !state.done else { throw ProviderJSON.invalid() }
        let item = try ProviderJSON.object(object["item"])
        guard try ProviderJSON.string(item["id"]) == state.itemID else { throw ProviderJSON.invalid() }

        var events: [ModelEvent] = []
        switch state.kind {
        case .message:
            try validateItemStatus(item["status"], expected: "completed", required: true)
            guard try ProviderJSON.string(item["type"]) == "message",
                  try ProviderJSON.string(item["role"]) == "assistant",
                  case .array(let parts) = item["content"] else { throw ProviderJSON.invalid() }
            guard state.messageParts.keys.sorted() == Array(parts.indices) else { throw ProviderJSON.invalid() }
            for partIndex in parts.indices {
                let part = try ProviderJSON.object(parts[partIndex])
                let kind = try partKind(part)
                guard kind == .outputText || kind == .refusal,
                      var statePart = state.messageParts[partIndex], statePart.kind == kind else {
                    throw ProviderJSON.invalid()
                }
                if kind == .outputText { try validateAnnotations(part, against: statePart.annotations) }
                let final = kind == .outputText
                    ? try ProviderJSON.string(part["text"])
                    : try ProviderJSON.string(part["refusal"])
                let appended = try statePart.reconcileItemDone(final)
                state.messageParts[partIndex] = statePart
                events.append(contentsOf: appendText(appended))
            }
            if state.messageParts.isEmpty, !parts.isEmpty { throw ProviderJSON.invalid() }
        case .reasoning:
            try validateItemStatus(item["status"], expected: "completed", required: false)
            guard try ProviderJSON.string(item["type"]) == "reasoning",
                  case .array(let summary) = item["summary"] else { throw ProviderJSON.invalid() }
            try reconcileReasoningParts(&state, values: summary, summary: true, events: &events)
            if let value = item["content"], value != .null {
                guard case .array(let parts) = value else { throw ProviderJSON.invalid() }
                try reconcileReasoningParts(&state, values: parts, summary: false, events: &events)
            } else if !state.reasoningContentParts.isEmpty {
                throw ProviderJSON.invalid()
            }
            if let encrypted = item["encrypted_content"], encrypted != .null,
               try ProviderJSON.string(encrypted).isEmpty {
                throw ProviderJSON.invalid()
            }
        case .functionCall:
            try validateItemStatus(item["status"], expected: "completed", required: false)
            guard try ProviderJSON.string(item["type"]) == "function_call",
                  var call = state.functionCall,
                  call.argumentsDone,
                  try ProviderJSON.string(item["call_id"]) == call.id.rawValue,
                  try ProviderJSON.string(item["name"]) == call.name else { throw ProviderJSON.invalid() }
            let final = try ProviderJSON.string(item["arguments"])
            guard final == call.arguments,
                  (try? JSONValue.decodeToolArguments(final)) != nil else { throw ProviderJSON.invalid() }
            call.completed = true
            state.functionCall = call
            events.append(.toolCallCompleted(.init(id: call.id, name: call.name,
                                                   argumentsJSON: final, completeness: .complete)))
        }
        state.native = .object(item)
        state.done = true
        items[index] = state
        return events
    }

    private mutating func consumeCompleted(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let response = try ProviderJSON.object(object["response"])
        guard let info,
              try ProviderJSON.string(response["id"]) == info.id,
              try ProviderJSON.string(response["status"]) == "completed" else { throw ProviderJSON.invalid() }
        try validateResponseModel(try ProviderJSON.string(response["model"]))
        guard items.values.allSatisfy({ $0.done }),
              items.values.allSatisfy({ $0.functionCall?.completed != false }) else { throw ProviderJSON.invalid() }
        try validateFinalOutput(response["output"], requireCompleted: true)

        guard case .array(let finalOutput) = response["output"] else { throw ProviderJSON.invalid() }
        for index in finalOutput.indices {
            guard var state = items[index] else { throw ProviderJSON.invalid() }
            state.native = finalOutput[index]
            items[index] = state
        }

        let usageEvents = try updateUsage(response["usage"])
        let modelCalls = orderedCalls()
        let stop: StopReason = !modelCalls.isEmpty ? .toolCalls : (refusal ? .refusal : .endTurn)
        ended = true
        var events = usageEvents
        let nativeItems = items.keys.sorted().compactMap { items[$0]?.native }
        if continuationPolicy == .openAI,
           !nativeItems.isEmpty,
           let continuation = try OpenAIResponsesContinuation.make(
               items: nativeItems, content: content, calls: modelCalls, model: model
           ) {
            content.append(.providerContinuation(continuation))
            events.append(.providerContinuation(continuation))
        }
        events.append(.responseCompleted(.init(info: info, content: content,
                                               toolCalls: modelCalls, usage: usage, stopReason: stop)))
        return events
    }

    private mutating func consumeIncomplete(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        let response = try ProviderJSON.object(object["response"])
        guard let info,
              try ProviderJSON.string(response["id"]) == info.id,
              try ProviderJSON.string(response["status"]) == "incomplete" else { throw ProviderJSON.invalid() }
        try validateResponseModel(try ProviderJSON.string(response["model"]))
        try validateFinalOutput(response["output"], requireCompleted: false)
        let usageEvents = try updateUsage(response["usage"])
        let details = try ProviderJSON.object(response["incomplete_details"])
        let reason = try ProviderJSON.string(details["reason"])
        let stop: StopReason = reason == "max_output_tokens" ? .maxOutputTokens :
            (reason == "content_filter" ? .refusal : .unknown(reason))
        let modelCalls = items.keys.sorted().compactMap { index -> ToolCall? in
            guard let call = items[index]?.functionCall else { return nil }
            return .init(id: call.id, name: call.name, argumentsJSON: call.arguments,
                         completeness: call.completed ? .complete : .incomplete)
        }
        ended = true
        return usageEvents + [.responseCompleted(.init(info: info, content: content,
                                                       toolCalls: modelCalls, usage: usage, stopReason: stop))]
    }

    private func seedMessagePart(
        _ state: inout ItemState,
        index: Int,
        part: [String: JSONValue]
    ) throws -> String {
        let kind = try partKind(part)
        guard kind == .outputText || kind == .refusal else { throw ProviderJSON.invalid() }
        let annotations: [JSONValue]
        if kind == .outputText {
            guard case .array(let values) = part["annotations"] else { throw ProviderJSON.invalid() }
            annotations = values
        } else {
            annotations = []
        }
        var partState = state.messageParts[index] ?? .init(kind: kind)
        guard partState.kind == kind else { throw ProviderJSON.invalid() }
        if !partState.annotations.isEmpty || !annotations.isEmpty {
            guard partState.annotations == annotations else { throw ProviderJSON.invalid() }
        }
        partState.annotations = annotations
        let text = kind == .outputText
            ? try ProviderJSON.string(part["text"])
            : try ProviderJSON.string(part["refusal"])
        let appended = try partState.seed(text)
        state.messageParts[index] = partState
        return appended
    }

    private func announceMessagePart(
        _ state: inout ItemState,
        index: Int,
        part: [String: JSONValue]
    ) throws -> String {
        let kind = try partKind(part)
        guard kind == .outputText || kind == .refusal else { throw ProviderJSON.invalid() }
        let annotations: [JSONValue]
        if kind == .outputText {
            guard case .array(let values) = part["annotations"] else { throw ProviderJSON.invalid() }
            annotations = values
        } else {
            annotations = []
        }
        var partState = state.messageParts[index] ?? .init(kind: kind)
        guard partState.kind == kind else { throw ProviderJSON.invalid() }
        if !partState.annotations.isEmpty || !annotations.isEmpty {
            guard partState.annotations == annotations else { throw ProviderJSON.invalid() }
        }
        partState.annotations = annotations
        let text = kind == .outputText
            ? try ProviderJSON.string(part["text"])
            : try ProviderJSON.string(part["refusal"])
        let appended = try partState.announce(text)
        state.messageParts[index] = partState
        return appended
    }

    private func seedReasoningPart(
        _ state: inout ItemState,
        index: Int,
        summary: Bool,
        part: [String: JSONValue]
    ) throws -> String {
        guard try partKind(part) == (summary ? .summaryText : .reasoningText) else { throw ProviderJSON.invalid() }
        let keyPath = summary ? \ItemState.reasoningSummaryParts : \ItemState.reasoningContentParts
        var partState = state[keyPath: keyPath][index] ?? .init(kind: summary ? .summaryText : .reasoningText)
        let appended = try partState.seed(try ProviderJSON.string(part["text"]))
        state[keyPath: keyPath][index] = partState
        return appended
    }

    private func announceReasoningPart(
        _ state: inout ItemState,
        index: Int,
        summary: Bool,
        part: [String: JSONValue]
    ) throws -> String {
        guard try partKind(part) == (summary ? .summaryText : .reasoningText) else { throw ProviderJSON.invalid() }
        let keyPath = summary ? \ItemState.reasoningSummaryParts : \ItemState.reasoningContentParts
        let expectedKind: PartKind = summary ? .summaryText : .reasoningText
        var partState = state[keyPath: keyPath][index] ?? .init(kind: expectedKind)
        guard partState.kind == expectedKind else { throw ProviderJSON.invalid() }
        let appended = try partState.announce(try ProviderJSON.string(part["text"]))
        state[keyPath: keyPath][index] = partState
        return appended
    }

    private mutating func reconcileReasoningParts(
        _ state: inout ItemState,
        values: [JSONValue],
        summary: Bool,
        events: inout [ModelEvent]
    ) throws {
        let keyPath = summary ? \ItemState.reasoningSummaryParts : \ItemState.reasoningContentParts
        let expectedKind: PartKind = summary ? .summaryText : .reasoningText
        guard state[keyPath: keyPath].keys.sorted() == Array(values.indices) else { throw ProviderJSON.invalid() }
        for index in values.indices {
            let part = try ProviderJSON.object(values[index])
            guard try partKind(part) == expectedKind, var statePart = state[keyPath: keyPath][index] else {
                throw ProviderJSON.invalid()
            }
            let appended = try statePart.reconcileItemDone(try ProviderJSON.string(part["text"]))
            state[keyPath: keyPath][index] = statePart
            events.append(contentsOf: appendReasoning(appended))
        }
    }

    private func validateFinalOutput(_ value: JSONValue?, requireCompleted: Bool) throws {
        guard case .array(let output) = value,
              output.count == items.count,
              items.keys.sorted() == Array(output.indices) else { throw ProviderJSON.invalid() }
        for index in output.indices {
            guard let state = items[index] else { throw ProviderJSON.invalid() }
            if requireCompleted && !state.done { throw ProviderJSON.invalid() }
            let final = try ProviderJSON.object(output[index])
            guard try ProviderJSON.string(final["id"]) == state.itemID else { throw ProviderJSON.invalid() }
            try validateFinalItem(final, against: state)
        }
    }

    private func validateFinalItem(_ item: [String: JSONValue], against state: ItemState) throws {
        switch state.kind {
        case .message:
            try validateItemStatus(
                item["status"], expected: state.done ? "completed" : "incomplete", required: true
            )
            guard try ProviderJSON.string(item["type"]) == "message",
                  try ProviderJSON.string(item["role"]) == "assistant",
                  case .array(let parts) = item["content"],
                  state.messageParts.keys.sorted() == Array(parts.indices) else { throw ProviderJSON.invalid() }
            for index in parts.indices {
                let part = try ProviderJSON.object(parts[index])
                let kind = try partKind(part)
                guard kind == .outputText || kind == .refusal,
                      let statePart = state.messageParts[index], statePart.kind == kind else {
                    throw ProviderJSON.invalid()
                }
                let final = kind == .outputText
                    ? try ProviderJSON.string(part["text"])
                    : try ProviderJSON.string(part["refusal"])
                guard final == statePart.value else { throw ProviderJSON.invalid() }
                if kind == .outputText { try validateAnnotations(part, against: statePart.annotations) }
            }
        case .reasoning:
            try validateItemStatus(
                item["status"], expected: state.done ? "completed" : "incomplete", required: false
            )
            guard try ProviderJSON.string(item["type"]) == "reasoning",
                  case .array(let summary) = item["summary"],
                  state.reasoningSummaryParts.keys.sorted() == Array(summary.indices) else {
                throw ProviderJSON.invalid()
            }
            let streamedEncrypted: String?
            if let native = state.native {
                streamedEncrypted = try optionalString(ProviderJSON.object(native)["encrypted_content"])
            } else {
                streamedEncrypted = nil
            }
            let finalEncrypted = try optionalString(item["encrypted_content"])
            // OpenAI defines output_item.done as the authoritative replay item.
            // The terminal snapshot may re-encrypt the same reasoning state, but
            // it must preserve whether encrypted replay state was present.
            guard (streamedEncrypted == nil) == (finalEncrypted == nil) else {
                throw ProviderJSON.invalid()
            }
            if let finalEncrypted, finalEncrypted.isEmpty { throw ProviderJSON.invalid() }
            for index in summary.indices {
                let part = try ProviderJSON.object(summary[index])
                guard try partKind(part) == .summaryText,
                      try ProviderJSON.string(part["text"]) == state.reasoningSummaryParts[index]?.value else {
                    throw ProviderJSON.invalid()
                }
            }
            if let value = item["content"], value != .null {
                guard case .array(let parts) = value,
                      state.reasoningContentParts.keys.sorted() == Array(parts.indices) else {
                    throw ProviderJSON.invalid()
                }
                for index in parts.indices {
                    let part = try ProviderJSON.object(parts[index])
                    guard try partKind(part) == .reasoningText,
                          try ProviderJSON.string(part["text"]) == state.reasoningContentParts[index]?.value else {
                        throw ProviderJSON.invalid()
                    }
                }
            } else if !state.reasoningContentParts.isEmpty {
                throw ProviderJSON.invalid()
            }
        case .functionCall:
            try validateItemStatus(
                item["status"], expected: state.done ? "completed" : "incomplete", required: false
            )
            let final = try ProviderJSON.object(.object(item))
            guard try ProviderJSON.string(final["type"]) == "function_call",
                  let call = state.functionCall,
                  try ProviderJSON.string(final["call_id"]) == call.id.rawValue,
                  try ProviderJSON.string(final["name"]) == call.name,
                  try ProviderJSON.string(final["arguments"]) == call.arguments else { throw ProviderJSON.invalid() }
        }
    }

    private func validateItemStatus(
        _ value: JSONValue?,
        expected: String,
        required: Bool
    ) throws {
        guard let value else {
            if required { throw ProviderJSON.invalid() }
            return
        }
        guard value != .null else {
            if required { throw ProviderJSON.invalid() }
            return
        }
        let status = try ProviderJSON.string(value)
        guard ["in_progress", "completed", "incomplete"].contains(status), status == expected else {
            throw ProviderJSON.invalid()
        }
    }

    private func orderedCalls() -> [ToolCall] {
        items.keys.sorted().compactMap { index -> ToolCall? in
            guard let call = items[index]?.functionCall else { return nil }
            return .init(id: call.id, name: call.name, argumentsJSON: call.arguments, completeness: .complete)
        }
    }

    private mutating func appendText(_ delta: String) -> [ModelEvent] {
        guard !delta.isEmpty else { return [] }
        if case .text(let previous) = content.last {
            content[content.count - 1] = .text(previous + delta)
        } else {
            content.append(.text(delta))
        }
        return [.textDelta(delta)]
    }

    private mutating func appendReasoning(_ delta: String) -> [ModelEvent] {
        guard !delta.isEmpty else { return [] }
        if case .reasoning(let previous) = content.last {
            content[content.count - 1] = .reasoning(previous + delta)
        } else {
            content.append(.reasoning(delta))
        }
        return [.reasoningDelta(delta)]
    }

    private func requiredIndex(_ value: JSONValue?) throws -> Int {
        guard let value = try ProviderJSON.count(value) else { throw ProviderJSON.invalid() }
        return value
    }

    private func partKind(_ part: [String: JSONValue]) throws -> PartKind {
        guard let kind = PartKind(rawValue: try ProviderJSON.string(part["type"])) else { throw ProviderJSON.invalid() }
        return kind
    }

    private func validateAnnotations(_ part: [String: JSONValue], against expected: [JSONValue]) throws {
        guard case .array(let annotations) = part["annotations"], annotations == expected else {
            throw ProviderJSON.invalid()
        }
    }

    private mutating func updateUsage(_ value: JSONValue?) throws -> [ModelEvent] {
        guard let value, value != .null else { return [] }
        let object = try ProviderJSON.object(value)
        let input = try ProviderJSON.count(object["input_tokens"])
        let output = try ProviderJSON.count(object["output_tokens"])
        var cached: Int?
        if let details = object["input_tokens_details"], details != .null {
            cached = try ProviderJSON.count(ProviderJSON.object(details)["cached_tokens"])
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
                message: "\(providerLabel) returned model '\(diagnostic(observed))' but expected '\(diagnostic(responseModelName))'."
            )
        }
    }

    private func classifyFailure(code: String?) -> ModelProviderError {
        let code = code ?? ""
        let kind: ModelProviderError.Kind
        switch code {
        case "rate_limit_exceeded": kind = .rateLimited
        case "server_error", "vector_store_timeout": kind = .unavailable
        case "invalid_prompt", "invalid_request_error", "data_residency_mismatch", "bio_policy",
             "misalignment_policy_violation": kind = .invalidRequest
        case "insufficient_quota": kind = .permissionDenied
        default: kind = .invalidResponse
        }
        return .init(kind: kind, message: "\(providerLabel) generation failed with code '\(diagnostic(code))'.")
    }

    private func optionalString(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        return try ProviderJSON.string(value)
    }

    private func diagnostic(_ value: String) -> String {
        let filtered = value.unicodeScalars.lazy.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128)
        return String(String.UnicodeScalarView(filtered))
    }
}

typealias OpenAIResponsesStreamDecoder = ResponsesStreamDecoder
