import AgentModels
import Foundation

/// How a Run sends images in its model requests (ADR 0012). Whether the bound model accepts images is
/// the Host's knowledge; the adapter's `ModelCapabilities.imageInput` says whether it can send them.
/// The choice applies to the request only: the conversation keeps every image.
public struct AgentImageInputPolicy: Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        /// A request containing an image fails before dispatch with
        /// `AgentLoopError.unsupportedCapabilities(.imageInput)`.
        case reject
        /// Each image is sent as its `ModelImage.textSubstitute`: the explicit choice for a model that
        /// does not see images.
        case describe
        /// Images are sent to the model. The adapter must declare `.imageInput`, or the request fails
        /// before dispatch. Beyond `maximumImagesPerRequest`, older images are sent as their text substitutes.
        case native
    }

    public static let maximumImagesPerRequestLimit = 100

    public let mode: Mode
    public let maximumImagesPerRequest: Int

    public static let reject = Self(mode: .reject, maximumImagesPerRequest: 0)
    public static let describe = Self(mode: .describe, maximumImagesPerRequest: 0)

    public static func native(maximumImagesPerRequest: Int = 20) throws -> Self {
        guard (1...maximumImagesPerRequestLimit).contains(maximumImagesPerRequest) else {
            throw AgentModelBindingError.invalidImageLimit
        }
        return Self(mode: .native, maximumImagesPerRequest: maximumImagesPerRequest)
    }

    private init(mode: Mode, maximumImagesPerRequest: Int) {
        self.mode = mode
        self.maximumImagesPerRequest = maximumImagesPerRequest
    }

    /// The request's messages under this policy. Messages without images are returned unchanged.
    func apply(to messages: [ModelMessage], adapterSendsImages: Bool) throws -> [ModelMessage] {
        let total = messages.reduce(0) { $0 + $1.images.count }
        guard total > 0 else { return messages }
        let keep: Int
        switch mode {
        case .reject:
            throw AgentLoopError.unsupportedCapabilities(.imageInput)
        case .describe:
            keep = 0
        case .native:
            guard adapterSendsImages else { throw AgentLoopError.unsupportedCapabilities(.imageInput) }
            keep = maximumImagesPerRequest
        }
        var describe = max(0, total - keep)
        guard describe > 0 else { return messages }
        func rewrite(_ content: [ModelContent]) -> [ModelContent] {
            content.map { part in
                guard describe > 0, case .image(let image) = part else { return part }
                describe -= 1
                return .text(image.textSubstitute)
            }
        }
        return messages.map { message in
            switch message {
            case .user(let content): return .user(rewrite(content))
            case .tool(let result):
                return .tool(.init(callID: result.callID, content: rewrite(result.content), isError: result.isError))
            case .assistant(let content, let calls): return .assistant(content: rewrite(content), toolCalls: calls)
            case .system, .developer: return message
            }
        }
    }
}

extension AgentContextTokenEstimationInput {
    /// The sum of `ModelImage.estimatedInputTokens` over the images in `messages`. An estimator that
    /// measures text should encode the messages with `ModelImage.referenceOnlyEncoding` and add this.
    public var imageInputTokens: Int {
        messages.reduce(0) { total, message in
            message.images.reduce(total) { $0 + $1.estimatedInputTokens }
        }
    }
}
