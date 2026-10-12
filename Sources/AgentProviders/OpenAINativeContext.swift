import AgentModels
import Foundation

// Standalone output is an input window, not an assistant-only continuation.
enum OpenAINativeContext {
    static let standaloneFormat = "openai.responses.compact.v1"
    static func window(_ checkpoint: ModelNativeContextCheckpoint, model: ModelID) throws -> [JSONValue] {
        let state = checkpoint.continuation
        guard state.model == model, state.contextTransition == checkpoint.transition else { throw ProviderJSON.invalid() }
        let object = try ProviderJSON.object(try JSONDecoder().decode(JSONValue.self, from: state.payload))
        let items: [JSONValue]
        switch checkpoint.transition.mode {
        case .openAIStandalone:
            guard state.format == standaloneFormat, object["object"] == .string("response.compaction"),
                  case .array(let output) = object["output"] else { throw ProviderJSON.invalid() }
            items = output
        case .openAIAutomatic:
            guard state.format == OpenAIResponsesContinuation.format,
                  case .array(let output) = object["items"],
                  let latest = output.lastIndex(where: { $0["type"] == .string("compaction") }),
                  latest == checkpoint.transition.replayPosition else { throw ProviderJSON.invalid() }
            items = Array(output.dropFirst(latest))
        default: throw ModelProviderError(kind: .unsupportedCapability, message: "An incompatible provider native window cannot be replayed.")
        }
        try NativeContextWire.validateOpenAIWindow(items, requiresClosedCalls: checkpoint.transition.mode == .openAIStandalone)
        return items
    }
    static func input(_ request: ModelRequest) throws -> [JSONValue] {
        // Native transitions are accepted only through the published checkpoint envelope.
        // A caller cannot reintroduce a candidate through ordinary canonical messages.
        for message in request.messages {
            if case .assistant(let content, _) = message,
               content.contains(where: { if case .providerContinuation(let state) = $0 { state.contextTransition != nil } else { false } }) {
                throw ModelProviderError(kind: .unsupportedCapability, message: "Native transition replay requires its published context checkpoint.")
            }
        }
        let messages = request.messages
        let leading = messages.prefix { $0.role == .system || $0.role == .developer }.count
        func encode(_ messages: [ModelMessage]) throws -> [JSONValue] {
            if messages.isEmpty { return [] }
            return try ResponsesCanonicalRequestEncoder.encodeMessages(messages, images: true) { content, calls in
                try OpenAIResponsesContinuation.restore(content: content, calls: calls, model: request.model)?.items
            }
        }
        let root = try encode(Array(messages.prefix(leading)))
        let native = try request.nativeContext.map { try window($0, model: request.model) } ?? []
        let tail = try encode(Array(messages.dropFirst(leading)))
        let input = root + native + tail
        guard !input.isEmpty else { throw ModelProviderError(kind: .invalidRequest, message: "Conversation input is required.") }
        return input
    }
    static func standalone(_ request: ModelRequest, promptCacheKey: String?) throws -> JSONValue {
        guard request.model.provider == "openai", !request.model.name.isEmpty else { throw ProviderJSON.invalid() }
        var body: [String: JSONValue] = ["model": .string(request.model.name), "input": .array(try input(request))]
        if let promptCacheKey { body["prompt_cache_key"] = .string(promptCacheKey) }
        // Only /compact fields. Generation tools/reasoning/schema/stream/output limits
        // are intentionally absent; returned user messages remain part of the full window.
        return .object(body)
    }
    static func response(_ object: JSONValue, request: ModelCompactionRequest) throws -> ModelCompactionResponse {
        let response = try ProviderJSON.object(object)
        guard response["object"] == .string("response.compaction"),
              let created = try ProviderJSON.count(response["created_at"]), created >= 0,
              case .array(let output) = response["output"] else { throw ProviderJSON.invalid() }
        let id = try ProviderJSON.string(response["id"])
        guard !id.isEmpty else { throw ProviderJSON.invalid() }
        let usage = try NativeContextWire.usage(response["usage"])
        let info = ResponseInfo(id: id, model: request.request.model)
        guard output.contains(where: { $0["type"] == .string("compaction") }) else {
            return .init(info: info, continuation: nil, usage: usage)
        }
        try NativeContextWire.validateOpenAIWindow(output, requiresClosedCalls: true)
        guard let source = request.request.nativeContextSource else { throw ProviderJSON.invalid() }
        let transition = ModelNativeContextTransition(mode: .openAIStandalone, source: source, replayPosition: 0,
            invocationID: request.invocationID, responseID: id,
            itemID: output.last(where: { $0["type"] == .string("compaction") })?["id"].flatMap { try? ProviderJSON.string($0) })
        let state = ModelProviderContinuation(model: info.model, format: standaloneFormat,
            payload: try ProviderJSON.encode(object), contextTransition: transition)
        return .init(info: info, continuation: state, usage: usage)
    }
}
