import AgentModels
import Foundation

/// Implicit caching is service managed and adds no wire flag or cache-hit guarantee.
public enum GeminiPromptCaching: Sendable { case implicit; case explicit(GeminiCachedContentBinding) }

/// Created by the cache client from a frozen, validated canonical prefix. Not execution authority.
/// Keep the selected account and remote source bytes stable; local correspondence cannot prove either.
public struct GeminiCachedContentBinding: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let resourceName: String
    public let expiresAt: Date
    let model: ModelID
    let endpoint: String
    let authorizationScopeID: String
    let sourceMessages: Data
    let contextWitness: Data
    let prefixCount: Int
    public var description: String { "GeminiCachedContentBinding(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["expiresAt": expiresAt]) }
    func validate(request: ModelRequest, context: GeminiEncodedContext, configuration: GeminiConfiguration, now: Date) throws {
        guard request.model == model, GeminiBoundary.exact(configuration.endpointScope, endpoint),
              GeminiBoundary.exact(configuration.authorizationScopeID, authorizationScopeID), now < expiresAt,
              request.messages.count >= prefixMessageCount,
              try ProviderJSON.encode(Array(request.messages.prefix(prefixMessageCount))) == sourceMessages,
              context.contents.count >= prefixCount,
              try Self.witness(context: context, prefixCount: prefixCount) == contextWitness else { throw GeminiBoundary.unsupported() }
    }
    let prefixMessageCount: Int
    static func witness(context: GeminiEncodedContext, prefixCount: Int) throws -> Data {
        try ProviderJSON.encode(JSONValue.object(["contents": .array(Array(context.contents.prefix(prefixCount))),
            "systemInstruction": context.system ?? .null, "tools": context.tools ?? .null]))
    }
}
