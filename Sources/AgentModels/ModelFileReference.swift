import Foundation

/// Host-managed immutable remote input. Identity covers this reference, not downloaded bytes.
/// The Host owns upload, access, expiry and content immutability. The SDK never fetches the URI.
public struct ModelFileReference: Hashable, Sendable, Codable, CustomDebugStringConvertible, CustomReflectable {
    public enum MediaType: String, Hashable, Sendable, Codable, CaseIterable {
        case pdf = "application/pdf"
        case plainText = "text/plain"
    }
    public let uri: URL
    public let mediaType: MediaType
    public let description: String
    /// Host estimate, not vendor tokenization or proof of remote contents.
    public let estimatedInputTokens: Int

    public init(uri: URL, mediaType: MediaType, description: String, estimatedInputTokens: Int) throws {
        guard uri.scheme?.lowercased() == "https", uri.host?.isEmpty == false,
              uri.user == nil, uri.password == nil, uri.fragment == nil,
              uri.absoluteString.utf8.count <= 4096,
              !uri.absoluteString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              description.utf8.count <= 1024, (0...1_000_000).contains(estimatedInputTokens) else {
            throw ModelFileReferenceError.invalidReference
        }
        self.uri = uri; self.mediaType = mediaType; self.description = description
        self.estimatedInputTokens = estimatedInputTokens
    }
    public var textSubstitute: String { "[File not shown: \(description) (\(mediaType.rawValue))]" }
    public var debugDescription: String { "ModelFileReference(\(mediaType.rawValue), URI redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["mediaType": mediaType, "uri": "<redacted>"]) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.uri.absoluteString.utf8.elementsEqual(rhs.uri.absoluteString.utf8)
            && lhs.mediaType == rhs.mediaType && lhs.description.utf8.elementsEqual(rhs.description.utf8)
            && lhs.estimatedInputTokens == rhs.estimatedInputTokens
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(uri.absoluteString.utf8)); hasher.combine(mediaType)
        hasher.combine(Array(description.utf8)); hasher.combine(estimatedInputTokens)
    }
    private enum CodingKeys: String, CodingKey { case uri, mediaType, description, estimatedInputTokens }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(uri: c.decode(URL.self, forKey: .uri), mediaType: c.decode(MediaType.self, forKey: .mediaType),
                      description: c.decode(String.self, forKey: .description),
                      estimatedInputTokens: c.decode(Int.self, forKey: .estimatedInputTokens))
    }
}
public enum ModelFileReferenceError: Error, Equatable, Sendable { case invalidReference }

extension ModelMessage {
    public var files: [ModelFileReference] {
        let parts: [ModelContent]
        switch self {
        case .system, .developer: return []
        case .user(let content), .assistant(let content, _): parts = content
        case .tool(let result): parts = result.content
        }
        return parts.compactMap { if case .file(let file) = $0 { file } else { nil } }
    }
}
