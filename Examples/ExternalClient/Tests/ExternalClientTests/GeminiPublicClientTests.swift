import AgentCatalog
import AgentDecisions
import AgentJevProvider
import AgentUsage
import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentProviders
import AgentTools
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XCTest

/// Public-only native Gemini Host fixture. Opaque fixture signatures are not vendor validation.
struct GeminiPublicClientTests {
    @Test func preFileBindingAndStoreFactoriesKeepExactFunctionTypes() {
        let binding: (String, String, ModelID, any ModelProvider, AgentModelDeployment,
                      [String: JSONValue], any AgentContextProjector, AgentContextTokenBudget?,
                      AgentContextReportBuffer?, AgentLegacyContinuationPolicy, AgentImageInputPolicy) throws -> AgentModelBinding = AgentModelBinding.init
        let native: (String, String, ModelID, any ModelProvider, AgentModelDeployment,
                     [String: JSONValue], any AgentContextProjector, AgentContextTokenBudget?,
                     AgentContextReportBuffer?, AgentLegacyContinuationPolicy, AgentImageInputPolicy,
                     AgentNativeContextPolicy?) throws -> AgentModelBinding = AgentModelBinding.init
        let scoped: (String, String, ModelID, any ModelProvider, AgentModelDeployment,
                     [String: JSONValue], any AgentContextProjector, AgentContextTokenBudget?,
                     AgentContextReportBuffer?, AgentLegacyContinuationPolicy, AgentImageInputPolicy,
                     AgentNativeContextPolicy?, String) throws -> AgentModelBinding = AgentModelBinding.init
        let oldCreate: (URL, String, JournalMaintenancePolicy, Bool, Bool, Bool, Bool, Bool, Bool) throws -> AgentJournal = AgentIncrementalJournal.create
        let nativeCreate: (URL, String, JournalMaintenancePolicy, Bool, Bool, Bool, Bool, Bool, Bool, Bool) throws -> AgentJournal = AgentIncrementalJournal.create
        let handoff: (URL, String, JournalMaintenancePolicy, Bool) throws -> AgentJournal = AgentIncrementalJournal.create
        _ = (binding, native, scoped, oldCreate, nativeCreate, handoff)
    }

