import AgentCatalog
import AgentModels
import AgentProviders
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct ModelCatalogProviderTests {
    @Test func catalogHTTPFailuresAreClassifiedWithoutExposingTheBody() async throws {
        let provider = try OpenAIModelCatalogProvider(
            apiKey: "fixture-secret",
            endpoint: URL(string: "https://api.example.test/v1/models")!,
            serviceInstanceID: "openai-project",
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(),
                bodies: [Data("private diagnostic".utf8)],
                status: 429,
                headers: ["retry-after": "7"]
            )
        )

        do {
            _ = try await provider.listModels(.init())
            Issue.record("Expected a classified catalog failure")
        } catch let error as ModelCatalogError {
            #expect(error.kind == .rateLimited)
            #expect(error.retryAfter == .seconds(7))
            #expect(String(describing: error).contains("private diagnostic") == false)
        }
    }

    @Test func malformedAndOversizedCatalogResponsesFailClosed() async throws {
        let malformed = try OpenAIModelCatalogProvider(
            apiKey: "fixture-secret",
            endpoint: URL(string: "https://api.example.test/v1/models")!,
            serviceInstanceID: "malformed",
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(), bodies: [Data("{".utf8)], headers: ["Content-Type": "application/json"]
            )
        )
        await #expect(throws: ModelCatalogError(kind: .invalidResponse)) {
            try await malformed.listModels(.init())
        }

        let oversized = try OpenAIModelCatalogProvider(
            apiKey: "fixture-secret",
            endpoint: URL(string: "https://api.example.test/v1/models")!,
            serviceInstanceID: "oversized",
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(),
                bodies: [Data(repeating: 0x20, count: 2 * 1_024 * 1_024 + 1)],
                headers: ["Content-Type": "application/json"]
            )
        )
        await #expect(throws: ModelCatalogError(kind: .responseTooLarge)) {
            try await oversized.listModels(.init())
        }
    }

    @Test func cancellingCatalogRefreshCancelsTheTransportConsumer() async throws {
        let gate = CatalogCancellationGate()
        let provider = try OpenAIModelCatalogProvider(
            apiKey: "fixture-secret",
            endpoint: URL(string: "https://api.example.test/v1/models")!,
            serviceInstanceID: "cancelled",
            transport: BlockingCatalogTransport(gate: gate)
        )
        let task = Task { try await provider.listModels(.init()) }
        await gate.waitUntilStarted()
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        await gate.waitUntilCancelled()
    }

    @Test func openAIListAndDetailKeepUnreportedCapabilitiesUnknown() async throws {
        let probe = ProviderRequestProbe()
        let transport = FixtureHTTPTransport(probe: probe, bodies: [
            Data(#"{"object":"list","data":[{"id":"future-openai-model","object":"model","created":1,"owned_by":"openai"}]}"#.utf8),
            Data(#"{"id":"future-openai-model","object":"model","created":1,"owned_by":"openai"}"#.utf8),
        ], headers: ["Content-Type": "application/json"])
        let provider = try OpenAIModelCatalogProvider(
            apiKey: "fixture-secret",
            endpoint: URL(string: "https://api.example.test/v1/models")!,
            serviceInstanceID: "openai-project",
            authorizationScopeID: "project-a",
            transport: transport
        )

        let page = try await provider.listModels(.init())
        let detail = try await provider.modelDetails(deploymentID: "future-openai-model")

        #expect(page.models.map(\.model.name) == ["future-openai-model"])
        #expect(page.models[0].capabilities == .unknown)
        #expect(detail.model.name == "future-openai-model")
        let requests = await probe.requests
        #expect(requests.map(\.url?.absoluteString) == [
            "https://api.example.test/v1/models",
            "https://api.example.test/v1/models/future-openai-model",
        ])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret" })
    }

    @Test func openAIModelsPaginationUsesAfterAndLimitWithoutInventingCapabilities() async throws {
        let probe = ProviderRequestProbe()
        let transport = FixtureHTTPTransport(probe: probe, bodies: [
            Data(#"{"object":"list","data":[{"id":"model-a"}],"has_more":true,"last_id":"model-a"}"#.utf8),
            Data(#"{"object":"list","data":[{"id":"model-b"}],"has_more":false,"last_id":"model-b"}"#.utf8),
        ], headers: ["Content-Type": "application/json"])
        let provider = try OpenAIModelCatalogProvider(
            apiKey: "fixture-secret",
            endpoint: URL(string: "https://api.example.test/v1/models?api-version=2026-01")!,
            serviceInstanceID: "openai-project",
            transport: transport
        )

        let first = try await provider.listModels(.init(pageSize: 1))
        let second = try await provider.listModels(.init(cursor: first.nextCursor, pageSize: 1))

        #expect(first.models.map(\.model.name) == ["model-a"])
        #expect(first.nextCursor == "model-a")
        #expect(second.models.map(\.model.name) == ["model-b"])
        #expect(second.nextCursor == nil)
        #expect(provider.scope.endpointScope.contains("api-version=2026-01"))
        let requests = await probe.requests
        #expect(requests.map(\.url?.absoluteString) == [
            "https://api.example.test/v1/models?api-version=2026-01&limit=1",
            "https://api.example.test/v1/models?api-version=2026-01&after=model-a&limit=1",
        ])
    }

    @Test func anthropicPaginationAndNullableCapabilitiesPreserveUnknown() async throws {
        let probe = ProviderRequestProbe()
        let body = #"{"data":[{"id":"claude-future","display_name":"Claude Future","created_at":"2026-09-20T00:00:00Z","type":"model","capabilities":{"effort":{"supported":true,"values":["low","high","future"]},"structured_outputs":{"supported":true},"thinking":{"supported":true,"types":["adaptive","enabled"]}},"max_input_tokens":200000,"max_tokens":64000},{"id":"claude-unknown","display_name":"Claude Unknown","created_at":"2026-09-20T00:00:00Z","type":"model","capabilities":null,"max_input_tokens":null,"max_tokens":null}],"has_more":true,"first_id":"claude-future","last_id":"claude-unknown"}"#
        let provider = try AnthropicModelCatalogProvider(
            apiKey: "fixture-secret",
            endpoint: URL(string: "https://api.example.test/v1/models?api-version=2026-01")!,
            serviceInstanceID: "anthropic-workspace",
            authorizationScopeID: "workspace-a",
            transport: FixtureHTTPTransport(
                probe: probe, bodies: [Data(body.utf8)], headers: ["Content-Type": "application/json"]
            )
        )

        let page = try await provider.listModels(.init(cursor: "after-model", pageSize: 2))

        #expect(page.nextCursor == "claude-unknown")
        #expect(page.models[0].capabilities.reasoning == .supported)
        #expect(page.models[0].capabilities.configurableReasoning == .supported)
        #expect(page.models[0].capabilities.structuredOutput == .supported)
        #expect(page.models[0].capabilities.tools == .unknown)
        #expect(page.models[0].reasoningControls.map(\.kind) == [.effort, .thinkingMode, .tokenBudget])
        #expect(page.models[0].reasoningControls[0].allowedValues == ["low", "high", "future"])
        #expect(page.models[0].reasoningControls[0].valuesAreExhaustive == false)
        #expect(page.models[0].reasoningControls[0].executability == .executable)
        #expect(page.models[0].reasoningControls[1].executability == .executable)
        #expect(page.models[0].reasoningControls[2].integerRange == .init(minimum: 1_024, maximum: 63_999))
        #expect(page.models[0].reasoningControls[2].requires == ["thinking.type": .string("enabled")])
        #expect(page.models[1].capabilities == .unknown)
        let request = try #require(await probe.requests.first)
        #expect(provider.scope.endpointScope.contains("api-version=2026-01"))
        #expect(request.url?.query?.contains("api-version=2026-01") == true)
        #expect(request.url?.query?.contains("after_id=after-model") == true)
        #expect(request.url?.query?.contains("limit=2") == true)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func unknownAnthropicThinkingModeIsDiscoverableButNotAutomaticallyExecutable() async throws {
        let body = #"{"data":[{"id":"claude-future","display_name":"Claude Future","capabilities":{"thinking":{"supported":true,"types":["adaptive","future-mode"]}},"max_input_tokens":200000,"max_tokens":64000}],"has_more":false,"last_id":"claude-future"}"#
        let provider = try AnthropicModelCatalogProvider(
            apiKey: "fixture-secret",
            endpoint: URL(string: "https://api.example.test/v1/models")!,
            serviceInstanceID: "anthropic-workspace",
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(), bodies: [Data(body.utf8)], headers: ["Content-Type": "application/json"]
            )
        )

        let model = try #require(try await provider.listModels(.init()).models.first)
        let control = try #require(model.reasoningControls.first)

        #expect(control.allowedValues == ["adaptive", "future-mode"])
        #expect(control.executability == .adapterUpgradeRequired)
    }

    @Test func anthropicThinkingBudgetWithoutAUsableRangeIsNotAutomaticallyExecutable() async throws {
        let body = #"{"data":[{"id":"claude-small-output","capabilities":{"thinking":{"supported":true,"types":["enabled"]}},"max_tokens":1024}],"has_more":false,"last_id":"claude-small-output"}"#
        let provider = try AnthropicModelCatalogProvider(
            apiKey: "fixture-secret",
            endpoint: URL(string: "https://api.example.test/v1/models")!,
            serviceInstanceID: "anthropic-workspace",
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(), bodies: [Data(body.utf8)], headers: ["Content-Type": "application/json"]
            )
        )

        let model = try #require(try await provider.listModels(.init()).models.first)
        let budget = try #require(model.reasoningControls.first(where: { $0.kind == .tokenBudget }))

        #expect(budget.support == .supported)
        #expect(budget.integerRange == nil)
        #expect(budget.executability == .adapterUpgradeRequired)
    }

    @Test func deepSeekListUsesItsOwnShapeAndDoesNotInventCapabilities() async throws {
        let probe = ProviderRequestProbe()
        let provider = try DeepSeekModelCatalogProvider(
            apiKey: "fixture-secret",
            endpoint: URL(string: "https://api.deepseek.example/models")!,
            serviceInstanceID: "deepseek-primary",
            authorizationScopeID: "account-a",
            transport: FixtureHTTPTransport(
                probe: probe,
                bodies: [Data(#"{"object":"list","data":[{"id":"deepseek-future","object":"model","owned_by":"deepseek"}]}"#.utf8)],
                headers: ["Content-Type": "application/json"]
            )
        )

        let page = try await provider.listModels(.init())

        #expect(page.models.map(\.model.name) == ["deepseek-future"])
        #expect(page.models[0].capabilities == .unknown)
        #expect(page.models[0].reasoningControls.isEmpty)
        let request = try #require(await probe.requests.first)
        #expect(request.url?.absoluteString == "https://api.deepseek.example/models")
        #expect(request.httpMethod == "GET")
    }
}

private actor CatalogCancellationGate {
    private var started = false
    private var cancelled = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelledWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func markCancelled() {
        cancelled = true
        let waiters = cancelledWaiters
        cancelledWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancelledWaiters.append($0) }
    }
}

private struct BlockingCatalogTransport: ProviderHTTPTransport {
    let gate: CatalogCancellationGate

    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                await gate.markStarted()
                continuation.yield(.response(status: 200, headers: ["Content-Type": "application/json"]))
                do {
                    try await Task.sleep(for: .seconds(60))
                    continuation.finish()
                } catch {
                    await gate.markCancelled()
                    continuation.finish(throwing: CancellationError())
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }
}
