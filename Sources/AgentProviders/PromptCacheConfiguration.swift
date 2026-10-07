import AgentModels
import Foundation

/// Host-verified Anthropic Messages cache controls for an exact endpoint and
/// resolved model set. This attestation does not establish upstream cache hits.
public struct AnthropicPromptCaching: Hashable, Sendable, Codable {
    public enum TTL: String, Hashable, Sendable, Codable {
        case fiveMinutes = "5m"
        case oneHour = "1h"
    }

    public enum Capability: String, Hashable, Sendable, Codable {
        case automatic, explicitBreakpoints, oneHourTTL
    }

    public struct Breakpoint: Hashable, Sendable, Codable {
        public enum Target: Hashable, Sendable, Codable {
            case lastTool
            /// Zero-based position among leading system/developer instructions.
            case system(index: Int)
            /// Canonical ModelRequest message position and its encoded block position,
            /// before adjacent Anthropic messages with the same role are combined.
            case message(index: Int, contentBlock: Int)
        }
        public let target: Target
        public let ttl: TTL
        public init(target: Target, ttl: TTL = .fiveMinutes) { self.target = target; self.ttl = ttl }
    }

    public let endpoint: URL
    public let modelNames: Set<String>
    public let capabilities: Set<Capability>
    public let automaticTTL: TTL?
    public let breakpoints: [Breakpoint]

    public init(endpoint: URL, modelNames: Set<String>, capabilities: Set<Capability>,
                automaticTTL: TTL? = nil, breakpoints: [Breakpoint] = []) {
        self.endpoint = endpoint
        self.modelNames = modelNames
        self.capabilities = capabilities
        self.automaticTTL = automaticTTL
        self.breakpoints = breakpoints
    }

    func validate(endpoint actualEndpoint: URL? = nil, modelName: String? = nil) throws {
        try PromptCacheQualification.validate(endpoint: endpoint, actualEndpoint: actualEndpoint,
                                              modelNames: modelNames, modelName: modelName)
        guard breakpoints.count + (automaticTTL == nil ? 0 : 1) <= 4,
              Set(breakpoints.map(\.target)).count == breakpoints.count else {
            throw PromptCacheQualification.invalid("At most four distinct Anthropic cache breakpoints are allowed, including automatic caching.")
        }
        guard automaticTTL == nil || capabilities.contains(.automatic),
              breakpoints.isEmpty || capabilities.contains(.explicitBreakpoints),
              !(automaticTTL == .oneHour || breakpoints.contains { $0.ttl == .oneHour }) || capabilities.contains(.oneHourTTL) else {
            throw PromptCacheQualification.unsupported("The endpoint/model has not been qualified for the selected Anthropic cache controls.")
        }
        for breakpoint in breakpoints {
            switch breakpoint.target {
            case .lastTool: break
            case .system(let index):
                guard index >= 0 else { throw PromptCacheQualification.invalid("A cache breakpoint index must be nonnegative.") }
            case .message(let index, let block):
                guard index >= 0, block >= 0 else { throw PromptCacheQualification.invalid("A cache breakpoint index must be nonnegative.") }
            }
        }
    }

    func control(_ ttl: TTL) -> JSONValue {
        .object(["type": .string("ephemeral"), "ttl": .string(ttl.rawValue)])
    }

    func mark(_ blocks: [JSONValue], atMessage index: Int) throws -> [JSONValue] {
        var blocks = blocks
        for breakpoint in breakpoints {
            guard case .message(let target, let block) = breakpoint.target, target == index else { continue }
            guard blocks.indices.contains(block), case .object(var value) = blocks[block], Self.cacheable(value) else {
                throw PromptCacheQualification.invalid("The Anthropic cache breakpoint does not target an eligible content block.")
            }
            value["cache_control"] = control(breakpoint.ttl)
            blocks[block] = .object(value)
        }
        return blocks
    }

    static func cacheable(_ block: [String: JSONValue]) -> Bool {
        guard case .string(let type) = block["type"],
              ["text", "image", "document", "tool_use", "tool_result"].contains(type) else { return false }
        if type == "text", case .string(let text) = block["text"] { return !text.isEmpty }
        return type != "text"
    }

