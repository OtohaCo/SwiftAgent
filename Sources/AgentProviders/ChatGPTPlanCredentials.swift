import AgentModels
import Foundation

/// The Host owns account selection, consent, token storage and refresh. Called per HTTP dispatch.
/// Do not change the selected account while a conversation retains that account's continuation.
public struct OpenAIChatGPTPlanCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let source: @Sendable () async throws -> String

    public init(accessToken: @escaping @Sendable () async throws -> String) { source = accessToken }
    public var description: String { "OpenAIChatGPTPlanCredentials(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    func token() async throws -> String {
        try Task.checkCancellation()
        let token: String
        do { token = try await source() }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw ModelProviderError(kind: .authentication, message: "ChatGPT-plan credentials are unavailable.")
        }
        try Task.checkCancellation()
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw ModelProviderError(kind: .authentication, message: "Invalid ChatGPT-plan access token.")
        }
        return token
    }
}
