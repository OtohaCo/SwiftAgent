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
        do {
            try await anthropicIdleCompactThenReminder(thinking: .serviceDefault)
            try await anthropicIdleCompactThenReminder(thinking: .betweenTools)
        }
        catch { throw ExampleFailure.phase("Anthropic", String(describing: error)) }
        do { try await openAIAutomaticToolLoopAndReopen() }
        catch { throw ExampleFailure.phase("OpenAI", String(describing: error)) }
        return "Native public fixture passed: catalog selection, compact→new user/reminder→discovery, immutable thinking, automatic compaction/tool loop, next Run, FileStore reopen; no live calls"
    }
    /// Native authority is explicitly retired without changing any persisted message.
    public static func ordinaryHandoff() async throws {
        var phase = "setup"
        do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ordinary-handoff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let oldHTTP = FixtureExchange([Fixtures.anthropicAnswer, Fixtures.anthropicCompact])
        let oldProvider = try AnthropicProvider(apiKey: "fixture", nativeContext: .init(qualification: .init(
            endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]), runReminders: true), transport: oldHTTP)
        let oldBinding = try AgentModelBinding(profileID: "old", profileRevision: "1", model: .init(provider: "anthropic", name: "fixture"), provider: oldProvider,
            deployment: .init(serviceInstanceID: "old", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"))
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "handoff", supportsContextHandoff: true)
        let session = try Agent(binding: oldBinding).makeSession(journal: journal)
        phase = "initial Run"
        try await finish(try await session.run("keep this constraint", contextControls: .init(reminder: "old reminder")))
        phase = "compact"
        let compact = try await session.compact(mode: .anthropicOnDemand)
        _ = try await compact.wait(); try await compact.waitForDrain()
        let canonical = await session.history
        let oldCheckpoint = try await journal.nativeContextCheckpoint(sessionID: session.id)
        let newHTTP = FixtureExchange([Fixtures.anthropicAnswer, Fixtures.anthropicCompact, Fixtures.anthropicAnswer])
        let newProvider = try AnthropicProvider(apiKey: "fixture", nativeContext: .init(qualification: .init(
            endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]), runReminders: true), transport: newHTTP)
        let span = try await session.contextHistorySpan(start: 0, count: 2)
        let projector = RetiredPrefixSummaryProjector(span: span)
        let newBinding = try AgentModelBinding(profileID: "new", profileRevision: "2", model: .init(provider: "anthropic", name: "fixture"), provider: newProvider,
            deployment: .init(serviceInstanceID: "new", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"), projector: projector)
        phase = "handoff"
        let operation = try await session.handoffToOrdinary(using: newBinding, discardingRetiredProviderContinuations: true)
        let retirement = try await operation.wait(); try await operation.waitForDrain()
        guard retirement.canonicalMessageCount == 2, await session.history == canonical, newHTTP.requests.isEmpty,
              retirement.retiredNativeCheckpointID == oldCheckpoint?.id else { throw ExampleFailure.invariant }
        phase = "target Run"
        try await finish(try await session.run("new real input", contextControls: .init(reminder: "new reminder"), using: newBinding))
        let body = String(decoding: newHTTP.requests[0].httpBody!, as: UTF8.self)
        guard body.contains("keep this constraint"), body.contains("new reminder"), !body.contains("old reminder"), !body.contains("compaction") else { throw ExampleFailure.invariant }
        let newChainBinding = try AgentModelBinding(profileID: "new", profileRevision: "2", model: newBinding.model, provider: newProvider,
            deployment: .init(serviceInstanceID: "new", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"))
        phase = "new native chain"
        let newCompact = try await session.compact(mode: .anthropicOnDemand, using: newChainBinding)
        let newCheckpoint = try await newCompact.wait().checkpoint; try await newCompact.waitForDrain()
        guard let newCheckpoint, newCheckpoint.generation == 1, newCheckpoint.id != oldCheckpoint?.id,
              newCheckpoint.transition.source.previousCheckpointID == nil else { throw ExampleFailure.invariant }
        let after = await session.history, id = session.id
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        phase = "reopen"
        let fresh = try Agent(binding: newChainBinding).makeSession(id: id, journal: reopened)
        guard try await fresh.conversationSnapshot().messages == after else { throw ExampleFailure.invariant }
        try await finish(try await fresh.run("reopened", contextControls: .init(reminder: "latest reminder")))
        guard newHTTP.requests.count == 3, oldHTTP.requests.count == 2 else { throw ExampleFailure.invariant }
        try await reopened.close()
        } catch { throw ExampleFailure.phase(phase, String(describing: error)) }
    }

    public static func thinkingAcrossOrdinaryHandoff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thinking-handoff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let oldCompact = Data(String(decoding: Fixtures.anthropicCompact, as: UTF8.self).replacingOccurrences(of: #""tool_changes":[]"#,
            with: #""tool_changes":[{"type":"tool_addition","tool":{"type":"tool_reference","name":"extra"}}]"#).utf8)
        let oldHTTP = FixtureExchange([Fixtures.anthropicThinkingDiscovery, Fixtures.anthropicAnswer, oldCompact])
        let oldProvider = try AnthropicProvider(apiKey: "fixture", nativeContext: .init(qualification: .init(
            endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]), inlineToolChanges: true, runReminders: true), transport: oldHTTP)
        let oldBinding = try AgentModelBinding(profileID: "old-thinking", profileRevision: "1", model: .init(provider: "anthropic", name: "fixture"), provider: oldProvider,
            deployment: .init(serviceInstanceID: "old-thinking", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"))
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "thinking-handoff", supportsContextHandoff: true)
        let session = try Agent(binding: oldBinding).makeSession(journal: journal)
        let oldExecutions = ExecutionCounter(), newExecutions = ExecutionCounter()
        let oldCaps = try await session.bindCapabilities(identity: "old", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [
            .init(id: "discover", version: "1", tool: DiscoveryTool(counter: oldExecutions)), .init(id: "extra", version: "1", tool: ExtraTool(), exposure: .deferred)])
        try await finish(try await session.run("old tool Run", contextControls: .init(reminder: "old reminder"), capabilities: oldCaps))
        let compact = try await session.compact(mode: .anthropicOnDemand); _ = try await compact.wait(); try await compact.waitForDrain()
        let canonical = await session.history
        guard let retiredPayload = canonical.compactMap({ message -> ModelProviderContinuation? in
            guard case .assistant(let content, _) = message else { return nil }
            return content.compactMap { if case .providerContinuation(let value) = $0 { value } else { nil } }.first
        }).first else { throw ExampleFailure.invariant }
        let malicious = try AgentModelBinding(profileID: "old-thinking", profileRevision: "1", model: oldBinding.model, provider: oldProvider,
            deployment: .init(serviceInstanceID: "old-thinking", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"),
            projector: ReinsertRetiredThinking(cutoff: 4, retired: retiredPayload))
        let firstExit = try await session.handoffToOrdinary(using: malicious, capabilities: oldCaps, discardingRetiredProviderContinuations: true)
        _ = try await firstExit.wait(); try await firstExit.waitForDrain()
        do {
            _ = try await session.run("must not admit reinserted thinking", contextControls: .init(reminder: "new"), using: malicious, capabilities: oldCaps)
            throw ExampleFailure.invariant
        } catch AgentModelBindingError.invalidProjection { }
        guard oldHTTP.requests.count == 3, await session.history == canonical else { throw ExampleFailure.invariant }
        func wire(_ body: Data) -> Data { Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: #""model":"fixture""#, with: #""model":"new-fixture""#).replacingOccurrences(of: "discovery-call", with: "new-discovery-call").utf8) }
        let newHTTP = FixtureExchange([wire(Fixtures.anthropicThinkingDiscovery), wire(Fixtures.anthropicAnswer), wire(Fixtures.anthropicAnswer), wire(Fixtures.anthropicAnswer)])
        let newProvider = try AnthropicProvider(apiKey: "fixture", nativeContext: .init(qualification: .init(
            endpoint: endpoint, resolvedModelNames: ["new-fixture"], modes: [.anthropicOnDemand]), inlineToolChanges: true, runReminders: true), transport: newHTTP)
        let target = try AgentModelBinding(profileID: "new-thinking", profileRevision: "2", model: .init(provider: "anthropic", name: "new-fixture"), provider: newProvider,
            deployment: .init(serviceInstanceID: "new-thinking", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"))
        func capabilities(_ owner: AgentSession) async throws -> AgentCapabilityBinding {
            try await owner.bindCapabilities(identity: "new", version: "2", backendInstanceID: "fixture", backendVersion: "2", allowedResources: [.global], tools: [
                .init(id: "discover", version: "2", tool: DiscoveryTool(counter: newExecutions, discover: false))])
        }
        let caps = try await capabilities(session)
        let operation = try await session.handoffToOrdinary(using: target, capabilities: caps, discardingRetiredProviderContinuations: true)
        let retired = try await operation.wait(); try await operation.waitForDrain()
        guard retired.canonicalMessageCount == 4, await session.history == canonical, newHTTP.requests.isEmpty else { throw ExampleFailure.invariant }
        try await finish(try await session.run("new tool Run", contextControls: .init(reminder: "new reminder"), using: target, capabilities: caps))
        guard newHTTP.requests.count == 2, await oldExecutions.count == 1, await newExecutions.count == 1 else { throw ExampleFailure.invariant }
        let first = String(decoding: newHTTP.requests[0].httpBody!, as: UTF8.self)
        let continued = String(decoding: newHTTP.requests[1].httpBody!, as: UTF8.self)
        guard !first.contains("fixture-thinking-signature"), !first.contains("compaction"), !first.contains("old reminder"),
              continued.components(separatedBy: "fixture-thinking-signature").count == 2 else { throw ExampleFailure.invariant }
        try await finish(try await session.run("next Run", contextControls: .init(reminder: "next reminder"), using: target, capabilities: caps))
        let after = await session.history, id = session.id
        guard Array(after.prefix(canonical.count)) == canonical else { throw ExampleFailure.invariant }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let fresh = try Agent(binding: target).makeSession(id: id, journal: reopened)
        guard try await fresh.conversationSnapshot().messages == after else { throw ExampleFailure.invariant }
        try await finish(try await fresh.run("reopened", contextControls: .init(reminder: "latest reminder"), capabilities: capabilities(fresh)))
        guard newHTTP.requests.count == 4, await oldExecutions.count == 1, await newExecutions.count == 1,
              String(decoding: newHTTP.requests[3].httpBody!, as: UTF8.self).components(separatedBy: "fixture-thinking-signature").count == 2 else { throw ExampleFailure.invariant }
        try await reopened.close()
    }

    /// Queue resolver controls use the normal admission path, with real encoded HTTP fixtures.
    public static func queuedReminders(cancelBeforeDispatch: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queued-reminder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let executions = ExecutionCounter()
        let secondTool = Data(String(decoding: Fixtures.anthropicThinkingDiscovery, as: UTF8.self).replacingOccurrences(of: "discovery-call", with: "queued-second-call").utf8)
        let exchange = FixtureExchange([Fixtures.anthropicThinkingDiscovery, Fixtures.anthropicAnswer, secondTool, Fixtures.anthropicAnswer])
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let provider = try AnthropicProvider(apiKey: "fixture", nativeContext: .init(
            qualification: .init(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]), inlineToolChanges: true, runReminders: true), transport: exchange)
        let gate = QueueProjectionGate()
        let projector: any AgentContextProjector = cancelBeforeDispatch ? gate : AgentIdentityContextProjector()
        let binding = try AgentModelBinding(profileID: "queued", profileRevision: "1", model: .init(provider: "anthropic", name: "fixture"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"), projector: projector)
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "queued", supportsNativeContext: true)
        let session = try Agent(binding: binding).makeSession(journal: journal)
        let id = session.id
        for number in 1...2 {
            _ = try await session.enqueueFollowUp(.init(inputID: "queued-\(number)", text: "real user \(number)", identity: .perCall, configurationRef: "v1"))
        }
        let finished = QueueRunCapture()
        let dispatch = try await session.startFollowUpDispatch(policy: .init(runTimeout: .seconds(10)), resolver: QueueReminderResolver(session: session, binding: binding, executions: executions), onRun: { _, run in
            do { try await finish(run); await finished.record(nil) }
            catch { await finished.record(String(describing: error)) }
        })
        if cancelBeforeDispatch {
            await gate.waitEntered()
            await dispatch.stop()
            await gate.release()
            try await dispatch.waitForDrain()
            guard exchange.requests.isEmpty, await session.history.isEmpty,
                  try await journal.readMessages(sessionID: id).isEmpty,
                  try await session.followUp(inputID: "queued-1")?.state == .queued,
                  try await session.followUp(inputID: "queued-2")?.state == .queued else { throw ExampleFailure.invariant }
            try await journal.close()
            let reopened = try AgentIncrementalJournal.open(at: directory)
            guard try await reopened.latestCheckpoint(sessionID: id) == nil else { throw ExampleFailure.invariant }
            try await reopened.close()
            return
        }
        try await finished.waitForTwo()
        await dispatch.stop(); try await dispatch.waitForDrain()
        guard exchange.requests.count == 4, await executions.count == 2 else { throw ExampleFailure.invariant }
        for (index, request) in exchange.requests.enumerated() {
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            let number = index / 2 + 1
            guard body.contains("reminder \(number)"), body.contains("real user \(number)"), body.contains("next_user_message") else { throw ExampleFailure.invariant }
        }
        let canonical = await session.history
        guard canonical.filter({ $0.role == .user }).count == 2, canonical.filter({ $0.role == .assistant }).count == 4, canonical.filter({ $0.role == .tool }).count == 2 else { throw ExampleFailure.invariant }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        guard try await reopened.latestCheckpoint(sessionID: id)?.history == canonical else { throw ExampleFailure.invariant }
        try await reopened.close()
    }

    private static func finish(_ run: AgentRun) async throws {
        guard try await run.wait().outcome == .completed else { throw ExampleFailure.invariant }
        try await run.waitForDrain()
    }
    private static func anthropicIdleCompactThenReminder(thinking: AnthropicThinking) async throws {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-host-anthropic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelName = "claude-sonnet-5-5"
        func wire(_ data: Data, prior: Bool = false) -> Data {
            Data(String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\"model\":\"fixture\"", with: "\"model\":\"\(modelName)\"")
                .replacingOccurrences(of: "discovery-call", with: prior ? "prior-discovery-call" : "discovery-call").utf8)
        }
        // Native summary faithfully retains the trusted deferred-tool addition.
        let compactFixture = Data(String(decoding: Fixtures.anthropicCompact, as: UTF8.self)
            .replacingOccurrences(of: #""tool_changes":[]"#,
                with: #""tool_changes":[{"type":"tool_addition","tool":{"type":"tool_reference","name":"extra"}}]"#).utf8)
        let exchange = FixtureExchange([wire(Fixtures.anthropicThinkingDiscovery, prior: true), wire(Fixtures.anthropicAnswer), wire(compactFixture),
            wire(Fixtures.anthropicThinkingDiscovery), wire(Fixtures.anthropicAnswer), wire(Fixtures.anthropicAnswer)])
        let provider = try AnthropicProvider(apiKey: "fixture-never-sent-to-network", thinking: thinking,
            nativeContext: .init(qualification: .init(endpoint: endpoint, resolvedModelNames: [modelName], modes: [.anthropicOnDemand]),
                                 inlineToolChanges: true, runReminders: true), transport: exchange)
        let model = ModelID(provider: "anthropic", name: modelName)
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
        try await finish(try await session.run(original, contextControls: .init(reminder: "上一轮请用中文回答"), capabilities: caps))
        let before = await session.history
        // Prior Run/tool work has physically drained; this is its own invocation.
        let operation = try await session.compact(mode: .anthropicOnDemand)
        let compact = try await operation.wait(); try await operation.waitForDrain()
        guard compact.checkpoint != nil, compact.response.usage.inputTokens == 1000,
              await session.history == before else { throw ExampleFailure.invariant }
        let controls = try AgentRunContextControls(reminder: "本轮请用中文回答")
        try await finish(try await session.run("discover", contextControls: controls, capabilities: caps))
        let requests = exchange.requests
        guard requests.count == 5, await executions.count == 2,
              !String(decoding: requests[3].httpBody!, as: UTF8.self).contains(original),
              String(decoding: requests[4].httpBody!, as: UTF8.self).contains("fixture-thinking-signature"),
              String(decoding: requests[4].httpBody!, as: UTF8.self).contains("tool_addition"),
              String(decoding: requests[4].httpBody!, as: UTF8.self).contains("next_user_message") else { throw ExampleFailure.invariant }
        for request in requests {
            guard let fields = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any] else { throw ExampleFailure.invariant }
            if thinking == .serviceDefault { guard fields["thinking"] == nil else { throw ExampleFailure.invariant } }
            else { guard (fields["thinking"] as? [String: String]) == ["type": "between_tools"] else { throw ExampleFailure.invariant } }
        }
        let canonical = await session.history, id = session.id
        guard canonical.contains(.user([.text(original)])), canonical.contains(where: { if case .tool = $0 { true } else { false } }) else { throw ExampleFailure.invariant }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let fresh = try agent.makeSession(id: id, journal: reopened)
        guard try await fresh.conversationSnapshot().messages == canonical else { throw ExampleFailure.invariant }
        try await finish(try await fresh.run("after reopen", contextControls: controls, capabilities: capabilities(fresh)))
        guard exchange.requests.count == 6, await executions.count == 2,
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

private struct QueueReminderResolver: AgentFollowUpResolver {
    let session: AgentSession
    let binding: AgentModelBinding
    let executions: ExecutionCounter
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        let capabilities = try await session.bindCapabilities(identity: "queue", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [.init(id: "discover", version: "1", tool: DiscoveryTool(counter: executions, discover: false))])
        let number = request.record.inputID == "queued-1" ? 1 : 2
        return .init(model: binding, capabilities: capabilities, contextControls: try .init(reminder: "reminder \(number)"))
    }
}
private actor QueueRunCapture {
    private var results: [String?] = []
    func record(_ error: String?) { results.append(error) }
    func waitForTwo() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while results.count < 2 {
            guard ContinuousClock.now < deadline else { throw ExampleFailure.phase("queue observer", "two Runs did not finish") }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard results.allSatisfy({ $0 == nil }) else { throw ExampleFailure.invariant }
    }
}
private actor QueueProjectionGate: AgentContextProjector {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        entered = true; observers.forEach { $0.resume() }; observers.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
        return try await AgentIdentityContextProjector().project(input)
    }
    func waitEntered() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private struct RetiredPrefixSummaryProjector: AgentContextSourceReferencing {
    let span: AgentContextHistorySpan
    var historySpans: [AgentContextHistorySpan] { [span] }
    var toolResultCallIDs: [ToolCallID] { [] }
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        let formal = input.canonicalMessages.drop(while: { $0.role == .system || $0.role == .developer })
        if formal.count <= span.start + span.messageIDs.count { return try await AgentIdentityContextProjector().project(input) }
        return try await AgentCompositeContextProjector(summaries: [.init(span: span, generatorVersion: "deterministic-v1", text: "keep this constraint")]).project(input)
    }
}

private struct ReinsertRetiredThinking: AgentContextProjector {
    let cutoff: Int
    let retired: ModelProviderContinuation
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        let identity = try await AgentIdentityContextProjector().project(input)
        let formal = input.canonicalMessages.drop(while: { $0.role == .system || $0.role == .developer })
        guard formal.count > cutoff else { return identity }
        let altered = ModelProviderContinuation(model: retired.model, format: retired.format,
            payload: Data((" \n" + String(decoding: retired.payload, as: UTF8.self)).utf8), origin: retired.origin,
            contextTransition: retired.contextTransition, requestBoundary: retired.requestBoundary)
        var messages = identity.messages
        guard let index = messages.firstIndex(where: { $0.role == .assistant }), case .assistant(let content, let calls) = messages[index] else { throw ExampleFailure.invariant }
        messages[index] = .assistant(content: content + [.providerContinuation(altered)], toolCalls: calls)
        return .init(messages: messages, plan: identity.plan)
    }
}
