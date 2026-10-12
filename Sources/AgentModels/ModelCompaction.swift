import Foundation

/// Open protocol identity. Unknown kinds can be retained as metadata, never executed implicitly.
public struct ModelCompactionMode: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let anthropicThreshold = Self(rawValue: "anthropic_threshold")
    public static let anthropicOnDemand = Self(rawValue: "anthropic_on_demand")
    public static let openAIAutomatic = Self(rawValue: "openai_automatic")
    public static let openAIStandalone = Self(rawValue: "openai_standalone")
    public init(from decoder: any Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}
