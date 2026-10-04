import AgentModels
import Foundation

enum ResponsesCanonicalRequestEncoder {
    typealias AssistantNativeItems = (
        _ content: [ModelContent],
        _ calls: [ToolCall]
    ) throws -> [JSONValue]?

    /// `images`: whether this adapter sends images (`input_image` data URLs). Without it an image in the
    /// request fails as an unsupported capability; a Run's image policy normally removes them first.
    static func encodeMessages(
        _ messages: [ModelMessage],
        images: Bool,
        assistantNativeItems: AssistantNativeItems? = nil
    ) throws -> [JSONValue] {
        var input: [JSONValue] = []
        for message in messages {
            switch message {
            case .system(let text):
                input.append(inputMessage(role: "system", text: text))
            case .developer(let text):
                input.append(inputMessage(role: "developer", text: text))
            case .user(let content):
                if content.contains(where: \.isImage) {
                    input.append(.object([
                        "type": .string("message"), "role": .string("user"),
                        "content": .array(try parts(content, images: images)),
                    ]))
                } else {
                    input.append(inputMessage(role: "user", text: try visibleText(content)))
                }
            case .assistant(let content, let calls):
                guard !content.contains(where: \.isImage) else { throw ImageEncoding.assistantImage() }
                if let native = try assistantNativeItems?(content, calls) {
                    input.append(contentsOf: native)
                    continue
                }
                let text = try visibleText(content)
                if !text.isEmpty {
                    input.append(inputMessage(role: "assistant", text: text))
                }
                input.append(contentsOf: try functionCalls(calls))
            case .tool(let result):
                let textual = result.content.filter { !$0.isImage }
                var output = try visibleText(textual)
                if result.isError {
                    let envelope = JSONValue.object([
                        "is_error": .bool(true),
                        "content": .string(output),
                    ])
                    output = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
                }
                let pictures = result.content.filter(\.isImage)
                let value: JSONValue = pictures.isEmpty ? .string(output) : .array(
                    (output.isEmpty ? [] : [.object(["type": .string("input_text"), "text": .string(output)])])
                        + (try parts(pictures, images: images)))
                input.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(result.callID.rawValue),
                    "output": value,
                ]))
            }
        }
        guard !input.isEmpty else {
            throw ModelProviderError(
                kind: .invalidRequest,
                message: "Conversation messages are required."
            )
        }
        return input
    }

    static func encodeTools(_ tools: [ModelToolDefinition]) -> JSONValue? {
        guard !tools.isEmpty else { return nil }
        return .array(tools.map {
            .object([
                "type": .string("function"),
                "name": .string($0.name),
                "description": .string($0.description),
                "parameters": $0.inputSchema,
                "strict": .bool(false),
            ])
        })
    }

    static func encodeStructuredOutput(_ schema: StructuredOutputSchema?) -> JSONValue? {
        guard let schema else { return nil }
        var format: [String: JSONValue] = [
            "type": .string("json_schema"),
            "name": .string(schema.name),
            "schema": schema.schema,
            "strict": .bool(schema.strict),
        ]
        if let description = schema.description {
            format["description"] = .string(description)
        }
        return .object(["format": .object(format)])
    }

    private static func inputMessage(role: String, text: String) -> JSONValue {
        .object([
            "type": .string("message"),
            "role": .string(role),
            "content": .string(text),
        ])
    }

    private static func functionCalls(_ calls: [ToolCall]) throws -> [JSONValue] {
        try calls.map { call in
            guard call.completeness == .complete,
                  (try? JSONValue.decodeToolArguments(call.argumentsJSON)) != nil,
                  !call.id.rawValue.isEmpty,
                  !call.name.isEmpty else {
                throw ModelProviderError(kind: .invalidRequest, message: "Invalid tool history.")
            }
            return .object([
                "type": .string("function_call"),
                "call_id": .string(call.id.rawValue),
                "name": .string(call.name),
                "arguments": .string(call.argumentsJSON),
            ])
        }
    }

    private static func visibleText(_ content: [ModelContent]) throws -> String {
        try content.compactMap { part -> String? in
            switch part {
            case .text(let value): return value
            case .json(let value):
                return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            case .reasoning, .providerContinuation:
                return nil
            case .image:
                throw ImageEncoding.assistantImage()
            }
        }.joined(separator: "\n")
    }

    /// Content parts in order: text as `input_text`, images as `input_image` data URLs.
    private static func parts(_ content: [ModelContent], images: Bool) throws -> [JSONValue] {
        try content.compactMap { part -> JSONValue? in
            switch part {
            case .text(let value): return .object(["type": .string("input_text"), "text": .string(value)])
            case .json(let value):
                return .object(["type": .string("input_text"),
                                "text": .string(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))])
            case .reasoning, .providerContinuation: return nil
            case .image(let image):
                guard images else { throw ImageEncoding.unsupported() }
                return .object(["type": .string("input_image"), "image_url": .string(ImageEncoding.dataURL(image))])
            }
        }
    }
}

/// Shared image rules of the adapters (ADR 0012).
enum ImageEncoding {
    static func unsupported() -> ModelProviderError {
        ModelProviderError(kind: .unsupportedCapability, message: "This adapter is not configured to send images to the model.")
    }

    static func assistantImage() -> ModelProviderError {
        ModelProviderError(kind: .invalidRequest, message: "Assistant messages cannot carry images.")
    }

    static func dataURL(_ image: ModelImage) -> String {
        "data:\(image.mediaType.rawValue);base64,\(image.data.base64EncodedString())"
    }

    /// Fails on any image in `messages`; for adapters that never send images.
    static func refuse(_ messages: [ModelMessage]) throws {
        if messages.contains(where: { !$0.images.isEmpty }) { throw unsupported() }
    }
}

extension ModelContent {
    var isImage: Bool { if case .image = self { true } else { false } }
}
