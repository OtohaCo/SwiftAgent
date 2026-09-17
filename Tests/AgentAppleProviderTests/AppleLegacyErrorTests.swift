#if canImport(FoundationModels)
import AgentModels
import FoundationModels
import Testing
@testable import AgentAppleProvider

struct AppleLegacyErrorTests {
    @Test(.enabled(if: legacyNativeErrorsAvailable))
    func legacySDKFailuresRemainClassifiedAndGuardrailsRefuseWithoutCalls() async throws {
        if #available(macOS 26, iOS 26, *) {
            let context = LanguageModelSession.GenerationError.Context(debugDescription: "private input")
            let cases: [(LanguageModelSession.GenerationError, ModelProviderError.Kind)] = [
                (.rateLimited(context), .rateLimited), (.decodingFailure(context), .invalidResponse),
                (.unsupportedLanguageOrLocale(context), .unsupportedCapability),
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
            let provider = AppleFoundationProvider { _ in throw LanguageModelSession.GenerationError.guardrailViolation(context) }
            var accumulator = ModelEventAccumulator()
            for try await event in provider.stream(request: .init(model: AppleFoundationProvider.modelID, messages: [])) {
                try accumulator.append(event)
            }
            let response = try accumulator.finish()
            #expect(response.stopReason == .refusal)
            #expect(response.toolCalls.isEmpty)
        }
    }
}

private let legacyNativeErrorsAvailable: Bool = {
    if #available(macOS 26, iOS 26, *) { return true }
    return false
}()
#endif