    @Test func attachmentsSignedParallelToolsAndReopenPreserveCanonicalFacts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-client-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = PublicGeminiProbe(), projector = PublicGeminiProjector()
        let provider = try GeminiProvider(credentials: .init(apiKey: { "public-key" }), preservedThinking: .requireCurrentTurnFunctionSignatures,
            transport: PublicGeminiTransport(probe: probe))
        let binding = try AgentModelBinding(profileID: "gemini-public", profileRevision: "1", model: .init(provider: "gemini", name: "fixture"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture-account", endpointScope: GeminiProvider.defaultBaseURL.absoluteString, apiDialect: "gemini-generate-content"),
            projector: projector, tokenBudget: .init(maximumContextTokens: 10_000, reservedOutputTokens: 1000, estimator: PublicFileEstimator()),
            imageInput: .native(), fileInput: .native())
        let agent = try Agent(binding: binding, tools: [try PublicGeminiTool(probe: probe)], configuration: .init(instructions: "Keep this constraint"))
        let journal = try await AgentIncrementalJournal.createAsync(at: directory, operationDomain: "public-gemini", supportsFileContent: true)
        let id = UUID(), session = try agent.makeSession(id: id, journal: journal)
        let file = try ModelFileReference(uri: URL(string: "https://files.example/immutable.pdf")!, mediaType: .pdf, description: "report", estimatedInputTokens: 2000)
        let image = try ModelImage(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!, description: "pixel")
        let input = try AgentRunInput(text: "Read and echo", attachments: [.file(file), .image(image)])
        let run = try await session.run(input, correlation: .init(key: "one", payloadDigest: "host"))
        #expect(try await run.wait().outcome == .completed); try await run.waitForDrain()
        #expect(await probe.executions == ["a", "b"])
        #expect(await projector.turns == [1, 2]) // Validated first preflight is reused, not projected twice.
        let history = try #require(try await journal.latestCheckpoint(sessionID: id)).history
        #expect(history.first == .user([.text(input.text), .file(file), .image(image)]))
        #expect(history.filter { if case .tool = $0 { return true }; return false }.count == 2)
        let record = try await session.runRecord(runID: run.id)
        guard case .terminal(_, .completed) = record else { Issue.record("Run record missing completed"); return }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: id)?.history == history)
        let fresh = try agent.makeSession(id: id, journal: reopened)
        let next = try await fresh.run("Continue"); #expect(try await next.wait().outcome == .completed); try await next.waitForDrain()
        #expect(try await fresh.runRecord(runID: run.id) == record)
        #expect(await probe.executions == ["a", "b"])
        let final = try #require(try await reopened.latestCheckpoint(sessionID: id)).history
        #expect(Array(final.prefix(history.count)) == history && final.flatMap(\.files) == [file])
        let requests = await probe.requests
        #expect(requests.count == 3)
        let first = try JSONDecoder().decode(JSONValue.self, from: #require(requests[0].httpBody))
        let second = try JSONDecoder().decode(JSONValue.self, from: #require(requests[1].httpBody))
        guard case .array(let contents1) = first["contents"], case .array(let contents2) = second["contents"],
              case .array(let originalParts) = contents1[0]["parts"], case .array(let modelParts) = contents2[1]["parts"],
              case .array(let results) = contents2[2]["parts"] else { Issue.record("Native part arrays missing"); return }
        #expect(originalParts[1]["fileData"]?["fileUri"] == .string(file.uri.absoluteString))
        #expect(originalParts[2]["inlineData"] != nil)
        #expect(modelParts[1]["thoughtSignature"] == .string("c2ln") && modelParts.last?["text"] == .string(""))
        #expect(results.count == 2 && results.allSatisfy { $0["functionResponse"] != nil && $0["text"] == nil })
        #expect(second["systemInstruction"] == first["systemInstruction"])
        try await reopened.close()
    }

    @Test func cancelledLateCredentialCannotDispatchAndPhysicalDrainWaits() async throws {
        let entered = XCTestExpectation(description: "Gemini credential callback"), gate = PublicGeminiCredentialGate(entered: entered), probe = PublicGeminiProbe()
        let provider = try GeminiProvider(credentials: .init(apiKey: { await gate.token() }), transport: PublicGeminiTransport(probe: probe))
        let run = try await Agent(model: .init(provider: "gemini", name: "fixture"), provider: provider).makeSession().run("Hi")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed)
        await run.cancel(); await #expect(throws: CancellationError.self) { try await run.wait() }
        let premature = XCTestExpectation(description: "drain before callback returned"); premature.isInverted = true
        let waiter = Task { try await run.waitForDrain(); premature.fulfill() }
        #expect(await XCTWaiter.fulfillment(of: [premature], timeout: 0.1) == .completed)
        await gate.release(); try await waiter.value
        #expect(await probe.requests.isEmpty)
    }

    @Test func explicitCachePreparationIsOutsideRunAndPreservesCanonicalPrefix() async throws {
        let probe = PublicGeminiCacheProbe(), transport = PublicGeminiCacheTransport(probe: probe), credentials = GeminiCredentials(apiKey: { "key" })
        let client = try GeminiCachedContentClient(credentials: credentials, authorizationScopeID: "selected-account", transport: transport)
        let prefix = ModelRequest(model: .init(provider: "gemini", name: "fixture"), messages: [.system("Keep"), .user([.text("Old")]), .assistant(content: [.text("Answer")], toolCalls: [])])
        let binding = try await client.create(prefix: prefix, ttl: .seconds(60))
        let provider = try GeminiProvider(credentials: credentials, authorizationScopeID: "selected-account", promptCaching: .explicit(binding), transport: transport)
        let request = ModelRequest(model: prefix.model, messages: prefix.messages + [.user([.text("Next")])])
        var accumulator = ModelEventAccumulator(); for try await event in provider.stream(request: request) { try accumulator.append(event) }
        #expect(try accumulator.finish().stopReason == .endTurn)
        #expect(Array(request.messages.prefix(prefix.messages.count)) == prefix.messages)
        let requests = await probe.requests, body = try JSONDecoder().decode(JSONValue.self, from: #require(requests[1].httpBody))
        #expect(body["cachedContent"] == .string(binding.resourceName) && body["systemInstruction"] == nil)
        try await client.delete(binding)
        #expect(await probe.requests.count == 3)
    }
}

