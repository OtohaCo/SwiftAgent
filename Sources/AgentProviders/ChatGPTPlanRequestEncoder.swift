import AgentModels
import Foundation

enum ChatGPTPlanRequestEncoder {
    static let namespace = "swiftagent"
    static let continuationFormat = "openai.chatgpt-plan.responses.v1"

    static func encode(_ request: ModelRequest) throws -> Data {
        guard request.model.provider == "openai", !request.model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid ChatGPT-plan model identifier.")
        }
        guard request.nativeContext == nil, request.nativeContextSource == nil, request.conversationControls == nil else {
            throw unsupported()
        }
        guard Set(request.tools.map { Array($0.name.utf8) }).count == request.tools.count,
              request.tools.allSatisfy({ !$0.name.isEmpty }) else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid ChatGPT-plan tool declarations.")
        }
        let messages = request.messages.map { message -> ModelMessage in
            if case .system(let text) = message { return .developer(text) }
            return message
        }
        let encoded = try ResponsesCanonicalRequestEncoder.encodeMessages(messages, images: true,
            assistantNativeItems: { content, calls in try restore(content: content, calls: calls, model: request.model) })
        let input = try encoded.map { value -> JSONValue in
            guard case .object(var item) = value, item["type"] == .string("function_call") else { return value }
            if let existing = item["namespace"], existing != .string(namespace) { throw unsupported() }
            item["namespace"] = .string(namespace)
            return .object(item)
        }
        var body: [String: JSONValue] = ["model": .string(request.model.name), "input": .array(input),
                                       "store": .bool(false), "stream": .bool(true)]
        if let tools = ResponsesCanonicalRequestEncoder.encodeTools(request.tools) {
            body["tools"] = .array([.object(["type": .string("namespace"), "name": .string(namespace),
                "description": .string("Host tools declared for this request."), "tools": tools])])
        }
        if let text = ResponsesCanonicalRequestEncoder.encodeStructuredOutput(request.structuredOutput) { body["text"] = text }
        // No max_output_tokens, previous_response_id, include, native/cache controls or unsupported tuning fields.
        return try NativeContextWire.checked(.object(body))
    }

    static func restore(content: [ModelContent], calls: [ToolCall], model: ModelID) throws -> [JSONValue]? {
        var converted: [ModelContent] = []
        for part in content {
            guard case .providerContinuation(let state) = part else { converted.append(part); continue }
            guard state.model == model, state.format == continuationFormat, state.contextTransition == nil,
                  let payload = try? JSONDecoder().decode(JSONValue.self, from: state.payload),
                  case .object(let fields) = payload, case .array(let items) = fields["items"] else { throw unsupported() }
            try validateItems(items)
            // Local SDK format wrapper only; raw item payload and canonical content/call binding remain unchanged.
            converted.append(.providerContinuation(.init(model: state.model, format: OpenAIResponsesContinuation.format,
                payload: state.payload, origin: state.origin)))
        }
        return try OpenAIResponsesContinuation.restore(content: converted, calls: calls, model: model)?.items
    }

    static func validateItems(_ items: [JSONValue]) throws {
        for value in items {
            let item = try ProviderJSON.object(value)
            guard item["type"] != .string("compaction"), item["encrypted_content"] == nil || item["encrypted_content"] == .null else { throw unsupported() }
            if item["type"] == .string("function_call"), item["namespace"] != .string(namespace) { throw unsupported() }
        }
    }

    static func unsupported() -> ModelProviderError {
        .init(kind: .unsupportedCapability, message: "ChatGPT-plan native/encrypted continuation or tool namespace is unsupported.",
              diagnostic: .init(stage: .requestValidation, reason: .continuationMismatch))
    }
}
