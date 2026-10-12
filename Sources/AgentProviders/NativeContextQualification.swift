import AgentModels
import Foundation

/// Host qualification of a concrete endpoint and resolved model set. This does
/// not probe credentials or infer that a compatible proxy implements vendor beta APIs.
public struct NativeContextQualification: Hashable, Sendable, Codable {
    public let endpoint: URL
    public let resolvedModelNames: Set<String>
    public let modes: Set<ModelCompactionMode>
    public init(endpoint: URL, resolvedModelNames: Set<String>, modes: Set<ModelCompactionMode>) throws {
        guard !resolvedModelNames.isEmpty, resolvedModelNames.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              modes.allSatisfy({ [.anthropicThreshold, .anthropicOnDemand, .openAIAutomatic, .openAIStandalone].contains($0) }) else {
            throw ModelProviderError(kind: .invalidRequest, message: "Native context qualification requires explicit known modes and resolved models.")
        }
        self.endpoint = endpoint; self.resolvedModelNames = resolvedModelNames; self.modes = modes
    }
    func validate(endpoint: URL, model: String, mode: ModelCompactionMode) throws {
        guard self.endpoint == endpoint, resolvedModelNames.contains(model), modes.contains(mode) else {
            throw ModelProviderError(kind: .unsupportedCapability, message: "The native context mode is not qualified for this endpoint and resolved model.")
        }
    }
    private enum CodingKeys: String, CodingKey { case endpoint, resolvedModelNames, modes }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(URL.self, forKey: .endpoint), resolvedModelNames: c.decode(Set<String>.self, forKey: .resolvedModelNames),
                      modes: c.decode(Set<ModelCompactionMode>.self, forKey: .modes))
    }
}

public struct OpenAINativeContextConfiguration: Hashable, Sendable, Codable {
    public let qualification: NativeContextQualification
    public let automatic: ModelAutomaticCompaction?
    public init(qualification: NativeContextQualification, automatic: ModelAutomaticCompaction? = nil) throws {
        guard qualification.modes.isSubset(of: [.openAIAutomatic, .openAIStandalone]),
              automatic == nil || (automatic?.mode == .openAIAutomatic && qualification.modes.contains(.openAIAutomatic)) else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid OpenAI native context configuration.")
        }
        self.qualification = qualification; self.automatic = automatic
    }
    private enum CodingKeys: String, CodingKey { case qualification, automatic }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(qualification: c.decode(NativeContextQualification.self, forKey: .qualification),
                      automatic: c.decodeIfPresent(ModelAutomaticCompaction.self, forKey: .automatic))
    }
}

public enum AnthropicThinkingPrefixMismatch: String, Hashable, Sendable, Codable {
    case error, dropBlock = "drop_block"
}

public struct AnthropicNativeContextConfiguration: Hashable, Sendable, Codable {
    public let qualification: NativeContextQualification
    public let automatic: ModelAutomaticCompaction?
    public let inlineToolChanges: Bool
    public let runReminders: Bool
    public let thinkingPrefixMismatch: AnthropicThinkingPrefixMismatch?
    public let preservedThinking: Bool
    public init(qualification: NativeContextQualification, automatic: ModelAutomaticCompaction? = nil,
                inlineToolChanges: Bool = false, runReminders: Bool = false,
                thinkingPrefixMismatch: AnthropicThinkingPrefixMismatch? = nil) throws {
        try self.init(qualification: qualification, automatic: automatic, inlineToolChanges: inlineToolChanges,
                      runReminders: runReminders, thinkingPrefixMismatch: thinkingPrefixMismatch, preservedThinking: false)
    }
    /// Host qualification that every managed on-demand compaction uses a model
    /// with preserved thinking. No account capability is inferred from credentials.
    public init(qualification: NativeContextQualification, automatic: ModelAutomaticCompaction? = nil,
                inlineToolChanges: Bool = false, runReminders: Bool = false,
                thinkingPrefixMismatch: AnthropicThinkingPrefixMismatch? = nil, preservedThinking: Bool) throws {
        guard !preservedThinking || (qualification.modes.contains(.anthropicOnDemand) && automatic == nil),
              qualification.modes.isSubset(of: [.anthropicThreshold, .anthropicOnDemand]),
              automatic == nil || (automatic?.mode == .anthropicThreshold && qualification.modes.contains(.anthropicThreshold)),
              !(automatic != nil && runReminders) else {
            throw ModelProviderError(kind: .unsupportedCapability, message: "Invalid Anthropic native context/reminder combination.")
        }
        self.qualification = qualification; self.automatic = automatic; self.inlineToolChanges = inlineToolChanges
        self.runReminders = runReminders; self.thinkingPrefixMismatch = thinkingPrefixMismatch; self.preservedThinking = preservedThinking
    }
    private enum CodingKeys: String, CodingKey { case qualification, automatic, inlineToolChanges, runReminders, thinkingPrefixMismatch, preservedThinking }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(qualification: c.decode(NativeContextQualification.self, forKey: .qualification),
            automatic: c.decodeIfPresent(ModelAutomaticCompaction.self, forKey: .automatic),
            inlineToolChanges: c.decodeIfPresent(Bool.self, forKey: .inlineToolChanges) ?? false, runReminders: c.decodeIfPresent(Bool.self, forKey: .runReminders) ?? false,
            thinkingPrefixMismatch: c.decodeIfPresent(AnthropicThinkingPrefixMismatch.self, forKey: .thinkingPrefixMismatch),
            preservedThinking: c.decodeIfPresent(Bool.self, forKey: .preservedThinking) ?? false)
    }
}

