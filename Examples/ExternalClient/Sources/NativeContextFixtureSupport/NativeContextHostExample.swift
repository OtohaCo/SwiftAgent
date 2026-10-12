import AgentCatalog
import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentProviders
import AgentTools
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public SDK only. Actual encoder/decoder with local fragmented HTTP responses;
/// all signatures/ciphertext are fixture material, not live qualification.
public enum NativeContextHostExample {
    public static func run() async throws -> String {
        do { try await anthropicIdleCompactThenReminder() }
        catch { throw ExampleFailure.phase("Anthropic", String(describing: error)) }
        do { try await openAIAutomaticToolLoopAndReopen() }
        catch { throw ExampleFailure.phase("OpenAI", String(describing: error)) }
        return "Native public fixture passed: catalog selection, compact→new user/reminder→discovery, immutable thinking, automatic compaction/tool loop, next Run, FileStore reopen; no live calls"
    }
    private static func finish(_ run: AgentRun) async throws {
        guard try await run.wait().outcome == .completed else { throw ExampleFailure.invariant }
        try await run.waitForDrain()
    }
    private static func anthropicIdleCompactThenReminder() async throws {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-host-anthropic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let exchange = FixtureExchange([Fixtures.anthropicAnswer, Fixtures.anthropicCompact,
            Fixtures.anthropicThinkingDiscovery, Fixtures.anthropicAnswer, Fixtures.anthropicAnswer])
        let provider = try AnthropicProvider(apiKey: "fixture-never-sent-to-network", thinking: .adaptive,
            nativeContext: .init(qualification: .init(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]),
                                 inlineToolChanges: true, runReminders: true), transport: exchange)
        let model = ModelID(provider: "anthropic", name: "fixture")
        let binding = try AgentModelBinding(profileID: "native-host", profileRevision: "catalog-v1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: "qualified-fixture", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"))
        let agent = try Agent(binding: binding)
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "native-host", supportsNativeContext: true)
        let session = try agent.makeSession(journal: journal)
        let executions = ExecutionCounter()
        func capabilities(_ session: AgentSession) async throws -> AgentCapabilityBinding {
            try await session.bindCapabilities(identity: "trusted", version: "1", backendInstanceID: "fixture", backendVersion: "1",
                allowedResources: [.global], tools: [
                    .init(id: "discover", version: "1", tool: DiscoveryTool(counter: executions)),
                    .init(id: "extra", version: "1", tool: ExtraTool(), exposure: .deferred)])
        }
        let caps = try await capabilities(session)
        let original = "covered source " + String(repeating: "x", count: 4096)
        try await finish(try await session.run(original, capabilities: caps))
        let before = await session.history
        // Prior Run/tool work has physically drained; this is its own invocation.
        let operation = try await session.compact(mode: .anthropicOnDemand)
        let compact = try await operation.wait(); try await operation.waitForDrain()
        guard compact.checkpoint != nil, compact.response.usage.inputTokens == 1000,
              await session.history == before else { throw ExampleFailure.invariant }
        let controls = try AgentRunContextControls(reminder: "本轮请用中文回答")
        try await finish(try await session.run("discover", contextControls: controls, capabilities: caps))
        let requests = exchange.requests
        guard requests.count == 4, await executions.count == 1,
              !String(decoding: requests[2].httpBody!, as: UTF8.self).contains(original),
              String(decoding: requests[3].httpBody!, as: UTF8.self).contains("fixture-thinking-signature"),
              String(decoding: requests[3].httpBody!, as: UTF8.self).contains("tool_addition"),
              String(decoding: requests[3].httpBody!, as: UTF8.self).contains("next_user_message") else { throw ExampleFailure.invariant }
        let canonical = await session.history, id = session.id
        guard canonical.contains(.user([.text(original)])), canonical.contains(where: { if case .tool = $0 { true } else { false } }) else { throw ExampleFailure.invariant }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let fresh = try agent.makeSession(id: id, journal: reopened)
        guard try await fresh.conversationSnapshot().messages == canonical else { throw ExampleFailure.invariant }
        try await finish(try await fresh.run("after reopen", contextControls: controls, capabilities: capabilities(fresh)))
        guard exchange.requests.count == 5, await executions.count == 1,
              String(decoding: exchange.requests.last!.httpBody!, as: UTF8.self).contains("tool_removal") else { throw ExampleFailure.invariant }
        try await reopened.close()

        // Catalog support does not grant this unconfigured proxy beta capabilities.
        let unqualified = try AnthropicProvider(apiKey: "fixture", transport: FixtureExchange([]))
        let unqualifiedBinding = try AgentModelBinding(profileID: "proxy", profileRevision: "1", model: model, provider: unqualified,
            deployment: .init(serviceInstanceID: "proxy", endpointScope: "https://proxy.invalid", apiDialect: "anthropic"))
        let unsupported = try Agent(binding: unqualifiedBinding).makeSession()
        do { _ = try await unsupported.compact(mode: .anthropicOnDemand); throw ExampleFailure.invariant }
        catch let error as ModelProviderError { guard error.kind == .unsupportedCapability else { throw error } }
    }

    private static func openAIAutomaticToolLoopAndReopen() async throws {
        let endpoint = URL(string: "https://api.openai.com/v1/responses")!
        let source = ModelCatalogSource(kind: .hostOverride, reference: "fictional-fixture", revision: "catalog-v1")
        let scope = try ModelServiceScope(provider: "openai", serviceInstanceID: "fixture", endpointScope: endpoint.absoluteString, apiDialect: "responses")
        let description = try ModelCompactionDescriptor(mode: .openAIAutomatic, support: .supported,
            minimumTriggerInputTokens: 1000, sources: [source], executability: .executable)
        let model = ModelID(provider: "openai", name: "fixture")
        let catalog = ModelCatalogEntry(model: model, deploymentID: "fixture", serviceScope: scope, sources: [source],
            promptPricing: nil, compaction: .init(support: .supported, modes: [description]))
        guard let selected = catalog.compaction?.modes.first, selected.support == .supported,
              selected.executability == .executable else { throw ExampleFailure.invariant }
        // Host selects a trigger. Adapter rechecks its protocol minimum; metadata
        // cannot lower it. Hard request budgets are configured separately.
        let automatic = try ModelAutomaticCompaction(mode: selected.mode, triggerInputTokens: 1000)
        let exchange = FixtureExchange([Fixtures.openAIAutomaticTool, Fixtures.openAIAnswer, Fixtures.openAIAnswer, Fixtures.openAIAnswer])
        let provider = try OpenAIResponsesProvider(apiKey: "fixture", nativeContext: .init(
            qualification: .init(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.openAIAutomatic]), automatic: automatic), transport: exchange)
        let binding = try AgentModelBinding(profileID: "catalog-native", profileRevision: "catalog-v1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: scope.serviceInstanceID, endpointScope: scope.endpointScope, apiDialect: scope.apiDialect))
        let executions = ExecutionCounter(), tool = try DiscoveryTool(counter: executions, discover: false)
        let agent = try Agent(binding: binding, tools: [tool])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-host-openai-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "native-openai", supportsNativeContext: true)
        let session = try agent.makeSession(journal: journal)
        let original = "full source " + String(repeating: "y", count: 4096)
        let run = try await session.run(original)
        var observedNativeUsage = false
        for await event in run.events {
            if case .model(.usage(let usage)) = event, usage.inputTokens == 100 { observedNativeUsage = true }
        }
        try await finish(run)
        guard exchange.requests.count == 2, await executions.count == 1, observedNativeUsage,
              !String(decoding: exchange.requests[1].httpBody!, as: UTF8.self).contains(original),
              String(decoding: exchange.requests[1].httpBody!, as: UTF8.self).contains("function_call_output"),
              String(decoding: exchange.requests[1].httpBody!, as: UTF8.self).contains("opaque-openai-window") else { throw ExampleFailure.invariant }
        try await finish(try await session.run("next Run"))
        let canonical = await session.history, id = session.id
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let fresh = try agent.makeSession(id: id, journal: reopened)
        guard try await fresh.conversationSnapshot().messages == canonical else { throw ExampleFailure.invariant }
        try await finish(try await fresh.run("reopened Run"))
        guard exchange.requests.count == 4, await executions.count == 1,
              !String(decoding: exchange.requests.last!.httpBody!, as: UTF8.self).contains(original),
              String(decoding: exchange.requests.last!.httpBody!, as: UTF8.self).contains("opaque-openai-window") else { throw ExampleFailure.invariant }
        try await reopened.close()
    }
}

