import AgentModels
import Foundation

struct GeminiNativeCall: Codable, Sendable { let canonicalID: String; let partIndex: Int }
struct GeminiNativeState: Codable, Sendable {
    static let format = "gemini-generate-content-parts-v1"
    let endpoint: String
    let parts: [JSONValue]
    let calls: [GeminiNativeCall]
}
struct GeminiEncodedContext: Sendable { let contents: [JSONValue]; let system: JSONValue?; let tools: JSONValue? }

enum GeminiRequestEncoder {
    static func context(_ request: ModelRequest, configuration: GeminiConfiguration) throws -> GeminiEncodedContext {
        _ = try configuration.endpoint(model: request.model)
        guard request.nativeContext == nil, request.conversationControls == nil else { throw GeminiBoundary.unsupported() }
        var system: [JSONValue] = [], contents: [JSONValue] = [], pending: [(ToolCall, JSONValue)] = []
        var results: [ToolCallID: JSONValue] = [:], seenCalls: Set<ToolCallID> = []
        let currentTurn = request.messages.lastIndex { if case .user = $0 { return true }; return false } ?? 0
        func flushResults() throws {
            guard !pending.isEmpty else { return }
            guard pending.count == results.count else { throw GeminiBoundary.invalidRequest() }
            contents.append(.object(["role": .string("user"), "parts": .array(try pending.map {
                guard let value = results[$0.0.id] else { throw GeminiBoundary.invalidRequest() }; return value
            })]))
            pending.removeAll(); results.removeAll()
        }
        for (messageIndex, message) in request.messages.enumerated() {
            if case .tool(let result) = message {
                guard let (_, native) = pending.first(where: { $0.0.id == result.callID }), results[result.callID] == nil else { throw GeminiBoundary.invalidRequest() }
                var output: [JSONValue] = [], images: [JSONValue] = []
                for content in result.content {
                    switch content {
                    case .text(let text): output.append(.string(text))
                    case .json(let value): output.append(value)
                    case .image(let image): images.append(try imagePart(image))
                    default: throw GeminiBoundary.unsupported()
                    }
                }
                var response: [String: JSONValue] = ["name": try ProviderJSON.object(native)["name"]!,
                    "response": .object([result.isError ? "error" : "output": output.count == 1 ? output[0] : .array(output)])]
                if let id = native["id"] { response["id"] = id }
                if !images.isEmpty { response["parts"] = .array(images) }
                results[result.callID] = .object(["functionResponse": .object(response)])
                continue
            }
            try flushResults()
            switch message {
            case .system(let text), .developer(let text): system.append(.object(["text": .string(text)]))
            case .user(let parts):
                let encoded = try parts.map(userPart)
                guard !encoded.isEmpty else { throw GeminiBoundary.invalidRequest() }
                contents.append(.object(["role": .string("user"), "parts": .array(encoded)]))
            case .assistant(let visible, let calls):
                let states = visible.compactMap { if case .providerContinuation(let s) = $0 { return s }; return nil }
                let parts: [JSONValue]
                if !states.isEmpty {
                    guard states.count == 1, states[0].format == GeminiNativeState.format, states[0].model == request.model,
                          states[0].contextTransition == nil, states[0].requestBoundary == nil,
                          let state = try? JSONDecoder().decode(GeminiNativeState.self, from: states[0].payload),
                          GeminiBoundary.exact(state.endpoint, configuration.endpointScope) else { throw GeminiBoundary.unsupported() }
                    try validate(state: state, content: visible, calls: calls)
                    parts = state.parts
                    for (call, mapping) in zip(calls, state.calls) { pending.append((call, try ProviderJSON.object(parts[mapping.partIndex])["functionCall"]!)) }
                } else {
                    guard visible.allSatisfy({ if case .text = $0 { return true }; if case .json = $0 { return true }; return false }), calls.isEmpty else { throw GeminiBoundary.unsupported() }
                    parts = try visible.map(userPart)
                }
                if configuration.profile == .requireCurrentTurnFunctionSignatures, messageIndex >= currentTurn,
                   let first = parts.first(where: { $0["functionCall"] != nil }) {
                    guard case .string(let signature) = first["thoughtSignature"], !signature.isEmpty else { throw GeminiBoundary.unsupported() }
                }
                for call in calls { guard seenCalls.insert(call.id).inserted else { throw GeminiBoundary.invalidRequest() } }
                guard !parts.isEmpty else { throw GeminiBoundary.invalidRequest() }
                contents.append(.object(["role": .string("model"), "parts": .array(parts)]))
            case .tool: break
            }
        }
        try flushResults()
        guard !contents.isEmpty else { throw GeminiBoundary.invalidRequest() }
        var names: Set<[UInt8]> = []
        let declarations: [JSONValue] = try request.tools.map { tool in
            guard GeminiBoundary.functionName(tool.name), names.insert(Array(tool.name.utf8)).inserted,
                  case .object = tool.inputSchema else { throw GeminiBoundary.invalidRequest() }
            var fields: [String: JSONValue] = ["name": .string(tool.name), "description": .string(tool.description), "parametersJsonSchema": tool.inputSchema]
            if let schema = tool.outputSchema { guard case .object = schema else { throw GeminiBoundary.invalidRequest() }; fields["responseJsonSchema"] = schema }
            return .object(fields)
        }
        return .init(contents: contents, system: system.isEmpty ? nil : .object(["parts": .array(system)]),
                     tools: declarations.isEmpty ? nil : .array([.object(["functionDeclarations": .array(declarations)])]))
    }

