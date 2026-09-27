import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

@main struct JournalTestProcess {
    static func main() async {
        guard CommandLine.arguments.count >= 3 else { exit(64) }
        let mode = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        do {
            let journal = try AgentIncrementalJournal.open(at: directory)
            switch mode {
            case "probe":
                try await journal.close()
                exit(0)
            case "hold":
                FileHandle.standardOutput.write(Data("READY\n".utf8))
                while true { try await Task.sleep(for: .seconds(1)) }
            case "commit-and-exit":
                let session = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
                _ = try await journal.appendCheckpoint([
                    .checkpoint(history: [.user([.text("committed before process exit")])], steeringIDs: [])
                ], sessionID: session, runID: UUID(), durability: .durable)
                exit(0)
            case "queue-write-and-wait":
                guard CommandLine.arguments.count == 4 else { exit(64) }
                let file = URL(fileURLWithPath: CommandLine.arguments[3])
                let provider = QueueProcessProvider()
                let model = ModelID(provider: "queue-process", name: "fixed")
                let agent = try Agent(model: model, provider: provider)
                let id = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
                let session = try agent.makeSession(id: id, journal: journal)
                let dispatch = try await session.startFollowUpDispatch(
                    policy: .init(maxModelTurns: 3, maxToolCalls: 3, runTimeout: .seconds(120)),
                    resolver: QueueProcessResolver(session: session, provider: provider, file: file))
                try await dispatch.waitForDrain()
                exit(0)
            default: exit(64)
            }
        } catch AgentJournalError.storeInUse {
            exit(42)
        } catch {
            FileHandle.standardError.write(Data(String(describing: error).utf8))
            exit(1)
        }
    }
}

private struct QueueProcessProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "queue-process", capabilities: [.streaming, .multiTurn, .tools])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "child", model: request.model)
            try emit(.responseStarted(info))
            if request.messages.last?.role == .tool {
                try emit(.textDelta("done"))
                try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
                return
            }
            let call = ToolCall(id: .init(rawValue: "child-write"), name: QueueProcessWrite.name,
                                argumentsJSON: #"{"id":"B"}"#, completeness: .complete)
            try emit(.toolCallStarted(call.id, name: call.name))
            try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
            try emit(.toolCallCompleted(call))
            try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
        }
    }
}

private struct QueueProcessResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: QueueProcessProvider
    let file: URL
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        let scope = try await session.bindCapabilities(identity: "child", version: "1",
            backendInstanceID: "fixture", backendVersion: "1",
            allowedResources: [.named(.init(namespace: "queue.process", id: "B"))],
            tools: [.init(id: "write", version: "1", tool: try QueueProcessWrite(file: file))])
        return .init(model: try AgentModelBinding(profileID: "child", profileRevision: "1",
            model: .init(provider: "queue-process", name: "fixed"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")),
            capabilities: scope)
    }
}

private struct QueueProcessWrite: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = "queue_process_write"
    static let description = "Write a disposable fixture file and wait for process termination"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let file: URL
    let policy: ToolPolicy
    init(file: URL) throws {
        self.file = file
        policy = try .mutation(timeout: .seconds(60), authorization: .notRequired, evidence: .none)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "queue.process", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "queue.process", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("effect\n".utf8))
        try handle.synchronize()
        try handle.close()
        FileHandle.standardOutput.write(Data("EFFECT-WRITTEN\n".utf8))
        while true { try await Task.sleep(for: .seconds(30)) }
    }
}
