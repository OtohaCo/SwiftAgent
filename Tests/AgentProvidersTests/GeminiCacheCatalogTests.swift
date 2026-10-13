import AgentCatalog
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentProviders

struct GeminiCacheCatalogTests {
    @Test func explicitCacheFreezesFullPrefixAndOmitsOnlyCachedWireContent() async throws {
        let probe = ProviderRequestProbe(), credentials = GeminiCredentials(apiKey: { "key" })
        let client = try GeminiCachedContentClient(credentials: credentials, authorizationScopeID: "account",
            transport: FixtureHTTPTransport(probe: probe, bodies: [geminiCacheFixture, geminiTextFixture, Data("{}".utf8)]))
        let prefix = ModelRequest(model: geminiRequest.model, messages: [.system("Keep constraint"), .user([.text("Old input")]), .assistant(content: [.text("Old answer")], toolCalls: [])], tools: geminiToolRequest.tools)
        let binding = try await client.create(prefix: prefix, ttl: .seconds(60))
        let provider = try GeminiProvider(credentials: credentials, authorizationScopeID: "account", promptCaching: .explicit(binding),
            transport: FixtureHTTPTransport(probe: probe, bodies: [geminiCacheFixture, geminiTextFixture, Data("{}".utf8)]))
        let request = ModelRequest(model: prefix.model, messages: prefix.messages + [.user([.text("Next")])], tools: prefix.tools)
        _ = try await geminiResponse(provider, request)
        let requests = await probe.requests, create = try geminiHTTPBody(requests[0]), body = try geminiHTTPBody(requests[1])
        #expect(create["ttl"] == .string("60s") && create["contents"] != nil && create["tools"] != nil && create["systemInstruction"] != nil)
        #expect(body["cachedContent"] == .string(binding.resourceName))
        #expect(body["systemInstruction"] == nil && body["tools"] == nil)
        guard case .array(let contents) = body["contents"] else { Issue.record("Missing suffix"); return }
        #expect(contents.count == 1 && contents[0]["parts"] == .array([.object(["text": .string("Next")])]))
        for mismatch in [ModelRequest(model: prefix.model, messages: [.system("Changed")] + Array(request.messages.dropFirst()), tools: request.tools),
                         .init(model: prefix.model, messages: prefix.messages + [.user([.text("Next")])], tools: []),
                         .init(model: .init(provider: "gemini", name: "other"), messages: request.messages, tools: request.tools),
                         .init(model: prefix.model, messages: [.system("Keep constraint"), .user([.text("Projected")]), .assistant(content: [.text("Old answer")], toolCalls: []), .user([.text("Next")])], tools: request.tools)] {
            await #expect(throws: ModelProviderError.self) { _ = try await geminiResponse(provider, mismatch) }
        }
        let wrongAccount = try GeminiProvider(credentials: credentials, authorizationScopeID: "other", promptCaching: .explicit(binding),
            transport: FixtureHTTPTransport(probe: probe, bodies: []))
        await #expect(throws: ModelProviderError.self) { _ = try await geminiResponse(wrongAccount, request) }
        #expect(await probe.requests.count == 2)
        try await client.delete(binding)
        #expect(await probe.requests.last?.httpMethod == "DELETE")
        #expect(!String(reflecting: binding).contains("Old input"))
    }