    static func encode(_ request: ModelRequest, configuration: GeminiConfiguration, now: Date = Date()) throws -> Data {
        let context = try context(request, configuration: configuration)
        var body: [String: JSONValue] = ["contents": .array(context.contents)]
        if let system = context.system { body["systemInstruction"] = system }
        if let tools = context.tools { body["tools"] = tools }
        var generation: [String: JSONValue] = ["candidateCount": .number(1)]
        if let thinking = configuration.thinking { generation["thinkingConfig"] = thinking.json }
        if let limit = configuration.maximumOutputTokens { generation["maxOutputTokens"] = .number(Decimal(limit)) }
        if let schema = request.structuredOutput {
            guard schema.strict, case .object = schema.schema else { throw GeminiBoundary.unsupported() }
            generation["responseFormat"] = .object(["text": .object(["mimeType": .string("APPLICATION_JSON"), "schema": schema.schema])])
        }
        body["generationConfig"] = .object(generation)
        if case .explicit(let binding) = configuration.caching {
            try binding.validate(request: request, context: context, configuration: configuration, now: now)
            body["contents"] = .array(Array(context.contents.dropFirst(binding.prefixCount)))
            guard binding.prefixCount < context.contents.count else { throw GeminiBoundary.invalidRequest() }
            body.removeValue(forKey: "systemInstruction"); body.removeValue(forKey: "tools")
            body["cachedContent"] = .string(binding.resourceName)
        }
        let data = try ProviderJSON.encode(JSONValue.object(body))
        guard data.count <= configuration.maximumRequestBytes else {
            throw ModelProviderError(kind: .invalidRequest, message: "Encoded Gemini request exceeds its HTTP body limit.")
        }
        return data
    }
    static func userPart(_ content: ModelContent) throws -> JSONValue {
        switch content {
        case .text(let text): return .object(["text": .string(text)])
        case .json(let value): return .object(["text": .string(try ProviderJSON.text(value))])
        case .image(let image): return try imagePart(image)
        case .file(let file): return .object(["fileData": .object(["mimeType": .string(file.mediaType.rawValue), "fileUri": .string(file.uri.absoluteString)])])
        default: throw GeminiBoundary.unsupported()
        }
    }
    static func imagePart(_ image: ModelImage) throws -> JSONValue {
        .object(["inlineData": .object(["mimeType": .string(image.mediaType.rawValue), "data": .string(image.data.base64EncodedString())])])
    }
    static func validate(state: GeminiNativeState, content: [ModelContent], calls: [ToolCall]) throws {
        let parsed = try GeminiResponseDecoder.parseParts(state.parts, allowedNames: nil, mappings: state.calls)
        let expected = content.filter { if case .providerContinuation = $0 { return false }; return true }
        guard parsed.content == expected, parsed.calls == calls, state.calls.count == calls.count else { throw GeminiBoundary.unsupported() }
    }
}
