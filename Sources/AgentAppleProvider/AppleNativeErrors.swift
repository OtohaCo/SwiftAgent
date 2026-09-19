#if canImport(FoundationModels)
import AgentModels
import Foundation
import FoundationModels

@available(macOS 26, iOS 26, *)
enum AppleNativeErrors {
    static func resolve(_ error: any Error) throws -> AppleModelPlan {
        #if compiler(>=6.4)
        if #available(macOS 27, iOS 27, *), let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .networkFailure: throw failure(.transport)
            case .quotaLimitReached(let context):
                let retryAfter = context.resetDate.flatMap { resetDate -> Duration? in
                    let milliseconds = Int64((resetDate.timeIntervalSinceNow * 1_000).rounded(.up))
                    return milliseconds > 0 ? .milliseconds(milliseconds) : nil
                }
                throw ModelProviderError(
                    kind: .rateLimited,
                    message: "Apple model generation failed (rateLimited).",
                    retryAfter: retryAfter
                )
            case .serviceUnavailable: throw failure(.unavailable)
            @unknown default: throw failure(.unavailable)
            }
        }
        if #available(macOS 27, iOS 27, *), error is GeneratedContent.ParsingError {
            throw failure(.invalidResponse)
        }
        if #available(macOS 27, iOS 27, *), let error = error as? LanguageModelError {
            switch error {
            case .refusal, .guardrailViolation: return refusal
            case .contextSizeExceeded, .unsupportedTranscriptContent: throw failure(.invalidRequest)
            case .rateLimited: throw failure(.rateLimited)
            case .unsupportedCapability, .unsupportedGenerationGuide, .unsupportedLanguageOrLocale:
                throw failure(.unsupportedCapability)
            case .timeout: throw failure(.unavailable)
            @unknown default: throw failure(.unavailable)
            }
        }
        #endif
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .refusal, .guardrailViolation: return refusal
            case .exceededContextWindowSize, .concurrentRequests: throw failure(.invalidRequest)
            case .rateLimited: throw failure(.rateLimited)
            case .unsupportedGuide, .unsupportedLanguageOrLocale: throw failure(.unsupportedCapability)
            case .decodingFailure: throw failure(.invalidResponse)
            case .assetsUnavailable: throw failure(.unavailable)
            @unknown default: throw failure(.unavailable)
            }
        }
        if error is DecodingError { throw failure(.invalidResponse) }
        throw failure(.unavailable)
    }

    private static var refusal: AppleModelPlan {
        .init(kind: .refusal, text: "The model declined this request.", toolCalls: [])
    }

    private static func failure(_ kind: ModelProviderError.Kind) -> ModelProviderError {
        .init(kind: kind, message: "Apple model generation failed (\(kind.rawValue)).")
    }
}
#endif