    @Test func expiredCacheAndMissingRemoteResourceRequireHostRecovery() async throws {
        let probe = ProviderRequestProbe(), client = try GeminiCachedContentClient(credentials: .init(apiKey: { "key" }), authorizationScopeID: "account",
            transport: FixtureHTTPTransport(probe: probe, bodies: [geminiCacheFixture]))
        let binding = try await client.create(prefix: geminiRequest)
        let expired = GeminiCachedContentBinding(resourceName: binding.resourceName, expiresAt: .distantPast, model: binding.model,
            endpoint: binding.endpoint, authorizationScopeID: binding.authorizationScopeID, sourceMessages: binding.sourceMessages,
            contextWitness: binding.contextWitness, prefixCount: binding.prefixCount, prefixMessageCount: binding.prefixMessageCount)
        let next = ModelRequest(model: geminiRequest.model, messages: geminiRequest.messages + [.user([.text("Next")])])
        let local = try GeminiProvider(credentials: .init(apiKey: { "key" }), authorizationScopeID: "account", promptCaching: .explicit(expired), transport: FixtureHTTPTransport(probe: probe, bodies: []))
        await #expect(throws: ModelProviderError.self) { _ = try await geminiResponse(local, next) }
        #expect(await probe.requests.count == 1)
        let remoteProbe = ProviderRequestProbe(), remote = try GeminiProvider(credentials: .init(apiKey: { "key" }), authorizationScopeID: "account", promptCaching: .explicit(binding),
            transport: FixtureHTTPTransport(probe: remoteProbe, bodies: [Data("private URI/signature".utf8)], status: 404))
        do { _ = try await geminiResponse(remote, next); Issue.record("Missing resource cannot silently resend") }
        catch let error as ModelProviderError { #expect(error.kind == .invalidRequest && !error.message.contains("private")) }
        #expect(await remoteProbe.requests.count == 1)
    }

    @Test func cacheCreateBoundsAndIncompleteToolPrefixRejectWithoutHTTP() async throws {
        let probe = ProviderRequestProbe(), client = try GeminiCachedContentClient(credentials: .init(apiKey: { "key" }), authorizationScopeID: "account", maximumRequestBytes: 1,
            transport: FixtureHTTPTransport(probe: probe, bodies: []))
        await #expect(throws: ModelProviderError.self) { _ = try await client.create(prefix: geminiRequest) }
        await #expect(throws: ModelProviderError.self) { _ = try await client.create(prefix: geminiRequest, ttl: .milliseconds(1)) }
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }), transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [try geminiFixture(parts: geminiParallelParts)]))
        let response = try await geminiResponse(provider, geminiToolRequest)
        let ordinary = try GeminiCachedContentClient(credentials: .init(apiKey: { "key" }), authorizationScopeID: "account", transport: FixtureHTTPTransport(probe: probe, bodies: []))
        await #expect(throws: ModelProviderError.self) { _ = try await ordinary.create(prefix: .init(model: geminiRequest.model, messages: geminiRequest.messages + [.assistant(content: response.content, toolCalls: response.toolCalls)], tools: geminiToolRequest.tools)) }
        #expect(await probe.requests.isEmpty)
    }

    @Test func cursorAccountScopeUsesExactUTF8RatherThanCanonicalUnicodeEquivalence() async throws {
        let probe = ProviderRequestProbe()
        let first = Data(#"{"models":[],"nextPageToken":"next"}"#.utf8)
        let catalog = try GeminiModelCatalogProvider(credentials: .init(apiKey: { "key" }), serviceInstanceID: "fixture", authorizationScopeID: "é",
            transport: FixtureHTTPTransport(probe: probe, bodies: [first, Data(#"{"models":[]}"#.utf8)]))
        let page = try await catalog.listModels(.init())
        let changed = try GeminiModelCatalogProvider(credentials: .init(apiKey: { "key" }), serviceInstanceID: "fixture", authorizationScopeID: "e\u{301}",
            transport: FixtureHTTPTransport(probe: probe, bodies: [first, Data(#"{"models":[]}"#.utf8)]))
        await #expect(throws: ModelCatalogError(kind: .scopeMismatch)) { _ = try await changed.listModels(.init(cursor: page.nextCursor)) }
        #expect(await probe.requests.count == 1)
    }

    @Test func paginatedCatalogPreservesOrderAndUnknownCapabilitiesAndBindsCursorScope() async throws {
        let first = Data(#"{"models":[{"name":"models/second","displayName":"Second","inputTokenLimit":100,"outputTokenLimit":20,"supportedGenerationMethods":["generateContent"]},{"name":"models/embedding","supportedGenerationMethods":["embedContent"]},{"name":"models/first","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"opaque/+ token"}"#.utf8)
        let last = Data(#"{"models":[{"name":"models/last","supportedGenerationMethods":["generateContent"]}]}"#.utf8)
        let probe = ProviderRequestProbe(), tokens = PlanRotatingTokens()
        let catalog = try GeminiModelCatalogProvider(credentials: .init(apiKey: { await tokens.next() }), serviceInstanceID: "fixture", authorizationScopeID: "account",
            transport: FixtureHTTPTransport(probe: probe, bodies: [first, last]))
        let page = try await catalog.listModels(.init(pageSize: 3))
        #expect(page.models.map(\.model.name) == ["second", "first"])
        #expect(page.models[0].maximumInputTokens == 100 && page.models[0].capabilities == .unknown)
        let cursor = try #require(page.nextCursor)
        let final = try await catalog.listModels(.init(cursor: cursor, pageSize: 3))
        #expect(final.models.map(\.model.name) == ["last"] && final.nextCursor == nil)
        let requests = await probe.requests
        #expect(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pageToken" })?.value == "opaque/+ token")
        #expect(requests.map { $0.value(forHTTPHeaderField: "x-goog-api-key") } == ["fixture-1", "fixture-2"])
        let other = try GeminiModelCatalogProvider(credentials: .init(apiKey: { "key" }), serviceInstanceID: "fixture", authorizationScopeID: "other", transport: FixtureHTTPTransport(probe: probe, bodies: []))
        await #expect(throws: ModelCatalogError(kind: .scopeMismatch)) { _ = try await other.listModels(.init(cursor: cursor, pageSize: 3)) }
        await #expect(throws: ModelCatalogError(kind: .scopeMismatch)) { _ = try await catalog.listModels(.init(cursor: cursor, pageSize: 4)) }
        #expect(await probe.requests.count == 2)
    }
}
let geminiCacheFixture = Data(#"{"name":"cachedContents/resource-1","model":"models/fixture","expireTime":"2099-10-13T00:00:00Z"}"#.utf8)
