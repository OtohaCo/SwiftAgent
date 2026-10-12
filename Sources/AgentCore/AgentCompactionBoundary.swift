import Foundation

/// A persisted, SDK-observed request boundary. Only a Session can return one;
/// callers cannot construct a cut from a message count or replacement witness.
public struct AgentCompactionBoundary: Hashable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let canonicalMessageCount: Int
    package init(id: UUID, sessionID: UUID, canonicalMessageCount: Int) {
        self.id = id; self.sessionID = sessionID; self.canonicalMessageCount = canonicalMessageCount
    }
}