private actor PublicGeminiProjector: AgentContextProjector {
    private(set) var turns: [Int] = []
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        turns.append(input.modelTurn)
        return .init(messages: input.canonicalMessages, plan: .init(projectionID: "public-source", version: "1",
            sourceRevision: input.conversationRevision, sourceDigest: try input.sourceDigest(), contextEpoch: input.contextEpoch, lossy: false))
    }
}
private struct PublicFileEstimator: AgentContextTokenEstimator {
    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        .init(inputTokens: 500 + input.messages.flatMap(\.files).reduce(0) { $0 + $1.estimatedInputTokens }, accuracy: .estimated)
    }
}
private actor PublicGeminiProbe {
    private(set) var requests: [URLRequest] = []
    private(set) var executions: [String] = []
    func record(_ request: URLRequest) -> Int { requests.append(request); return requests.count }
    func execute(_ value: String) { executions.append(value); executions.sort() }
}
private struct PublicGeminiTool: AgentTool {
    struct Input: Codable, Sendable { let text: String }
    struct Output: Codable, Sendable { let text: String }
    static let name = "echo", description = "Echo"
    static let inputSchema = ToolSchema.object(properties: ["text": .string], required: ["text"])
    static let outputSchema = inputSchema
    let policy: ToolPolicy; let probe: PublicGeminiProbe
    init(probe: PublicGeminiProbe) throws { self.probe = probe; policy = try .init(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(2), authorization: .notRequired) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> { await probe.execute(input.text); return .init(output: .init(text: input.text)) }
}
private struct PublicGeminiTransport: ProviderHTTPTransport {
    let probe: PublicGeminiProbe
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let turn = await probe.record(request)
                let parts = turn == 1 ? #"[{"text":"think","thought":true},{"functionCall":{"name":"echo","args":{"text":"a"},"id":"native-a"},"thoughtSignature":"c2ln"},{"functionCall":{"name":"echo","args":{"text":"b"}}},{"text":"","thoughtSignature":"ZW1wdHk="}]"# : #"[{"text":"done","thoughtSignature":"c2ln"}]"#
                let body = "data: {\"responseId\":\"r\(turn)\",\"candidates\":[{\"index\":0,\"content\":{\"role\":\"model\",\"parts\":\(parts)},\"finishReason\":\"STOP\"}]}\n\n"
                continuation.yield(.response(status: 200, headers: [:])); continuation.yield(.data(Data(body.utf8))); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
private actor PublicGeminiCredentialGate {
    let entered: XCTestExpectation; private var pending: CheckedContinuation<String, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func token() async -> String { await withCheckedContinuation { pending = $0; entered.fulfill() } }
    func release() { pending?.resume(returning: "late-key"); pending = nil }
}
private actor PublicGeminiCacheProbe { private(set) var requests: [URLRequest] = []; func record(_ value: URLRequest) { requests.append(value) } }
private struct PublicGeminiCacheTransport: ProviderHTTPTransport {
    let probe: PublicGeminiCacheProbe
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.record(request)
                let body: String
                if request.httpMethod == "DELETE" { body = "{}" }
                else if request.url?.lastPathComponent == "cachedContents" { body = #"{"name":"cachedContents/public-1","model":"models/fixture","expireTime":"2099-10-13T00:00:00Z"}"# }
                else { body = "data: {\"responseId\":\"r\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"done\"}]},\"finishReason\":\"STOP\"}]}\n\n" }
                continuation.yield(.response(status: 200, headers: [:])); continuation.yield(.data(Data(body.utf8))); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension JSONValue {
    subscript(key: String) -> JSONValue? { if case .object(let fields) = self { return fields[key] }; return nil }
}
