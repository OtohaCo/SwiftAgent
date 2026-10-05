import AgentModels
import Testing

struct ModelProviderDiagnosticTests {
    @Test func originalInitializerFunctionReferenceRemainsCompatible() {
        let original: (ModelProviderError.Kind, String, Duration?) -> ModelProviderError = ModelProviderError.init(kind:message:retryAfter:)
        let legacy = original(.invalidResponse, "Safe display", nil)
        let detailed = ModelProviderError(kind: legacy.kind, message: legacy.message,
            diagnostic: .init(stage: .server, reason: .serverFailure))
        #expect(legacy.diagnostic == nil)
        #expect(detailed.kind == legacy.kind && detailed.retryAfter == legacy.retryAfter)
        #expect(detailed != legacy) // Optional detail participates in value equality.
        #expect(legacy == .init(kind: .invalidResponse, message: "Safe display"))
    }
}
