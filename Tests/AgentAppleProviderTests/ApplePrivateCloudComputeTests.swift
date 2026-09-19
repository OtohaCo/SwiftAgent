#if canImport(FoundationModels) && compiler(>=6.4)
import AgentModels
import Foundation
import FoundationModels
import Testing
@testable import AgentAppleProvider

struct ApplePrivateCloudComputeTests {
    @Test(.enabled(if: privateCloudComputeTestsAvailable))
    func privateCloudModelIdentityIsDistinctAndRequired() async throws {
        guard #available(macOS 27, iOS 27, *) else { return }
        let probe = GenerationProbe()
        let provider = AppleFoundationProvider(
            modelID: AppleFoundationProvider.privateCloudComputeModelID,
            generate: { _ in
                await probe.record()
                return .init(kind: .answer, text: "Cloud answer", toolCalls: [])
            }
        )

        let response = try await collect(
            provider,
            .init(model: AppleFoundationProvider.privateCloudComputeModelID, messages: [])
        )
        #expect(response.info.model == AppleFoundationProvider.privateCloudComputeModelID)
        #expect(response.content == [.text("Cloud answer")])

        await #expect(throws: ModelProviderError.self) {
            try await collect(provider, .init(model: AppleFoundationProvider.modelID, messages: []))
        }
        #expect(await probe.count == 1)
    }

    @Test(.enabled(if: privateCloudComputeTestsAvailable))
    func privateCloudErrorsAreClassifiedWithoutLeakingDiagnostics() async throws {
        guard #available(macOS 27, iOS 27, *) else { return }
        let cases: [(any Error, ModelProviderError.Kind)] = [
            (
                PrivateCloudComputeLanguageModel.Error.networkFailure(
                    .init(debugDescription: "private network details")
                ),
                .transport
            ),
            (
                PrivateCloudComputeLanguageModel.Error.serviceUnavailable(
                    .init(debugDescription: "private service details")
                ),
                .unavailable
            ),
            (
                PrivateCloudComputeLanguageModel.Error.quotaLimitReached(
                    .init(resetDate: Date(timeIntervalSinceNow: 60), debugDescription: "private quota details")
                ),
                .rateLimited
            ),
        ]

        for (nativeError, expectedKind) in cases {
            let provider = AppleFoundationProvider(
                modelID: AppleFoundationProvider.privateCloudComputeModelID,
                generate: { _ in throw nativeError }
            )
            do {
                _ = try await collect(
                    provider,
                    .init(model: AppleFoundationProvider.privateCloudComputeModelID, messages: [])
                )
                Issue.record("PCC failure must terminate the response")
            } catch {
                let failure = try #require(error as? ModelProviderError)
                #expect(failure.kind == expectedKind)
                #expect(!failure.message.contains("private"))
                if expectedKind == .rateLimited {
                    #expect(failure.retryAfter != nil)
                }
            }
        }
    }

    @Test(.enabled(if: privateCloudComputeTestsAvailable))
    func privateCloudFactoryRejectsInvalidTokenLimits() {
        guard #available(macOS 27, iOS 27, *) else { return }
        #expect(throws: ModelProviderError.self) {
            try AppleFoundationProvider.privateCloudCompute(maximumResponseTokens: 0)
        }
    }

    private func collect(
        _ provider: AppleFoundationProvider,
        _ request: ModelRequest
    ) async throws -> ModelResponse {
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: request) {
            try accumulator.append(event)
        }
        return try accumulator.finish()
    }
}

private actor GenerationProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private let privateCloudComputeTestsAvailable: Bool = {
    if #available(macOS 27, iOS 27, *) { return true }
    return false
}()
#endif
