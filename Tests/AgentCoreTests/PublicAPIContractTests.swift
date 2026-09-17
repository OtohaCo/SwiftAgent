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
    }

    @Test func readOnlyAgentDoesNotRequireAJournal() async throws {
        let session = try PublicAPIReadOnlyClient.makeSession()
        let result = try await session.run("hello").wait()
        #expect(result.outcome == .completed)
        #expect(result.response.content == [.text("hello")])
    }

    @Test func mutationToolsFailFastWhenTheSessionHasNoJournal() throws {
        #expect(throws: AgentSessionError.durableJournalRequired) {
            _ = try PublicAPIMutationClient.makeSessionWithoutJournal()
        }
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

enum PublicAPIReadOnlyClient {
    static let model = ModelID(provider: "fixture", name: "public-api")

    static func makeSession() throws -> AgentSession {
        try Agent(
            model: model,
            provider: EchoProvider(),
            tools: [try SearchTool()],
            configuration: AgentConfiguration(instructions: "Answer briefly.", runTimeout: .seconds(5))
        ).makeSession()
    }

    static func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
}

enum PublicAPIMutationClient {
    static func makeSessionWithoutJournal() throws -> AgentSession {
        try Agent(
            model: PublicAPIReadOnlyClient.model,
            provider: MutationProvider(),
            tools: [try ListingUpdateTool()]
        ).makeSession()
    }

    static func makeSession(id: UUID = UUID(), journal: AgentJournal) throws -> AgentSession {
        try Agent(
            model: PublicAPIReadOnlyClient.model,
            provider: MutationProvider(),
            tools: [try ListingUpdateTool()]
        ).makeSession(id: id, journal: journal)
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

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
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

    init() throws {
        policy = try .mutation(authorization: .notRequired, evidence: .none)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "listing", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "listing", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let receipt = ToolReceipt(
            operationID: context.idempotencyKey ?? "missing",
            status: .succeeded,
            confirmedTargets: [.init(namespace: "listing", id: input.id)],
            revision: "v2"
        )
        return ToolResult(output: .init(updated: true), receipt: receipt)
    }
}
