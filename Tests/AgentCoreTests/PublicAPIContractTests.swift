import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

/// Compile-time fixtures that stand in for an external package client.
/// Stay on published Agent, Session, Run, Tool, and Provider types.
struct PublicAPIContractTests {
    @Test func configurationDefaultsMatchTheDocumentedContract() throws {
        let configuration = AgentConfiguration()
        #expect(configuration.instructions.isEmpty)
        #expect(configuration.structuredOutput == nil)
        #expect(configuration.maxModelTurns == 8)
        #expect(configuration.maxToolCalls == 16)
        #expect(configuration.runTimeout == .seconds(30))
        #expect(configuration.contextPolicy.maxInputUTF8Bytes == 8 * 1024 * 1024)
        #expect(configuration.contextPolicy.maxActiveHistoryUTF8Bytes == 12 * 1024 * 1024)
        #expect(configuration.contextPolicy.retainedRecentTurnCount == 6)
        #expect(configuration.contextPolicy.compactor == nil)
    }

    @Test func readOnlyAgentAcceptsNilMemoryAndDurableJournals() async throws {
        let agent = try PublicAPIReadOnlyClient.makeAgent()
        let nilSession = try agent.makeSession()
        #expect(try await nilSession.run("hello").wait().outcome == .completed)

        let memory = AgentJournal()
        #expect(memory.storage == .memory)
        let memorySession = try agent.makeSession(journal: memory)
        #expect(try await memorySession.run("hello").wait().outcome == .completed)

        let url = PublicAPIJournal.makeURL("read-only-durable")
        defer { PublicAPIJournal.cleanup(url) }
        let durable = try AgentJournal(persistenceURL: url)
        #expect(durable.storage == .durable)
        let durableSession = try agent.makeSession(journal: durable)
        #expect(try await durableSession.run("hello").wait().outcome == .completed)
    }

    @Test func mutationToolsFailFastWhenTheSessionHasNoJournal() throws {
        let probe = PublicAPISideEffectProbe()
        #expect(throws: AgentSessionError.durableJournalRequired) {
            _ = try PublicAPIMutationClient.makeAgent(probe: probe).makeSession()
        }
        #expect(probe.modelStarts == 0)
        #expect(probe.toolExecutions == 0)
    }

    @Test func mutationToolsFailFastWhenTheJournalIsMemoryOnly() async throws {
        let probe = PublicAPISideEffectProbe()
        let journal = AgentJournal()
        #expect(journal.storage == .memory)
        #expect(throws: AgentSessionError.durableJournalRequired) {
            _ = try PublicAPIMutationClient.makeAgent(probe: probe).makeSession(journal: journal)
        }
        #expect(probe.modelStarts == 0)
        #expect(probe.toolExecutions == 0)
        #expect(await journal.snapshot().isEmpty)
        #expect(await journal.pendingMutations().isEmpty)
    }

    @Test func mutationToolsAcceptADurableJournalAndAPersistedMemoryJournal() async throws {
        let url = PublicAPIJournal.makeURL("mutation-durable")
        defer { PublicAPIJournal.cleanup(url) }
        let durable = try AgentJournal(persistenceURL: url)
        #expect(durable.storage == .durable)
        _ = try PublicAPIMutationClient.makeSession(journal: durable)

        let upgradedURL = PublicAPIJournal.makeURL("mutation-persisted")
        defer { PublicAPIJournal.cleanup(upgradedURL) }
        let upgraded = AgentJournal()
        #expect(upgraded.storage == .memory)
        try await upgraded.persist(to: upgradedURL)
        #expect(upgraded.storage == .durable)
        _ = try PublicAPIMutationClient.makeSession(journal: upgraded)
    }

    @Test func agentInitializerFreezeKeepsInstructionsConvenienceOnly() throws {
        let model = PublicAPIReadOnlyClient.model
        let provider = EchoProvider()
        _ = try Agent(model: model, provider: provider, tools: [try SearchTool()], instructions: "Answer briefly.")
        _ = try Agent(
            model: model,
            provider: provider,
            tools: [try SearchTool()],
            configuration: AgentConfiguration(instructions: "Answer briefly.", maxModelTurns: 2)
        )
    }

    @Test func typedMutationPublishesAReceiptAndLeavesNoPendingWork() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-public-api-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try AgentJournal(persistenceURL: url)
        let run = try await PublicAPIMutationClient.makeSession(journal: journal).run("Update the listing")
        let result = try await run.wait()
        await run.waitForDrain()
        #expect(result.toolCalls == 1)
        #expect(result.receipts.count == 1)
        #expect(await journal.pendingMutations().isEmpty)
        var sawTerminal = false
        for await event in run.events {
            if case .runFinished(.result) = event { sawTerminal = true }
        }
        #expect(sawTerminal)
    }

    @Test func cancellationCompletesTheEventStreamWithoutASecondTerminal() async throws {
        let session = try PublicAPICancellableClient.makeSession()
        let run = try await session.run("work")
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        let events = await PublicAPIReadOnlyClient.collect(run.events)
        #expect(events.last == .runFinished(.cancelled))
        #expect(events.filter { if case .runFinished = $0 { true } else { false } }.count == 1)
    }

    @Test func durableRestartInspectsPendingMutationsThroughPublicJournalAPIs() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-public-api-restart-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try AgentJournal(persistenceURL: url)
        _ = try await PublicAPIMutationClient.makeSession(journal: journal).run("Update the listing").wait()
        let restarted = try AgentJournal.load(from: url)
        #expect(await restarted.pendingMutations().isEmpty)
        #expect(await restarted.recovery == .clean)
        let session = try PublicAPIMutationClient.makeSession(id: UUID(), journal: restarted)
        #expect(await session.activeRunID == nil)
    }

    @Test func failureTaxonomyIsTypedWithoutStringMatching() {
        let failure = AgentFailure.session(.durableJournalRequired)
        guard case .session(.durableJournalRequired) = failure else {
            Issue.record("SDK clients must switch on AgentFailure, not localizedDescription")
            return
        }
        #expect(AgentFailure.cancelled == .cancelled)
    }
}

