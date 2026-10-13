import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Host owns key/token storage, account selection, scope qualification and refresh.
/// Read once per dispatch, never during preflight. Changing accounts requires a new binding.
public struct GeminiCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let header: String
    private let bearer: Bool
    private let source: @Sendable () async throws -> String
    public init(apiKey: @escaping @Sendable () async throws -> String) { header = "x-goog-api-key"; bearer = false; source = apiKey }
    public init(bearerToken: @escaping @Sendable () async throws -> String) { header = "Authorization"; bearer = true; source = bearerToken }
    public var description: String { "GeminiCredentials(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    func authorize(_ request: inout URLRequest) async throws {
        try Task.checkCancellation()
        let token: String
        do { token = try await source() }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); throw ModelProviderError(kind: .authentication, message: "Gemini credentials are unavailable.") }
        try Task.checkCancellation()
        guard !token.isEmpty, token.utf8.count <= 16_384,
              token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw ModelProviderError(kind: .authentication, message: "Invalid Gemini credential.")
        }
        request.setValue(bearer ? "Bearer " + token : token, forHTTPHeaderField: header)
    }
}

/// These controls require Host qualification for the selected model and endpoint.
public struct GeminiThinkingConfiguration: Hashable, Sendable {
    public enum Level: String, Hashable, Sendable { case minimal = "MINIMAL", low = "LOW", medium = "MEDIUM", high = "HIGH" }
    public let level: Level?
    public let budget: Int?
    public let includeThoughts: Bool?
    public init(level: Level? = nil, budget: Int? = nil, includeThoughts: Bool? = nil) throws {
        guard level == nil || budget == nil, budget.map({ (-1...1_000_000).contains($0) }) ?? true else { throw GeminiBoundary.invalidRequest() }
        self.level = level; self.budget = budget; self.includeThoughts = includeThoughts
    }
    var json: JSONValue {
        var fields: [String: JSONValue] = [:]
        if let level { fields["thinkingLevel"] = .string(level.rawValue) }
        if let budget { fields["thinkingBudget"] = .number(Decimal(budget)) }
        if let includeThoughts { fields["includeThoughts"] = .bool(includeThoughts) }
        return .object(fields)
    }
}

public enum GeminiPreservedThinkingProfile: Hashable, Sendable {
    /// Retain received parts exactly; does not claim strict-model qualification.
    case preserve
    /// First function-call part of every step in the current turn must have a received signature.
    case requireCurrentTurnFunctionSignatures
}

struct GeminiConfiguration: Sendable {
    let baseURL: URL
    let streaming: Bool
    let thinking: GeminiThinkingConfiguration?
    let profile: GeminiPreservedThinkingProfile
    let maximumOutputTokens: Int?
    let maximumRequestBytes: Int
    let maximumResponseBytes: Int
    let authorizationScopeID: String
    let caching: GeminiPromptCaching
    init(baseURL: URL, streaming: Bool, thinking: GeminiThinkingConfiguration?, profile: GeminiPreservedThinkingProfile,
         maximumOutputTokens: Int?, maximumRequestBytes: Int, maximumResponseBytes: Int,
         authorizationScopeID: String, caching: GeminiPromptCaching) throws {
        guard let c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              c.scheme == "https" || (c.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(c.host ?? "")),
              c.host?.isEmpty == false, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.percentEncodedPath.split(separator: "/").allSatisfy({ segment in
                  segment != "." && segment != ".." && segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
              }), (1...100_000_000).contains(maximumRequestBytes), (1...64_000_000).contains(maximumResponseBytes),
              maximumOutputTokens.map({ (1...1_000_000).contains($0) }) ?? true,
              !authorizationScopeID.isEmpty, authorizationScopeID.utf8.count <= 1024,
              !authorizationScopeID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw GeminiBoundary.invalidRequest() }
        self.baseURL = baseURL; self.streaming = streaming; self.thinking = thinking; self.profile = profile
        self.maximumOutputTokens = maximumOutputTokens; self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes; self.authorizationScopeID = authorizationScopeID; self.caching = caching
    }
    func endpoint(model: ModelID) throws -> URL {
        guard model.provider == "gemini", GeminiBoundary.slug(model.name) else { throw GeminiBoundary.invalidRequest() }
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.path = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).withGeminiSlash + "/models/" + model.name + (streaming ? ":streamGenerateContent" : ":generateContent")
        if streaming { c.queryItems = [.init(name: "alt", value: "sse")] }
        guard let url = c.url else { throw GeminiBoundary.invalidRequest() }; return url
    }
    var endpointScope: String { baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}
private extension String { var withGeminiSlash: String { isEmpty ? "" : "/" + self } }

enum GeminiBoundary {
    static func slug(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") } && name != "." && name != ".."
    }
    static func functionName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_:.-".contains($0)) }
    }
    static func invalidRequest() -> ModelProviderError { .init(kind: .invalidRequest, message: "Invalid Gemini request or configuration.") }
    static func unsupported() -> ModelProviderError { .init(kind: .unsupportedCapability, message: "Unsupported Gemini content, continuation or cache boundary.") }
    static func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
}
