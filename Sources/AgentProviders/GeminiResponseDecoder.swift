import AgentModels
import Foundation

/// Accumulates bounded native parts without merging their signature-bearing boundaries.
/// Calls become executable only after a clean EOF and validated finish reason.
struct GeminiResponseDecoder {
    let request: ModelRequest
    let configuration: GeminiConfiguration
    var parts: [JSONValue] = []
    var responseID: String?
    var info: ResponseInfo?
    var finishReason: String?
    var usage = ModelUsage()
    var candidateTokens: Int?
    var thoughtsTokens: Int?
    var cachedTokens: Int?
    var blocked = false

    @discardableResult
    mutating func consume(_ object: [String: JSONValue]) throws -> [ModelEvent] {
        if let error = object["error"] { throw GeminiFailure.stream(error) }
        if let id = object["responseId"] {
            let id = try ProviderJSON.string(id); guard !id.isEmpty, responseID.map({ GeminiBoundary.exact($0, id) }) ?? true else { throw GeminiShape.invalid("response id empty or changed") }; responseID = id
        }
        guard finishReason == nil && !blocked else {
            guard object["candidates"] == nil, object["promptFeedback"] == nil, let metadata = object["usageMetadata"] else { throw GeminiShape.invalid("data after the finish reason") }
            try updateUsage(ProviderJSON.object(metadata)); return []
        }
        var events: [ModelEvent] = []

        if info == nil {
            info = .init(id: responseID ?? UUID().uuidString, model: request.model)
            events.append(.responseStarted(info!))
        }
        if let metadata = object["usageMetadata"] { try updateUsage(try ProviderJSON.object(metadata)) }
        if let feedback = object["promptFeedback"] {
            let feedback = try ProviderJSON.object(feedback)
            if let reason = feedback["blockReason"], reason != .string("BLOCK_REASON_UNSPECIFIED") {
                _ = try ProviderJSON.string(reason); blocked = true
            }
        }
        if let candidates = object["candidates"] {
            guard case .array(let values) = candidates, values.count <= 1 else { throw GeminiShape.invalid("candidates not one array") }
            for value in values {
                let candidate = try ProviderJSON.object(value)
                if let index = candidate["index"] { guard try ProviderJSON.count(index) == 0 else { throw GeminiShape.invalid("candidate index not zero") } }
                if let content = candidate["content"] {
                    let fields = try ProviderJSON.object(content)
                    guard fields["role"] == .string("model") else { throw GeminiShape.invalid("content role is not model") }
                    guard case .array(let newer) = fields["parts"] else { throw GeminiShape.invalid("content has no parts") }
                    // Validate shapes before retaining them. Native names checked against the declared set at seal.
                    _ = try Self.parseParts(newer, allowedNames: nil, mappings: nil)
                    for part in newer {
                        if case .string(let text) = part["text"], !text.isEmpty {
                            events.append(part["thought"] == .bool(true) ? .reasoningDelta(text) : .textDelta(text))
                        }
                    }
                    parts.append(contentsOf: newer)
                }
                if let reason = candidate["finishReason"] { finishReason = try ProviderJSON.string(reason) }
            }
        }
        return events
    }
    mutating func updateUsage(_ fields: [String: JSONValue]) throws {
        func merge(_ previous: Int?, _ current: Int?) throws -> Int? {
            guard let current else { return previous }; guard previous.map({ current >= $0 }) ?? true else { throw GeminiShape.invalid("token count decreased") }; return current
        }
        let input = try merge(usage.inputTokens, ProviderJSON.count(fields["promptTokenCount"]))
        // Reported as received (a count never goes down); held to the prompt count where it is used.
        cachedTokens = try merge(cachedTokens, ProviderJSON.count(fields["cachedContentTokenCount"]))
        candidateTokens = try merge(candidateTokens, ProviderJSON.count(fields["candidatesTokenCount"]))
        thoughtsTokens = try merge(thoughtsTokens, ProviderJSON.count(fields["thoughtsTokenCount"]))
        let output: Int?
        if let candidates = candidateTokens, let thoughts = thoughtsTokens {
            let sum = candidates.addingReportingOverflow(thoughts); guard !sum.overflow else { throw GeminiShape.invalid("token count overflow") }; output = sum.partialValue
        } else { output = thoughtsTokens == nil ? candidateTokens : nil }
        // A service may count cached tokens from an earlier, larger request, so the cached count can exceed the prompt count.
        // The reply is still real: the cached part cannot be more than the prompt, and is kept to it.
        let cache = cachedTokens.map { cached in input.map { min(cached, $0) } ?? cached }
        usage = .init(inputTokens: input, outputTokens: output, cachedInputTokens: cache, reasoningTokens: thoughtsTokens)
    }
    func finish() throws -> [ModelEvent] {
        guard blocked || finishReason != nil else { throw ProviderHTTPFailure.streamEndedEarly() }
        let stop: StopReason
        switch blocked ? "SAFETY" : finishReason {
        case "STOP": stop = .endTurn
        case "MAX_TOKENS": stop = .maxOutputTokens
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII": stop = .refusal
        case nil where blocked: stop = .refusal
        case "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL", "OTHER", "LANGUAGE":
            stop = .unknown(finishReason!)
        default: throw GeminiShape.invalid("unknown finish reason " + GeminiShape.label(finishReason))
        }
        guard let info else { throw GeminiShape.invalid("no response started") }
        // No executable calls after safety, truncation, or a diagnostic finish reason. Retain visible words and usage only.
        let retainedParts = stop == .endTurn ? parts : parts.filter { $0["functionCall"] == nil }
        let parsed = try Self.parseParts(retainedParts, allowedNames: request.tools.map(\.name), mappings: nil)
        var content = parsed.content
        let calls = stop == .endTurn ? parsed.calls : []
        if configuration.profile == .requireCurrentTurnFunctionSignatures, !calls.isEmpty,
           let first = retainedParts.first(where: { $0["functionCall"] != nil }) {
            guard case .string(let signature) = first["thoughtSignature"], !signature.isEmpty else { throw GeminiBoundary.unsupported() }
        }
        var events: [ModelEvent] = []
        for call in calls {
            events.append(.toolCallStarted(call.id, name: call.name)); events.append(.toolCallArgumentsDelta(call.id, call.argumentsJSON)); events.append(.toolCallCompleted(call))
        }
        // A truncated response does not become a continuation authorizing a future tool result.
        if stop == .endTurn, !retainedParts.isEmpty {
            let state = GeminiNativeState(endpoint: configuration.endpointScope, parts: retainedParts, calls: parsed.mappings)
            let continuation = ModelProviderContinuation(model: request.model, format: GeminiNativeState.format, payload: try ProviderJSON.encode(state))
            content.append(.providerContinuation(continuation)); events.append(.providerContinuation(continuation))
        }
        events.append(.usage(usage))
        events.append(.responseCompleted(.init(info: info, content: content, toolCalls: calls, usage: usage,
            stopReason: calls.isEmpty ? stop : .toolCalls)))
        return events
    }
    static func parseParts(_ parts: [JSONValue], allowedNames: [String]?, mappings: [GeminiNativeCall]?) throws -> (content: [ModelContent], calls: [ToolCall], mappings: [GeminiNativeCall]) {
        var content: [ModelContent] = [], calls: [ToolCall] = [], mapping: [GeminiNativeCall] = [], nativeIDs: Set<[UInt8]> = [], canonicalIDs: Set<ToolCallID> = []
        for (index, value) in parts.enumerated() {
            let part = try ProviderJSON.object(value)
            guard Set(part.keys).isSubset(of: ["text", "thought", "thoughtSignature", "functionCall"]) else { throw GeminiBoundary.unsupported() }
            if let signature = part["thoughtSignature"] { guard case .string(let value) = signature, !value.isEmpty, Data(base64Encoded: value) != nil else { throw GeminiShape.invalid("part signature is not base64 text") } }
            if let thought = part["thought"] { guard case .bool = thought else { throw GeminiShape.invalid("part thought flag is not a boolean") } }
            if let text = part["text"] {
                guard part["functionCall"] == nil else { throw GeminiShape.invalid("part has both text and a function call") }
                let text = try ProviderJSON.string(text)
                // Empty signature-only parts stay in opaque parts, not visible text.
                if !text.isEmpty {
                    let reasoning = part["thought"] == .bool(true)
                    if reasoning, case .reasoning(let previous) = content.last { content[content.count - 1] = .reasoning(previous + text) }
                    else if !reasoning, case .text(let previous) = content.last { content[content.count - 1] = .text(previous + text) }
                    else { content.append(reasoning ? .reasoning(text) : .text(text)) }
                }
            } else if let function = part["functionCall"] {
                let fields = try ProviderJSON.object(function)
                guard Set(fields.keys).isSubset(of: ["name", "args", "id"]), part["thought"] != .bool(true) else { throw GeminiBoundary.unsupported() }
                let name = try ProviderJSON.string(fields["name"])
                guard GeminiBoundary.functionName(name) else { throw GeminiShape.invalid("function call name is not a valid name") }
                guard allowedNames.map({ $0.contains { GeminiBoundary.exact($0, name) } }) ?? true else { throw GeminiShape.invalid("function call to a tool that was not offered") }
                guard case .object(let arguments) = fields["args"] ?? .object([:]) else { throw GeminiShape.invalid("function call arguments are not an object") }
                if let native = fields["id"] { let id = try ProviderJSON.string(native); guard !id.isEmpty, nativeIDs.insert(Array(id.utf8)).inserted else { throw GeminiShape.invalid("function call id empty or repeated") } }
                let id: ToolCallID
                if let mappings {
                    guard calls.count < mappings.count, mappings[calls.count].partIndex == index else { throw GeminiBoundary.unsupported() }
                    id = .init(rawValue: mappings[calls.count].canonicalID)
                } else { id = .init(rawValue: "gemini-" + UUID().uuidString) }
                guard !id.rawValue.isEmpty, canonicalIDs.insert(id).inserted else { throw GeminiShape.invalid("function call id empty or repeated") }
                calls.append(.init(id: id, name: name, argumentsJSON: try ProviderJSON.text(JSONValue.object(arguments)), completeness: .complete))
                mapping.append(.init(canonicalID: id.rawValue, partIndex: index))
            } else { throw GeminiShape.invalid("part has neither text nor a function call (fields: " + GeminiShape.fieldNames(part) + ")") }
        }
        if let mappings { guard mappings.count == mapping.count else { throw GeminiBoundary.unsupported() } }
        return (content, calls, mapping)
    }
}

/// Shape failures name the rule that failed and, at most, a finish reason's fixed code or part field names.
/// Never message text, arguments or other response content.
enum GeminiShape {
    static func invalid(_ rule: String) -> ModelProviderError {
        .init(kind: .invalidResponse, message: "Invalid Gemini response: " + rule + ".",
              diagnostic: .init(stage: .responseDecoding, reason: .invalidShape))
    }
    /// A finish reason is a short upper-case code; anything else is not echoed.
    static func label(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.utf8.count <= 64,
              value.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) || $0 == 95 }) else { return "(unrecognized)" }
        return value
    }
    /// Field names are the wire's own identifiers; limit to plain camel-case words so odd names are not echoed.
    static func fieldNames(_ part: [String: JSONValue]) -> String {
        let names = part.keys.sorted().map { name in
            name.utf8.count <= 32 && name.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }) ? name : "(other)"
        }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}