enum PublicAPIJournal {
    static func makeURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-public-api-\(label)-\(UUID().uuidString).log")
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + ".lock")
    }
}

enum PublicAPIReadOnlyClient {
    static let model = ModelID(provider: "fixture", name: "public-api")

    static func makeAgent() throws -> Agent {
        try Agent(
            model: model,
            provider: EchoProvider(),
            tools: [try SearchTool()],
            configuration: AgentConfiguration(instructions: "Answer briefly.", runTimeout: .seconds(5))
        )
    }

    static func makeSession() throws -> AgentSession {
        try makeAgent().makeSession()
    }

    static func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
}

enum PublicAPIMutationClient {
    static func makeAgent(probe: PublicAPISideEffectProbe? = nil) throws -> Agent {
        try Agent(
            model: PublicAPIReadOnlyClient.model,
            provider: MutationProvider(probe: probe),
            tools: [try ListingUpdateTool(probe: probe)]
        )
    }

    static func makeSessionWithoutJournal() throws -> AgentSession {
        try makeAgent().makeSession()
    }

    static func makeSession(id: UUID = UUID(), journal: AgentJournal) throws -> AgentSession {
        try makeAgent().makeSession(id: id, journal: journal)
    }
}

final class PublicAPISideEffectProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var modelStartCount = 0
    private var toolExecutionCount = 0

    var modelStarts: Int {
        lock.lock()
        defer { lock.unlock() }
        return modelStartCount
    }

    var toolExecutions: Int {
        lock.lock()
        defer { lock.unlock() }
        return toolExecutionCount
    }

    func recordModel() {
        lock.lock()
        defer { lock.unlock() }
        modelStartCount += 1
    }

    func recordTool() {
        lock.lock()
        defer { lock.unlock() }
        toolExecutionCount += 1
    }
}

enum PublicAPICancellableClient {
    static func makeSession() throws -> AgentSession {
        try Agent(
            model: PublicAPIReadOnlyClient.model,
            provider: HangingProvider(),
            configuration: AgentConfiguration(runTimeout: .seconds(5))
        ).makeSession()
    }
}

struct EchoProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.streaming, .multiTurn, .tools])

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "echo", model: request.model)
            let text = request.messages.compactMap { message -> String? in
                if case .user(let content) = message, case .text(let value)? = content.first { return value }
                return nil
            }.last ?? ""
            try emit(.responseStarted(info))
            try emit(.textDelta(text))
            try emit(.responseCompleted(.init(info: info, content: [.text(text)], stopReason: .endTurn)))
        }
    }
}

struct MutationProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.streaming, .multiTurn, .tools])
    let probe: PublicAPISideEffectProbe?

    init(probe: PublicAPISideEffectProbe? = nil) {
        self.probe = probe
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            probe?.recordModel()
            let info = ResponseInfo(id: "mutation", model: request.model)
            if request.messages.contains(where: { $0.role == .tool }) {
                try emit(.responseStarted(info))
                try emit(.textDelta("Done"))
                try emit(.responseCompleted(.init(info: info, content: [.text("Done")], stopReason: .endTurn)))
                return
            }
            let call = ToolCall(
                id: .init(rawValue: "listing-1"),
                name: ListingUpdateTool.name,
                argumentsJSON: #"{"id":"listing-1"}"#,
                completeness: .complete
            )
            try emit(.responseStarted(info))
            try emit(.toolCallStarted(call.id, name: call.name))
            try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
            try emit(.toolCallCompleted(call))
            try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
        }
    }
}

struct HangingProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.streaming, .multiTurn])

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "hang", model: request.model)
            try emit(.responseStarted(info))
            try await Task.sleep(for: .seconds(30))
            try emit(.responseCompleted(.init(info: info, content: [.text("late")], stopReason: .endTurn)))
        }
    }
}

struct SearchTool: AgentTool {
    struct Input: Codable, Sendable { let query: String }
    struct Output: Codable, Sendable { let results: [String] }

    static let name = "search"
    static let description = "Search public records"
    static let inputSchema = ToolSchema.object(properties: ["query": .string], required: ["query"])
    static let outputSchema = ToolSchema.object(
        properties: ["results": .array(items: .string)], required: ["results"]
    )
    let policy: ToolPolicy

    init() throws {
        policy = try .readOnly(authorization: .notRequired)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        ToolResult(output: Output(results: [input.query]))
    }
}

struct ListingUpdateTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }

    static let name = "update_listing"
    static let description = "Update a listing"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let policy: ToolPolicy
    let probe: PublicAPISideEffectProbe?

    init(probe: PublicAPISideEffectProbe? = nil) throws {
        self.probe = probe
        policy = try .mutation(authorization: .notRequired, evidence: .none)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "listing", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "listing", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        probe?.recordTool()
        let receipt = ToolReceipt(
            operationID: context.idempotencyKey ?? "missing",
            status: .succeeded,
            confirmedTargets: [.init(namespace: "listing", id: input.id)],
            revision: "v2"
        )
        return ToolResult(output: .init(updated: true), receipt: receipt)
    }
}
