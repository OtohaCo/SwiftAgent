import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

@main struct JournalReplayFixture {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { exit(64) }
        let journal = try AgentIncrementalJournal.open(at: URL(fileURLWithPath: CommandLine.arguments[1]))
        let file = URL(fileURLWithPath: CommandLine.arguments[2])
        let agent = try Agent(model: .init(provider: "fixture-file", name: "retry"),
                              provider: FileMutationProvider(), tools: [FileMutationTool(file: file)])
        let run = try await agent.makeSession(id: UUID(), journal: journal)
            .run("Retry the same file effect", operationID: "external-file-write")
        let result = try await run.wait()
        try await run.waitForDrain()
        guard result.receipts.count == 1 else { exit(2) }
        try await journal.close()
    }
}

private struct FileMutationProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture-file", capabilities: [.streaming, .multiTurn, .tools])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "child-response", model: request.model)
            try emit(.responseStarted(info))
            if request.messages.last?.role == .tool {
                try emit(.textDelta("done"))
                try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
            } else {
                let call = ToolCall(id: .init(rawValue: "child-call"), name: FileMutationTool.name,
                                    argumentsJSON: #"{"id":"listing-1"}"#, completeness: .complete)
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
                try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
            }
        }
    }
}

private struct FileMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = "update_listing"
    static let description = "Append a fixture file effect"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let file: URL
    let policy: ToolPolicy
    init(file: URL) throws {
        self.file = file
        policy = try .mutation(authorization: .notRequired, evidence: .none)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "listing", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "listing", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("effect\n".utf8))
        try handle.synchronize()
        return ToolResult(output: .init(updated: true),
                          receipt: ToolReceipt(operationID: context.idempotencyKey ?? "",
                                               status: .succeeded,
                                               confirmedTargets: [.init(namespace: "listing", id: input.id)],
                                               revision: "v2"))
    }
}
