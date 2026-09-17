#if canImport(FoundationModels) && compiler(>=6.4)
import AgentModels
import Foundation
import FoundationModels
import Testing
@testable import AgentAppleProvider

struct AppleNativeErrorTests {
    @Test(.enabled(if: modernNativeErrorsAvailable))
    func nativeFailuresAreClassifiedWithoutLeakingDiagnostics() async throws {
        if #available(macOS 27, iOS 27, *) {
            let cases: [(any Error, ModelProviderError.Kind)] = [
                (LanguageModelError.contextSizeExceeded(.init(contextSize: 10, tokenCount: 11, debugDescription: "private input")), .invalidRequest),
                (LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "private input")), .rateLimited),
                (LanguageModelError.unsupportedGenerationGuide(.init(schemaName: nil, debugDescription: "private input")), .unsupportedCapability),
                (GeneratedContent.ParsingError(rawContent: "private input", debugDescription: "private input"), .invalidResponse),
            ]
            for (native, expected) in cases {
                let provider = AppleFoundationProvider { _ in throw native }
                do {
                    for try await _ in provider.stream(request: .init(model: AppleFoundationProvider.modelID, messages: [])) {}
                    Issue.record("Native failure must terminate the response")
                } catch {
                    #expect((error as? ModelProviderError)?.kind == expected)
                    #expect((error as? ModelProviderError)?.message.contains("private input") == false)
                }
            }
        }
    }

    @Test(.enabled(if: modernNativeErrorsAvailable))
    func nativeRefusalSealsARefusalWithoutToolCalls() async throws {
        if #available(macOS 27, iOS 27, *) {
            let provider = AppleFoundationProvider { _ in
                throw LanguageModelError.refusal(.init(explanation: "private explanation", debugDescription: "private input"))
            }
            var accumulator = ModelEventAccumulator()
            for try await event in provider.stream(request: .init(model: AppleFoundationProvider.modelID, messages: [])) {
                try accumulator.append(event)
            }
            let response = try accumulator.finish()
            #expect(response.stopReason == .refusal)
            #expect(response.toolCalls.isEmpty)
            #expect(!response.content.contains { if case .text(let text) = $0 { text.contains("private") } else { false } })
        }
    }
}

private let modernNativeErrorsAvailable: Bool = {
    if #available(macOS 27, iOS 27, *) { return true }
    return false
}()
#endif
