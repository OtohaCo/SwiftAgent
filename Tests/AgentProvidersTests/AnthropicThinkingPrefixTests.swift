import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentProviders

struct AnthropicThinkingPrefixTests {
    private let model = ModelID(provider: "anthropic", name: "fixture")

    @Test func unchangedNativePrefixContinuesAndRejectsToolResetOrEditedPast() async throws {
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "k", transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicThinkingToolFixture, anthropicTextFixture]))
        let tools = [ModelToolDefinition(name: "calculator", description: "Add", inputSchema: .object(["type": .string("object")]))]
        let pastCall = ToolCall(id: .init(rawValue: "past"), name: "calculator", argumentsJSON: "{}", completeness: .complete)
        let prefix: [ModelMessage] = [.system("fixed"), .user([.text("old task")]), .assistant(content: [], toolCalls: [pastCall]), .tool(.init(callID: pastCall.id, content: [.text("long prior result")], isError: false)), .user([.text("Compute")])]
        var accumulated = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(model: model, messages: prefix, tools: tools)) { try accumulated.append(event) }
        let response = try accumulated.finish()
        let tail: [ModelMessage] = [.assistant(content: response.content, toolCalls: response.toolCalls), .tool(.init(callID: response.toolCalls[0].id, content: [.text("5")], isError: false))]
        let unchanged = ModelRequest(model: model, messages: prefix + tail, tools: tools)
        try provider.validate(request: unchanged)
        for try await _ in provider.stream(request: unchanged) {}
        #expect(await probe.requests.count == 2)
        var excerpted = prefix
        excerpted[3] = .tool(.init(callID: pastCall.id, content: [.text("excerpt")], isError: false))
        let rejected = [
            ModelRequest(model: model, messages: prefix + tail, tools: []), // next Run resets declarations
            ModelRequest(model: model, messages: excerpted + tail, tools: tools),
            ModelRequest(model: model, messages: [.system("fixed"), .user([.text("summary")])] + tail, tools: tools),
        ]
        for request in rejected {
            #expect(throws: ModelProviderError.self) { try provider.validate(request: request) }
            do { for try await _ in provider.stream(request: request) {}; Issue.record("Changed thinking prefix dispatched") }
            catch let error as ModelProviderError { #expect(error.kind == .invalidRequest) }
        }
        #expect(await probe.requests.count == 2)
    }

    @Test func legacyThinkingWithoutWitnessIsRefusedButUnsignedToolChangesAreAccepted() async throws {
        let blocks: [JSONValue] = [.object(["type": .string("thinking"), "thinking": .string("thought"), "signature": .string("opaque-fixture")]), .object(["type": .string("text"), "text": .string("answer")])]
        let state = try AnthropicContinuation.make(blocks: blocks, model: model)
        let request = ModelRequest(model: model, messages: [.user([.text("before")]), .assistant(content: [.reasoning("thought"), .text("answer"), .providerContinuation(state)], toolCalls: []), .user([.text("next")])])
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "k", transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture]))
        do { for try await _ in provider.stream(request: request) {}; Issue.record("Legacy signed thinking lacks witness") }
        catch let error as ModelProviderError { #expect(error.kind == .invalidRequest) }
        #expect(await probe.requests.isEmpty)
        let unsigned = ModelRequest(model: model, messages: [.user([.text("summary of old history")])], tools: [.init(name: "expanded", description: "new declaration", inputSchema: .object(["type": .string("object")]))])
        for try await _ in provider.stream(request: unsigned) {}
        #expect(await probe.requests.count == 1)
    }

    @Test func subsequentRunRestoringInitialDeclarationsRefusesBeforeAdmission() async throws {
        let probe = ProviderRequestProbe(), execution = ProviderExecutionProbe()
        let provider = try AnthropicProvider(apiKey: "k", transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicThinkingToolFixture, anthropicTextFixture]))
        let session = try Agent(model: model, provider: provider).makeSession()
        let expanded = try await session.bindCapabilities(identity: "expanded", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [
            .init(id: "calculator", version: "1", tool: try ProviderCalculator(probe: execution)),
            .init(id: "extra", version: "1", tool: try ExtraPrefixTool()),
        ])
        let first = try await session.run("Compute", capabilities: expanded)
        _ = try await first.wait()
        try await first.waitForDrain()
        let before = await session.history
        let initial = try await session.bindCapabilities(identity: "initial", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [
            .init(id: "calculator", version: "1", tool: try ProviderCalculator(probe: execution)),
            .init(id: "extra", version: "1", tool: try ExtraPrefixTool(), exposure: .deferred),
        ])
        do { _ = try await session.run("Next Run", capabilities: initial); Issue.record("Reset declarations must be refused") }
        catch let error as ModelProviderError { #expect(error.kind == .invalidRequest) }
        #expect(await session.history == before)
        #expect(await execution.count == 1)
        #expect(await probe.requests.count == 2)
    }

    @Test func toolDeclarationExpansionRefusesNextRequestWithoutRepeatingExecution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rc6-thinking-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "thinking-prefix")
        let probe = ProviderRequestProbe(), execution = ProviderExecutionProbe()
        let provider = try AnthropicProvider(apiKey: "k", transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicThinkingToolFixture]))
        let id = UUID()
        let session = try Agent(model: model, provider: provider).makeSession(id: id, journal: journal)
        let capabilities = try await session.bindCapabilities(identity: "fixture", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [
            .init(id: "calculator", version: "1", tool: try DeclaringCalculator(probe: execution)),
            .init(id: "extra", version: "1", tool: try ExtraPrefixTool(), exposure: .deferred),
        ])
        let run = try await session.run("Compute", capabilities: capabilities)
        do { _ = try await run.wait(); Issue.record("Expanded tools with bound thinking should fail") }
        catch let error as ModelProviderError { #expect(error.kind == .invalidRequest) }
        try await run.waitForDrain()
        #expect(await execution.count == 1)
        #expect(await probe.requests.count == 1)
        let history = await session.history
        #expect(history.contains { if case .tool = $0 { true } else { false } })
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let fresh = try Agent(model: model, provider: provider).makeSession(id: id, journal: reopened)
        let persisted = try await fresh.conversationSnapshot()
        #expect(persisted.messages == history)
        try await reopened.close()
    }
}

private struct DeclaringCalculator: AgentTool {
    typealias Input = ProviderCalculator.Input
    typealias Output = ProviderCalculator.Output
    static let name = "calculator"
    static let description = "Add and discover another tool"
    static let inputSchema = ProviderCalculator.inputSchema
    static let outputSchema = ProviderCalculator.outputSchema
    let policy: ToolPolicy
    let probe: ProviderExecutionProbe
    init(probe: ProviderExecutionProbe) throws { self.probe = probe; policy = try .readOnly(authorization: .notRequired) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.record()
        return .init(output: .init(sum: input.a + input.b), declaredTools: ["extra"])
    }
}

private struct ExtraPrefixTool: AgentTool {
    typealias Input = ProviderCalculator.Input
    typealias Output = ProviderCalculator.Output
    static let name = "extra"
    static let description = "Deferred extra calculator"
    static let inputSchema = ProviderCalculator.inputSchema
    static let outputSchema = ProviderCalculator.outputSchema
    let policy: ToolPolicy
    init() throws { policy = try .readOnly(authorization: .notRequired) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> { .init(output: .init(sum: input.a + input.b)) }
}
