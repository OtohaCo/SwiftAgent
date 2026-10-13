import AgentModels
import Foundation

/// Immutable formal input. Existing String APIs, queued inputs and steering remain text-only.
public struct AgentRunInput: Sendable {
    public enum Attachment: Hashable, Sendable {
        case image(ModelImage)
        case file(ModelFileReference)
    }
    public let text: String
    public let attachments: [Attachment]
    public init(text: String, attachments: [Attachment] = []) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentSessionError.emptyInput }
        guard attachments.count <= 20 else { throw AgentFileInputError.invalidLimit }
        self.text = text; self.attachments = attachments
    }
    var content: [ModelContent] {
        [.text(text)] + attachments.map {
            switch $0 { case .image(let image): .image(image); case .file(let file): .file(file) }
        }
    }
}

public enum AgentFileInputError: Error, Equatable, Sendable { case invalidLimit, invalidRole, limitExceeded }

/// Explicit file request view; canonical references are never removed or downloaded.
public struct AgentFileInputPolicy: Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable { case reject, describe, native }
    public let mode: Mode
    public let maximumFilesPerRequest: Int
    public let maximumEstimatedInputTokens: Int
    public static let reject = Self(mode: .reject, maximumFilesPerRequest: 0, maximumEstimatedInputTokens: 0)
    public static let describe = Self(mode: .describe, maximumFilesPerRequest: 0, maximumEstimatedInputTokens: 0)
    public static func native(maximumFilesPerRequest: Int = 4, maximumEstimatedInputTokens: Int = 1_000_000) throws -> Self {
        guard (1...20).contains(maximumFilesPerRequest), (1...1_000_000).contains(maximumEstimatedInputTokens) else {
            throw AgentFileInputError.invalidLimit
        }
        return .init(mode: .native, maximumFilesPerRequest: maximumFilesPerRequest,
                     maximumEstimatedInputTokens: maximumEstimatedInputTokens)
    }
    func apply(to messages: [ModelMessage], adapterSendsFiles: Bool) throws -> (messages: [ModelMessage], described: Bool) {
        let files = messages.flatMap(\.files)
        guard !files.isEmpty else { return (messages, false) }
        guard !messages.contains(where: { $0.role == .assistant && !$0.files.isEmpty }) else { throw AgentFileInputError.invalidRole }
        switch mode {
        case .reject: throw AgentLoopError.unsupportedCapabilities(.fileInput)
        case .native:
            guard adapterSendsFiles else { throw AgentLoopError.unsupportedCapabilities(.fileInput) }
            guard files.count <= maximumFilesPerRequest else { throw AgentFileInputError.limitExceeded }
            var tokens = 0
            for file in files {
                guard file.estimatedInputTokens <= maximumEstimatedInputTokens - tokens else { throw AgentFileInputError.limitExceeded }
                tokens += file.estimatedInputTokens
            }
            return (messages, false)
        case .describe:
            func describe(_ content: [ModelContent]) -> [ModelContent] {
                content.map { if case .file(let file) = $0 { .text(file.textSubstitute) } else { $0 } }
            }
            return (messages.map {
                switch $0 {
                case .user(let content): .user(describe(content))
                case .tool(let result): .tool(.init(callID: result.callID, content: describe(result.content), isError: result.isError))
                default: $0
                }
            }, true)
        }
    }
}
