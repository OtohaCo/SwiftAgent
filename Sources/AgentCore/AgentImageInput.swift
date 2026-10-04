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
        /// before dispatch. The newest images are sent while they fit both request limits; older ones
        /// are sent as their text substitutes.
        case native
    }

    /// At most 20 images a request: Anthropic lowers its pixel limit for requests with more.
    public static let maximumImagesPerRequestLimit = 20
    /// At most 24 MiB of image bytes a request, whose base64 form stays within Anthropic's 32 MB request.
    public static let maximumImageBytesPerRequestLimit = 24 * 1024 * 1024

    public let mode: Mode
    public let maximumImagesPerRequest: Int
    public let maximumImageBytesPerRequest: Int

    public static let reject = Self(mode: .reject, images: 0, bytes: 0)
    public static let describe = Self(mode: .describe, images: 0, bytes: 0)

    public static func native(maximumImagesPerRequest: Int = 20,
                              maximumImageBytesPerRequest: Int = 20 * 1024 * 1024) throws -> Self {
        guard (1...maximumImagesPerRequestLimit).contains(maximumImagesPerRequest),
              (1...maximumImageBytesPerRequestLimit).contains(maximumImageBytesPerRequest) else {
            throw AgentModelBindingError.invalidImageLimit
        }
        return Self(mode: .native, images: maximumImagesPerRequest, bytes: maximumImageBytesPerRequest)
    }

    private init(mode: Mode, images: Int, bytes: Int) {
        self.mode = mode
        maximumImagesPerRequest = images
        maximumImageBytesPerRequest = bytes
    }

    /// The request's messages under this policy, and whether any image became text. Messages without
    /// images are returned unchanged.
    func apply(to messages: [ModelMessage], adapterSendsImages: Bool) throws -> (messages: [ModelMessage], described: Bool) {
        let images = messages.flatMap(\.images)
        guard !images.isEmpty else { return (messages, false) }
        // Models never produce images; a projection that put one in assistant content is invalid.
        guard !messages.contains(where: { $0.role == .assistant && !$0.images.isEmpty }) else {
            throw AgentModelBindingError.invalidProjection
        }
        var keep = 0
        switch mode {
        case .reject:
            throw AgentLoopError.unsupportedCapabilities(.imageInput)
        case .describe:
            keep = 0
        case .native:
            guard adapterSendsImages else { throw AgentLoopError.unsupportedCapabilities(.imageInput) }
            var bytes = 0
            for image in images.reversed() {
                guard keep < maximumImagesPerRequest, bytes + image.byteCount <= maximumImageBytesPerRequest else { break }
                keep += 1
                bytes += image.byteCount
            }
        }
        var describe = images.count - keep
        guard describe > 0 else { return (messages, false) }
        func rewrite(_ content: [ModelContent]) -> [ModelContent] {
            content.map { part in
                guard describe > 0, case .image(let image) = part else { return part }
                describe -= 1
                return .text(image.textSubstitute)
            }
        }
        let rewritten = messages.map { message -> ModelMessage in
            switch message {
            case .user(let content): return .user(rewrite(content))
            case .tool(let result):
                return .tool(.init(callID: result.callID, content: rewrite(result.content), isError: result.isError))
            case .assistant, .system, .developer: return message
            }
        }
        return (rewritten, true)
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
