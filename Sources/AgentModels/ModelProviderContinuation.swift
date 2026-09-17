import Foundation

/// Opaque continuation state interpreted only by its owning provider, never by the agent loop.
public struct ModelProviderContinuation: Hashable, Sendable, Codable {
    public let model: ModelID
    public let format: String
    public let payload: Data

    public init(model: ModelID, format: String, payload: Data) {
        self.model = model
        self.format = format
        self.payload = payload
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model.provider.utf8.elementsEqual(rhs.model.provider.utf8)
            && lhs.model.name.utf8.elementsEqual(rhs.model.name.utf8)
            && lhs.format.utf8.elementsEqual(rhs.format.utf8) && lhs.payload == rhs.payload
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(model.provider.utf8))
        hasher.combine(Array(model.name.utf8))
        hasher.combine(Array(format.utf8))
        hasher.combine(payload)
    }
}
