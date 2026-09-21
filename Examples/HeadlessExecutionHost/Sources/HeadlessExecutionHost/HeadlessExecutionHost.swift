import AgentCore
import AgentModels
import AgentTools
import Crypto
import ExecutionReportingSupport
import Foundation

public enum HeadlessScenario: String, CaseIterable, Sendable {
    case failureAfterWrite = "failure-after-write"
    case readOnlyRejectsWrite = "read-only-rejects-write"
}

public struct HeadlessExecutionResult: Sendable {
    public let scenario: HeadlessScenario
    public let root: URL
    public let report: RunExecutionReport
    public let fileContent: String?
    public let executorEntryCount: Int
    public let journalRecordCount: Int
    public let replayExecutorEntryCount: Int?

    public init(
        scenario: HeadlessScenario,
        root: URL,
        report: RunExecutionReport,
        fileContent: String?,
        executorEntryCount: Int,
        journalRecordCount: Int,
        replayExecutorEntryCount: Int?
    ) {
        self.scenario = scenario
        self.root = root
        self.report = report
        self.fileContent = fileContent
        self.executorEntryCount = executorEntryCount
        self.journalRecordCount = journalRecordCount
        self.replayExecutorEntryCount = replayExecutorEntryCount
    }
}

public enum HeadlessExecutionHostError: Error, Equatable, Sendable {
    case missingFixtureFile
    case unexpectedSuccessfulRun
}

public struct HeadlessExecutionHost: Sendable {
    public init() {}

    public func run(
        _ scenario: HeadlessScenario,
        root: URL? = nil
    ) async throws -> HeadlessExecutionResult {
        let root = try makeRoot(root)
        let store = try NoteStore(root: root)
        let journalURL = root.appendingPathComponent("journal.bin")
        let journal = AgentJournal()
        try await journal.persist(to: journalURL)
        let model = ModelID(provider: "deterministic-fixture", name: "note-host")
        let tool = try CreateNoteTool(store: store, allowMutation: scenario == .failureAfterWrite)
        let provider = DeterministicNoteProvider(scenario: scenario)
        let agent = try Agent(
            model: model,
            provider: provider,
            tools: [tool],
            configuration: .init(
                instructions: "Create the requested note exactly once when the Host authorizes it.",
                maxModelTurns: 3,
                maxToolCalls: 1,
                runTimeout: .seconds(10)
            )
        )
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let run = try await session.run(
            "Create note.txt with the text 'execution fact'.",
            operationID: "headless-note-operation"
        )
        let observationTask = Task { () -> ExecutionReportReducer in
            var reducer = ExecutionReportReducer(sessionID: run.sessionID, runID: run.id)
            for await event in run.events {
                reducer.consume(event)
            }
            reducer.markStreamEnded()
            return reducer
        }
        var reducer: ExecutionReportReducer

        do {
            let result = try await run.wait()
            reducer = await observationTask.value
            reducer.recordWait(.success(result))
        } catch {
            reducer = await observationTask.value
            reducer.recordWait(.failure(ExecutionReportReducer.classify(error)))
        }
        switch scenario {
        case .failureAfterWrite:
            reducer.recordPresentation(.malformed(reason: "fixture provider ended before a valid final response"))
        case .readOnlyRejectsWrite:
            reducer.recordPresentation(.parsed(text: "The Host rejected the write before execution."))
        }
        try await run.waitForDrain()
        reducer.markDrainCompleted()

        let fileContent = try? await store.read(name: "note.txt")
        let records = await journal.snapshot()
        let replayCount: Int?
        if scenario == .failureAfterWrite {
            let replaySession = try agent.makeSession(id: sessionID, journal: journal)
            let replay = try await replaySession.run(
                "Create note.txt with the text 'execution fact'.",
                operationID: "headless-note-operation"
            )
            let replayObservation = Task {
                for await _ in replay.events {}
            }
            _ = try? await replay.wait()
            try await replay.waitForDrain()
            _ = await replayObservation.value
            replayCount = await store.executorEntryCount
        } else {
            replayCount = nil
        }

        return HeadlessExecutionResult(
            scenario: scenario,
            root: root,
            report: reducer.report,
            fileContent: fileContent,
            executorEntryCount: await store.executorEntryCount,
            journalRecordCount: records.count,
            replayExecutorEntryCount: replayCount
        )
    }

    private func makeRoot(_ supplied: URL?) throws -> URL {
        if let supplied {
            try FileManager.default.createDirectory(at: supplied, withIntermediateDirectories: true)
            return supplied
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftAgent-HeadlessExecution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor NoteStore {
    let root: URL
    private(set) var executorEntryCount = 0

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(name: String, content: String) throws -> String {
        guard name == "note.txt" else { throw HeadlessExecutionHostError.missingFixtureFile }
        let url = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try Data(content.utf8).write(to: url, options: .atomic)
        executorEntryCount += 1
        return revision(for: content)
    }

    func read(name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw HeadlessExecutionHostError.missingFixtureFile
        }
        return content
    }

    nonisolated func revision(for content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CreateNoteTool: AgentTool {
    struct Input: Codable, Sendable { let name: String; let content: String }
    struct Output: Codable, Sendable { let name: String; let revision: String }

    static let name = "create_note"
    static let description = "Create the Host's isolated note file."
    static let inputSchema = ToolSchema.object(
        properties: ["name": .string, "content": .string],
        required: ["name", "content"]
    )
    static let outputSchema = ToolSchema.object(
        properties: ["name": .string, "revision": .string],
        required: ["name", "revision"]
    )

    let store: NoteStore
    let allowMutation: Bool
    let policy: ToolPolicy

    init(store: NoteStore, allowMutation: Bool) throws {
        self.store = store
        self.allowMutation = allowMutation
        policy = try .mutation(evidence: .none)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "note", id: input.name))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        let revision = store.revision(for: input.content)
        return try .init(
            targets: [.init(namespace: "note", id: input.name)],
            revision: .exact(revision)
        )
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        allowMutation ? .allowed : .denied
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let revision = try await store.write(name: input.name, content: input.content)
        let receipt = ToolReceipt(
            operationID: context.idempotencyKey ?? "",
            status: .succeeded,
            confirmedTargets: [.init(namespace: "note", id: input.name)],
            revision: revision
        )
        return ToolResult(output: .init(name: input.name, revision: revision), receipt: receipt)
    }
}

private struct DeterministicNoteProvider: ModelProvider {
    let scenario: HeadlessScenario
    let descriptor = ModelProviderDescriptor(
        id: "deterministic-fixture",
        capabilities: [.streaming, .multiTurn, .tools]
    )

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "fixture-\(request.runID?.uuidString ?? "none")-\(request.messages.count)", model: request.model)
            try emit(.responseStarted(info))
            if case .tool = request.messages.last {
                if scenario == .failureAfterWrite {
                    try emit(.textDelta("The note was written, but the final reply failed."))
                    throw ModelProviderError(kind: .invalidResponse, message: "deterministic final response failure")
                }
                try emit(.responseCompleted(.init(
                    info: info,
                    content: [.text("The Host rejected the write before execution.")],
                    stopReason: .endTurn
                )))
                return
            }
            let call = ToolCall(
                id: .init(rawValue: "note-call"),
                name: CreateNoteTool.name,
                argumentsJSON: #"{"name":"note.txt","content":"execution fact"}"#,
                completeness: .complete
            )
            try emit(.toolCallStarted(call.id, name: call.name))
            try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
            try emit(.toolCallCompleted(call))
            try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
        }
    }
}