    func validateTTLOrder(in body: [String: JSONValue]) throws {
        var blocks: [[String: JSONValue]] = []
        if case .array(let tools) = body["tools"] { blocks += tools.compactMap(\.cacheObject) }
        if case .array(let system) = body["system"] { blocks += system.compactMap(\.cacheObject) }
        if case .array(let messages) = body["messages"] {
            for message in messages {
                if case .array(let content) = message.cacheObject?["content"] { blocks += content.compactMap(\.cacheObject) }
            }
        }
        var ttls = blocks.compactMap { block -> TTL? in
            guard case .object(let control) = block["cache_control"], case .string(let ttl) = control["ttl"] else { return nil }
            return TTL(rawValue: ttl)
        }
        if let automaticTTL {
            if let last = blocks.last(where: Self.cacheable), case .object(let control) = last["cache_control"],
               case .string(let ttl) = control["ttl"], ttl != automaticTTL.rawValue {
                throw PromptCacheQualification.invalid("Automatic caching and the last explicit breakpoint must use the same TTL.")
            }
            ttls.append(automaticTTL)
        }
        var sawFiveMinutes = false
        for ttl in ttls {
            if ttl == .fiveMinutes { sawFiveMinutes = true }
            else if sawFiveMinutes {
                throw PromptCacheQualification.invalid("Anthropic one-hour cache breakpoints must precede five-minute breakpoints.")
            }
        }
    }
}

/// Host-verified Responses cache protocol for an exact endpoint and resolved
/// model set. Compatible gateways and local services require their own evidence.
public struct OpenAIResponsesPromptCaching: Hashable, Sendable, Codable {
    public enum Capability: String, Hashable, Sendable, Codable {
        case modernControls, prewarm, legacyInMemoryRetention, legacy24HourRetention
    }
    public enum Mode: String, Hashable, Sendable, Codable { case implicit, explicit }
    public enum TTL: String, Hashable, Sendable, Codable { case thirtyMinutes = "30m" }
    public enum Retention: String, Hashable, Sendable, Codable {
        case inMemory = "in_memory"
        case twentyFourHours = "24h"
    }
    public struct Breakpoint: Hashable, Sendable, Codable {
        public let messageIndex: Int
        /// Position among eligible encoded content blocks of this canonical message.
        /// A plain-text message or tool result has exactly one block at index zero.
        public let contentBlock: Int
        public init(messageIndex: Int, contentBlock: Int = 0) {
            self.messageIndex = messageIndex; self.contentBlock = contentBlock
        }
    }
    public enum Policy: Hashable, Sendable, Codable {
        /// Historical markers can exceed the per-request cache-write budget.
        /// Keep them in canonical history; the service selects eligible writes/lookups.
        case modern(mode: Mode, ttl: TTL, breakpoints: [Breakpoint])
        case legacy(retention: Retention)
    }
    public let endpoint: URL
    public let modelNames: Set<String>
    public let capabilities: Set<Capability>
    public let policy: Policy
    public init(endpoint: URL, modelNames: Set<String>, capabilities: Set<Capability>, policy: Policy) {
        self.endpoint = endpoint; self.modelNames = modelNames; self.capabilities = capabilities; self.policy = policy
    }

    func validate(endpoint actualEndpoint: URL? = nil, modelName: String? = nil, prewarm: Bool = false) throws {
        try PromptCacheQualification.validate(endpoint: endpoint, actualEndpoint: actualEndpoint,
                                              modelNames: modelNames, modelName: modelName)
        switch policy {
        case .modern(_, _, let breakpoints):
            guard capabilities.contains(.modernControls), !prewarm || capabilities.contains(.prewarm) else {
                throw PromptCacheQualification.unsupported("The endpoint/model has not been qualified for modern Responses cache controls or prewarming.")
            }
            guard Set(breakpoints).count == breakpoints.count,
                  breakpoints.allSatisfy({ $0.messageIndex >= 0 && $0.contentBlock >= 0 }) else {
                throw PromptCacheQualification.invalid("Invalid or duplicate Responses breakpoint positions.")
            }
        case .legacy(let retention):
            guard !prewarm,
                  capabilities.contains(retention == .inMemory ? .legacyInMemoryRetention : .legacy24HourRetention) else {
                throw PromptCacheQualification.unsupported("The endpoint/model has not been qualified for this retention policy or prewarming.")
            }
        }
    }

