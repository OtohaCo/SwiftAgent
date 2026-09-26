import AgentCore
import AgentJournalFileStore
import AgentDecisions
import AgentModels
import AgentTools
import Foundation
import Testing

struct DecisionSafetyBoundaryTests {
    @Test func certainDecisionCannotBypassEvidenceOrReachMutationExecutor() async throws {
        let decision = try await CertainDecisionProvider().decide(try .init(
            state: .string("update account-1"),
            nouls: ["proceed": .init(instructions: .string("Should the update be proposed?"))]
        ))
        #expect(decision.nouls["proceed"]?.probability == 1)

        let probe = DecisionMutationProbe()
        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-decision-boundary-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: journalURL)
            try? FileManager.default.removeItem(atPath: journalURL.path + ".lock")
        }
        let journal = try AgentIncrementalJournal.create(at: journalURL, operationDomain: "decision-tests")
        let agent = try Agent(
            model: .init(provider: "fixture", name: "decision-boundary"),
            provider: DecisionMutationModelProvider(),
            tools: [try EvidenceProtectedMutationTool(probe: probe)]
        )

        await #expect(throws: EvidenceError.self) {
            try await agent.makeSession(journal: journal).run("Apply the proposal").wait()
        }
        #expect(probe.executions == 0)
        #expect(try await journal.pendingMutations().isEmpty)
    }
}

private struct CertainDecisionProvider: DecisionProvider {
    let descriptor = DecisionProviderDescriptor(id: "fixture-decision")

    func decide(_ request: DecisionRequest) async throws -> DecisionResponse {
        DecisionResponse(model: "fixture-decision", nouls: ["proceed": .init(probability: 1)])
    }
}

private struct DecisionMutationModelProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.multiTurn, .tools])

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "decision-boundary", model: request.model)
            let call = ToolCall(
                id: .init(rawValue: "update-account-1"),
                name: EvidenceProtectedMutationTool.name,
                argumentsJSON: #"{"id":"account-1"}"#,
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

private final class DecisionMutationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var executionCount = 0
    var executions: Int { lock.withLock { executionCount } }
    func record() { lock.withLock { executionCount += 1 } }
}

private struct EvidenceProtectedMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }

    static let name = "update_account"
    static let description = "Update an observed account"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])

    let policy: ToolPolicy
    let probe: DecisionMutationProbe

    init(probe: DecisionMutationProbe) throws {
        self.probe = probe
        policy = try .mutation(authorization: .notRequired, evidence: .required)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "account", id: input.id))]
    }

    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        [.init(reference: .init(namespace: "account", id: input.id), scope: .sameSession)]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "account", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        probe.record()
        return ToolResult(
            output: .init(updated: true),
            receipt: .init(
                operationID: context.idempotencyKey ?? "missing",
                status: .succeeded,
                confirmedTargets: [.init(namespace: "account", id: input.id)],
                revision: "v1"
            )
        )
    }
}
