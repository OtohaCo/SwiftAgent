import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

/// Package-level consumer of the public Agent, Tool, Provider, and recovery API.
struct ExternalClientTests {
    @Test func readOnlyAgentRunsWithoutAJournal() async throws {
        let session = try makeReadOnlyAgent().makeSession()
        let result = try await session.run("hello").wait()
        #expect(result.outcome == .completed)
    }

    @Test func mutationAgentRejectsAMemoryJournalBeforeAnyModelCall() async throws {
        let probe = SideEffectProbe()
        let journal = AgentJournal()
        #expect(journal.storage == .memory)
        #expect(throws: AgentSessionError.durableJournalRequired) {
            _ = try makeMutationAgent(probe: probe).makeSession(journal: journal)
        }
        #expect(probe.modelStarts == 0)
        #expect(probe.toolExecutions == 0)
        #expect(await journal.snapshot().isEmpty)
        #expect(await journal.pendingMutations().isEmpty)
    }

    @Test func mutationAgentRecoversThroughThePublicJournalAPI() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-external-client-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try AgentJournal(persistenceURL: url)
        #expect(journal.storage == .durable)
        let sessionID = UUID()
        let run = try await makeMutationAgent().makeSession(id: sessionID, journal: journal).run("Update the listing")
        let result = try await run.wait()
        try await run.waitForDrain()
        #expect(result.receipts.count == 1)
        #expect(await journal.pendingMutations().isEmpty)

        let restarted = try AgentJournal.load(from: url)
        #expect(await restarted.pendingMutations().isEmpty)
        #expect(await restarted.recovery == .clean)
        _ = try makeMutationAgent().makeSession(id: sessionID, journal: restarted)
    }
}

private func makeReadOnlyAgent() throws -> Agent {
    try Agent(
        model: ModelID(provider: "external-client", name: "echo"),
        provider: EchoProvider(),
        tools: [try SearchTool()],
        instructions: "Answer briefly."
    )
}

private func makeMutationAgent(probe: SideEffectProbe? = nil) throws -> Agent {
    try Agent(
        model: ModelID(provider: "external-client", name: "echo"),
        provider: MutationProvider(probe: probe),
        tools: [try ListingUpdateTool(probe: probe)]
    )
}

private final class SideEffectProbe: @unchecked Sendable {
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

private struct EchoProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "external-client", capabilities: [.streaming, .multiTurn, .tools])

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

private struct MutationProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "external-client", capabilities: [.streaming, .multiTurn, .tools])
    let probe: SideEffectProbe?

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

private struct SearchTool: AgentTool {
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

private struct ListingUpdateTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }

    static let name = "update_listing"
    static let description = "Update a listing"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let policy: ToolPolicy
    let probe: SideEffectProbe?

    init(probe: SideEffectProbe? = nil) throws {
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