private enum ExampleFailure: Error { case invariant, exhaustedFixture, phase(String, String) }
private actor ExecutionCounter { var count = 0; func record() { count += 1 } }
private struct DiscoveryTool: AgentTool {
    struct Input: Codable, Sendable { let value: Int }
    struct Output: Codable, Sendable { let value: Int }
    static let name = "discover"
    static let description = "Read and discover an already bound tool"
    static let inputSchema = ToolSchema.object(properties: ["value": .integer], required: ["value"])
    static let outputSchema = inputSchema
    let policy: ToolPolicy
    let counter: ExecutionCounter
    let discover: Bool
    init(counter: ExecutionCounter, discover: Bool = true) throws { self.counter = counter; self.discover = discover; policy = try .readOnly(authorization: .notRequired) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await counter.record()
        return .init(output: .init(value: input.value), declaredTools: discover ? ["extra"] : [])
    }
}
private struct ExtraTool: AgentTool {
    typealias Input = DiscoveryTool.Input
    typealias Output = DiscoveryTool.Output
    static let name = "extra"
    static let description = "A trusted deferred reader"
    static let inputSchema = DiscoveryTool.inputSchema
    static let outputSchema = DiscoveryTool.outputSchema
    let policy: ToolPolicy
    init() throws { policy = try .readOnly(authorization: .notRequired) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> { .init(output: .init(value: input.value)) }
}
private final class FixtureExchange: ProviderHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [Data]
    private var sent: [URLRequest] = []
    init(_ bodies: [Data]) { remaining = bodies }
    var requests: [URLRequest] { lock.withLock { sent } }
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        let body: Data? = lock.withLock { sent.append(request); return remaining.isEmpty ? nil : remaining.removeFirst() }
        return AsyncThrowingStream { c in
            guard let body else { c.finish(throwing: ExampleFailure.exhaustedFixture); return }
            c.yield(.response(status: 200, headers: ["content-type": "text/event-stream"]))
            for offset in stride(from: 0, to: body.count, by: 7) { c.yield(.data(body.subdata(in: offset..<min(offset + 7, body.count)))) }
            c.finish()
        }
    }
}