// Internal diagnostics deliberately exclude signed/encrypted native material.
enum NativeContextWire {
    static func usage(_ value: JSONValue?) throws -> ModelUsage {
        guard let value, value != .null else { return .init() }
        let object = try ProviderJSON.object(value)
        let inputDetails = try object["input_tokens_details"].flatMap { $0 == .null ? nil : try ProviderJSON.object($0) }
        let outputDetails = try object["output_tokens_details"].flatMap { $0 == .null ? nil : try ProviderJSON.object($0) }
        let input = try ProviderJSON.count(object["input_tokens"]), output = try ProviderJSON.count(object["output_tokens"])
        let read = try ProviderJSON.count(inputDetails?["cached_tokens"]), write = try ProviderJSON.count(inputDetails?["cache_write_tokens"])
        let reasoning = try ProviderJSON.count(outputDetails?["reasoning_tokens"])
        _ = try ModelUsageIteration(ordinal: 0, kind: "message", inputTokens: input, outputTokens: output,
                                    cachedInputTokens: read, cacheWriteInputTokens: write, reasoningTokens: reasoning)
        return .init(inputTokens: input, outputTokens: output, cachedInputTokens: read,
                     cacheWriteInputTokens: write, reasoningTokens: reasoning)
    }
    static func checked(_ value: JSONValue, maximum: Int = 32_000_000) throws -> Data {
        let body = try ProviderJSON.encode(value)
        guard body.count <= maximum else { throw ModelProviderError(kind: .invalidRequest, message: "Encoded native request exceeds the local byte limit.") }
        return body
    }
    static func openAICompactionItem(_ value: JSONValue) throws {
        let item = try ProviderJSON.object(value)
        guard item["type"] == .string("compaction"), !(try ProviderJSON.string(item["id"])).isEmpty,
              !(try ProviderJSON.string(item["encrypted_content"])).isEmpty else { throw ProviderJSON.invalid() }
    }
    static func validateOpenAIWindow(_ items: [JSONValue], requiresClosedCalls: Bool = false) throws {
        guard !items.isEmpty, items.count <= 10_000 else { throw ProviderJSON.invalid() }
        var found = false, ids: Set<String> = [], callIDs: Set<String> = [], pending: Set<String> = []
        for value in items {
            let item = try ProviderJSON.object(value)
            if let id = item["id"], id != .null {
                let value = try ProviderJSON.string(id)
                guard !value.isEmpty, ids.insert(value).inserted else { throw ProviderJSON.invalid() }
            }
            switch item["type"] {
            case .string("compaction"):
                try openAICompactionItem(value); found = true
            case .string("message"):
                guard let role = item["role"], [JSONValue.string("user"), .string("assistant"), .string("system"), .string("developer")].contains(role),
                      item["content"] != nil else { throw ProviderJSON.invalid() }
                if let status = item["status"], status != .null, status != .string("completed") { throw ProviderJSON.invalid() }
                if case .array(let content) = item["content"] {
                    for part in content {
                        let object = try ProviderJSON.object(part)
                        guard let type = object["type"], [.string("input_text"), .string("output_text"), .string("input_image"), .string("refusal")].contains(type) else { throw ProviderJSON.invalid() }
                        if type == .string("input_image") {
                            guard !(try ProviderJSON.string(object["image_url"])).isEmpty else { throw ProviderJSON.invalid() }
                        }
                        else { _ = try ProviderJSON.string(object[type == .string("refusal") ? "refusal" : "text"]) }
                    }
                } else { _ = try ProviderJSON.string(item["content"]) }
            case .string("reasoning"):
                guard found else { throw ProviderJSON.invalid() }
                try OpenAIResponsesContinuation.validateNativeWindowReasoning(item)
            case .string("function_call"):
                guard found else { throw ProviderJSON.invalid() }
                try OpenAIResponsesContinuation.validateNativeWindowFunction(item)
                let callID = try ProviderJSON.string(item["call_id"])
                guard callIDs.insert(callID).inserted else { throw ProviderJSON.invalid() }
                pending.insert(callID)
            case .string("function_call_output"):
                guard found else { throw ProviderJSON.invalid() }
                let callID = try ProviderJSON.string(item["call_id"])
                guard !callID.isEmpty, pending.remove(callID) != nil else { throw ProviderJSON.invalid() }
                // This adapter supports the existing text/JSON client-result contract.
                _ = try ProviderJSON.string(item["output"])
            default: throw ModelProviderError(kind: .unsupportedCapability, message: "Unsupported native compact window item.")
            }
        }
        guard found, !requiresClosedCalls || pending.isEmpty else { throw ProviderJSON.invalid() }
    }
}

extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }; return object[key]
    }
}
