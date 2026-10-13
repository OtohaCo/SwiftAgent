import AgentModels
import Foundation

/// Accumulates bounded native parts without merging their signature-bearing boundaries.
/// Calls become executable only after a clean EOF and validated finish reason.
struct GeminiResponseDecoder {
    let request: ModelRequest
    let configuration: GeminiConfiguration
    var parts: [JSONValue] = []
    var responseID: String?
    var finishReason: String?
    var usage = ModelUsage()
    var candidateTokens: Int?
    var thoughtsTokens: Int?
    var blocked = false

    mutating func consume(_ object: [String: JSONValue]) throws {
        guard finishReason == nil && !blocked else { throw ProviderJSON.invalid() }
        if object["error"] != nil { throw ModelProviderError(kind: .invalidResponse, message: "Gemini stream failed.") }
        if let id = object["responseId"] {
            let id = try ProviderJSON.string(id); guard !id.isEmpty, responseID.map({ GeminiBoundary.exact($0, id) }) ?? true else { throw ProviderJSON.invalid() }; responseID = id
        }
        if let metadata = object["usageMetadata"] { try updateUsage(try ProviderJSON.object(metadata)) }
        if let feedback = object["promptFeedback"] {
            let feedback = try ProviderJSON.object(feedback)
            if let reason = feedback["blockReason"], reason != .string("BLOCK_REASON_UNSPECIFIED") {
                _ = try ProviderJSON.string(reason); blocked = true
            }
        }
        if let candidates = object["candidates"] {
            guard case .array(let values) = candidates, values.count <= 1 else { throw ProviderJSON.invalid() }
            for value in values {
                let candidate = try ProviderJSON.object(value)
                if let index = candidate["index"] { guard try ProviderJSON.count(index) == 0 else { throw ProviderJSON.invalid() } }
                if let content = candidate["content"] {
                    let fields = try ProviderJSON.object(content)
                    guard fields["role"] == .string("model"), case .array(let newer) = fields["parts"] else { throw ProviderJSON.invalid() }
                    // Validate shapes before retaining them. Native names checked against the declared set at seal.
                    _ = try Self.parseParts(newer, allowedNames: nil, mappings: nil)
                    parts.append(contentsOf: newer)
                }
                if let reason = candidate["finishReason"] { finishReason = try ProviderJSON.string(reason) }
            }
        }
    }
    mutating func updateUsage(_ fields: [String: JSONValue]) throws {
        func merge(_ previous: Int?, _ current: Int?) throws -> Int? {
            guard let current else { return previous }; guard previous.map({ current >= $0 }) ?? true else { throw ProviderJSON.invalid() }; return current
        }
        let input = try merge(usage.inputTokens, ProviderJSON.count(fields["promptTokenCount"]))
        let cache = try merge(usage.cachedInputTokens, ProviderJSON.count(fields["cachedContentTokenCount"]))
        candidateTokens = try merge(candidateTokens, ProviderJSON.count(fields["candidatesTokenCount"]))
        thoughtsTokens = try merge(thoughtsTokens, ProviderJSON.count(fields["thoughtsTokenCount"]))
        let output: Int?
        if let candidates = candidateTokens, let thoughts = thoughtsTokens {
            let sum = candidates.addingReportingOverflow(thoughts); guard !sum.overflow else { throw ProviderJSON.invalid() }; output = sum.partialValue
        } else { output = thoughtsTokens == nil ? candidateTokens : nil }
        if let input, let cache { guard cache <= input else { throw ProviderJSON.invalid() } }
        usage = .init(inputTokens: input, outputTokens: output, cachedInputTokens: cache, reasoningTokens: thoughtsTokens)
    }
    func finish() throws -> [ModelEvent] {
        guard blocked || finishReason != nil else { throw ProviderJSON.invalid() }
        let stop: StopReason
        switch blocked ? "SAFETY" : finishReason {
        case "STOP": stop = .endTurn
        case "MAX_TOKENS": stop = .maxOutputTokens
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII": stop = .refusal
        case nil where blocked: stop = .refusal
        default: throw ProviderJSON.invalid()
        }
        let info = ResponseInfo(id: responseID ?? UUID().uuidString, model: request.model)
        // No executable partial calls after safety/truncation. Retain visible words and usage only.
        let retainedParts = stop == .endTurn ? parts : parts.filter { $0["functionCall"] == nil }
        let parsed = try Self.parseParts(retainedParts, allowedNames: request.tools.map(\.name), mappings: nil)
        var content = parsed.content
        let calls = stop == .endTurn ? parsed.calls : []
        if configuration.profile == .requireCurrentTurnFunctionSignatures, !calls.isEmpty,
           let first = retainedParts.first(where: { $0["functionCall"] != nil }) {
            guard case .string(let signature) = first["thoughtSignature"], !signature.isEmpty else { throw GeminiBoundary.unsupported() }
        }
        var events: [ModelEvent] = [.responseStarted(info)]
        for part in content { switch part { case .text(let text): events.append(.textDelta(text)); case .reasoning(let text): events.append(.reasoningDelta(text)); default: throw ProviderJSON.invalid() } }
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
            if let signature = part["thoughtSignature"] { guard case .string(let value) = signature, !value.isEmpty, Data(base64Encoded: value) != nil else { throw ProviderJSON.invalid() } }
            if let thought = part["thought"] { guard case .bool = thought else { throw ProviderJSON.invalid() } }
            if let text = part["text"] {
                guard part["functionCall"] == nil else { throw ProviderJSON.invalid() }
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
                guard GeminiBoundary.functionName(name), allowedNames.map({ $0.contains { GeminiBoundary.exact($0, name) } }) ?? true,
                      case .object(let arguments) = fields["args"] ?? .object([:]) else { throw ProviderJSON.invalid() }
                if let native = fields["id"] { let id = try ProviderJSON.string(native); guard !id.isEmpty, nativeIDs.insert(Array(id.utf8)).inserted else { throw ProviderJSON.invalid() } }
                let id: ToolCallID
                if let mappings {
                    guard calls.count < mappings.count, mappings[calls.count].partIndex == index else { throw GeminiBoundary.unsupported() }
                    id = .init(rawValue: mappings[calls.count].canonicalID)
                } else { id = .init(rawValue: "gemini-" + UUID().uuidString) }
                guard !id.rawValue.isEmpty, canonicalIDs.insert(id).inserted else { throw ProviderJSON.invalid() }
                calls.append(.init(id: id, name: name, argumentsJSON: try ProviderJSON.text(JSONValue.object(arguments)), completeness: .complete))
                mapping.append(.init(canonicalID: id.rawValue, partIndex: index))
            } else { throw ProviderJSON.invalid() }
        }
        if let mappings { guard mappings.count == mapping.count else { throw GeminiBoundary.unsupported() } }
        return (content, calls, mapping)
    }
}
