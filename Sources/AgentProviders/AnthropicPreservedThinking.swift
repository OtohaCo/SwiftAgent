import AgentModels
import Foundation

enum AnthropicPreservedThinking {
    static func scope(configuration: AnthropicNativeContextConfiguration?, endpoint: URL,
                      resolvedModelName: String, thinking: AnthropicThinking) throws -> String {
        guard let configuration, configuration.preservedThinking, thinking.supportsBindingControls else {
            throw ModelProviderError(kind: .unsupportedCapability, message: "Preserved-thinking compaction requires explicit deployment and thinking qualification.")
        }
        try configuration.qualification.validate(endpoint: endpoint, model: resolvedModelName, mode: .anthropicOnDemand)
        return ModelImageDigest.sha256Hex(try ProviderJSON.encode(JSONValue.object([
            "endpoint": .string(endpoint.absoluteString), "model": .string(resolvedModelName),
            "preservedThinking": .bool(true)])))
    }
    static func witness(body: JSONValue, scope: String) throws -> ModelPreservedThinkingRequestWitness {
        guard case .array(let messages) = body["messages"] else { throw ProviderJSON.invalid() }
        let prefix = AnthropicContinuation.prefix(system: body["system"], tools: body["tools"], messages: messages)
        var configuration = try ProviderJSON.object(body)
        for key in ["messages", "system", "tools", "compaction", "context_management", "cache_control"] { configuration.removeValue(forKey: key) }
        let root = JSONValue.object(["prefix": AnthropicContinuation.prefix(system: body["system"], tools: body["tools"], messages: []),
                                     "configuration": .object(configuration)])
        return try .init(prefixDigest: ModelImageDigest.sha256Hex(try ProviderJSON.encode(prefix)),
                     rootToolsDigest: ModelImageDigest.sha256Hex(try ProviderJSON.encode(root)), qualificationScope: scope)
    }
}