    func apply(to body: inout [String: JSONValue], request: ModelRequest, images: Bool,
               assistantNativeItems: ResponsesCanonicalRequestEncoder.AssistantNativeItems? = nil,
               prewarm: Bool = false) throws {
        switch policy {
        case .legacy(let retention): body["prompt_cache_retention"] = .string(retention.rawValue)
        case .modern(let mode, let ttl, let breakpoints):
            var options: [String: JSONValue] = ["mode": .string(mode.rawValue), "ttl": .string(ttl.rawValue)]
            if prewarm { options["prewarm"] = .bool(true) }
            body["prompt_cache_options"] = .object(options)
            guard case .array(var input) = body["input"] else { throw PromptCacheQualification.invalid("Missing Responses input.") }
            // Prefix counts preserve the existing encoder's continuation and text grouping
            // exactly; only marked blocks acquire the additional wire control.
            for breakpoint in breakpoints {
                guard request.messages.indices.contains(breakpoint.messageIndex) else {
                    throw PromptCacheQualification.invalid("The Responses cache breakpoint message is absent.")
                }
                let before = Array(request.messages.prefix(breakpoint.messageIndex))
                let through = Array(request.messages.prefix(breakpoint.messageIndex + 1))
                // An omitted empty assistant may make an intermediate prefix empty.
                // A temporary empty user item keeps that prefix countable without
                // weakening the real encoder's history/continuation validation.
                let sentinel = ModelMessage.user([.text("")])
                let start = try ResponsesCanonicalRequestEncoder.encodeMessages(
                    before + [sentinel], images: images, assistantNativeItems: assistantNativeItems).count - 1
                let end = try ResponsesCanonicalRequestEncoder.encodeMessages(
                    through + [sentinel], images: images, assistantNativeItems: assistantNativeItems).count - 1
                var candidates: [(Int, Int)] = []
                for itemIndex in start..<end {
                    guard case .object(let item) = input[itemIndex] else { continue }
                    let key: String
                    if item["type"] == .string("function_call_output") { key = "output" }
                    else if item["type"] == .string("message"), item["role"] != .string("assistant") { key = "content" }
                    else { continue }
                    if case .string(let text) = item[key], !text.isEmpty { candidates.append((itemIndex, 0)) }
                    if case .array(let blocks) = item[key] {
                        for (blockIndex, block) in blocks.enumerated() {
                            guard case .object(let value) = block,
                                  [JSONValue.string("input_text"), .string("input_image")].contains(value["type"] ?? .null) else { continue }
                            if value["type"] == .string("input_text"), value["text"] == .string("") { continue }
                            candidates.append((itemIndex, blockIndex))
                        }
                    }
                }
                guard candidates.indices.contains(breakpoint.contentBlock) else {
                    throw PromptCacheQualification.invalid("The Responses cache breakpoint does not target an eligible input content block.")
                }
                let (itemIndex, blockIndex) = candidates[breakpoint.contentBlock]
                guard case .object(var item) = input[itemIndex] else { throw PromptCacheQualification.invalid("Missing cache target.") }
                let key = item["type"] == .string("function_call_output") ? "output" : "content"
                var blocks: [JSONValue]
                if case .string(let text) = item[key] { blocks = [.object(["type": .string("input_text"), "text": .string(text)])] }
                else if case .array(let value) = item[key] { blocks = value }
                else { throw PromptCacheQualification.invalid("Missing cache target content.") }
                guard case .object(var block) = blocks[blockIndex] else { throw PromptCacheQualification.invalid("Invalid cache target.") }
                block["prompt_cache_breakpoint"] = .object(["mode": .string("explicit")])
                blocks[blockIndex] = .object(block)
                item[key] = .array(blocks)
                input[itemIndex] = .object(item)
            }
            body["input"] = .array(input)
        }
    }
}

enum PromptCacheQualification {
    static func validatePrewarm(_ event: ModelEvent) throws {
        guard case .responseCompleted(let response) = event else { return }
        guard response.content.isEmpty, response.toolCalls.isEmpty,
              response.usage.outputTokens.map({ $0 == 0 }) ?? true else {
            throw ModelProviderError(kind: .invalidResponse, message: "A prewarm request unexpectedly generated output.")
        }
    }

    static func validate(endpoint: URL, actualEndpoint: URL?, modelNames: Set<String>, modelName: String?) throws {
        guard !modelNames.isEmpty, modelNames.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
            && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              endpoint.host?.isEmpty == false, endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              endpoint.query == nil, ["https", "http"].contains(endpoint.scheme?.lowercased() ?? "") else {
            throw invalid("Invalid prompt cache endpoint/model qualification.")
        }
        if let actualEndpoint, endpoint != actualEndpoint { throw unsupported("Prompt cache configuration belongs to a different endpoint.") }
        if let modelName, !modelNames.contains(modelName) { throw unsupported("This resolved model has not been qualified for the configured cache protocol.") }
    }
    static func invalid(_ message: String) -> ModelProviderError { .init(kind: .invalidRequest, message: message) }
    static func unsupported(_ message: String) -> ModelProviderError { .init(kind: .unsupportedCapability, message: message) }
}

private extension JSONValue {
    var cacheObject: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}
