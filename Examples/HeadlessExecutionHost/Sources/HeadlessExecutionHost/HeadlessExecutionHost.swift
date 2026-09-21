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
    public let fileRevision: String?
    public let executorEntryCount: Int
    public let executorEntryCountAfterFirstRun: Int
    public let successfulWriteCount: Int
    public let successfulWriteCountAfterFirstRun: Int
    public let journalRecordCount: Int
    public let replayExecutorEntryCount: Int?
    public let replayReceivedToolResult: Bool?
    public let replayReport: RunExecutionReport?

    public init(
        scenario: HeadlessScenario,
        root: URL,
        report: RunExecutionReport,
        fileContent: String?,
        fileRevision: String?,
        executorEntryCount: Int,
        executorEntryCountAfterFirstRun: Int,
        successfulWriteCount: Int,
        successfulWriteCountAfterFirstRun: Int,
        journalRecordCount: Int,
        replayExecutorEntryCount: Int?,
        replayReceivedToolResult: Bool?,
        replayReport: RunExecutionReport?
    ) {
        self.scenario = scenario
        self.root = root
        self.report = report
        self.fileContent = fileContent
        self.fileRevision = fileRevision
        self.executorEntryCount = executorEntryCount
        self.executorEntryCountAfterFirstRun = executorEntryCountAfterFirstRun
        self.successfulWriteCount = successfulWriteCount
        self.successfulWriteCountAfterFirstRun = successfulWriteCountAfterFirstRun
        self.journalRecordCount = journalRecordCount
        self.replayExecutorEntryCount = replayExecutorEntryCount
        self.replayReceivedToolResult = replayReceivedToolResult
        self.replayReport = replayReport
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
        let bootstrapJournal = AgentJournal()
        try await bootstrapJournal.persist(to: journalURL)
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
        let firstReport: RunExecutionReport
        let journalRecordCount: Int
        let executorEntryCountAfterFirstRun: Int
        let successfulWriteCountAfterFirstRun: Int
        do {
            let journal = try AgentJournal.load(from: journalURL)
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
            firstReport = reducer.report
            journalRecordCount = await journal.snapshot().count
            executorEntryCountAfterFirstRun = await store.executorEntryCount
            successfulWriteCountAfterFirstRun = await store.successfulWriteCount
        }

        let fileContent = try? await store.read(name: "note.txt")
        let replayCount: Int?
        let replayReceivedToolResult: Bool?
        let replayReport: RunExecutionReport?
        if scenario == .failureAfterWrite {
            let reloadedJournal = try AgentJournal.load(from: journalURL)
            let replaySession = try agent.makeSession(id: sessionID, journal: reloadedJournal)
            let replay = try await replaySession.run(
                "Create note.txt with the text 'execution fact'.",
                operationID: "headless-note-operation"
            )
            let replayObservation = Task { () -> ExecutionReportReducer in
                var reducer = ExecutionReportReducer(sessionID: replay.sessionID, runID: replay.id)
                for await event in replay.events {
                    reducer.consume(event)
                }
                reducer.markStreamEnded()
                return reducer
            }
            let replayResult = try await replay.wait()
            var reducer = await replayObservation.value
            reducer.recordWait(.success(replayResult))
            reducer.recordPresentation(.parsed(text: "The note was already committed."))
            try await replay.waitForDrain()
            reducer.markDrainCompleted()
            replayReport = reducer.report
            replayCount = await store.executorEntryCount
            replayReceivedToolResult = await provider.state.receivedToolResult(for: replay.id)
        } else {
            replayCount = nil
            replayReceivedToolResult = nil
            replayReport = nil
        }

        let fileRevision = try? await store.revision(name: "note.txt")

        return HeadlessExecutionResult(
            scenario: scenario,
            root: root,
            report: firstReport,
            fileContent: fileContent,
            fileRevision: fileRevision,
            executorEntryCount: await store.executorEntryCount,
            executorEntryCountAfterFirstRun: executorEntryCountAfterFirstRun,
            successfulWriteCount: await store.successfulWriteCount,
            successfulWriteCountAfterFirstRun: successfulWriteCountAfterFirstRun,
            journalRecordCount: journalRecordCount,
            replayExecutorEntryCount: replayCount,
            replayReceivedToolResult: replayReceivedToolResult,
            replayReport: replayReport
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
    private(set) var successfulWriteCount = 0

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(name: String, content: String) throws -> String {
        guard name == "note.txt" else { throw HeadlessExecutionHostError.missingFixtureFile }
        executorEntryCount += 1
        let url = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try Data(content.utf8).write(to: url, options: .atomic)
        successfulWriteCount += 1
        return revision(for: content)
    }

    func read(name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw HeadlessExecutionHostError.missingFixtureFile
        }
        return content
    }

    func revision(name: String) throws -> String {
        revision(for: try read(name: name))
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

private actor DeterministicNoteProviderState {
    private var firstMutationRunID: UUID?
    private var toolResultRuns = Set<UUID>()

    func shouldFailFinalResponse(for runID: UUID) -> Bool {
        if let firstMutationRunID {
            return firstMutationRunID == runID
        }
        firstMutationRunID = runID
        return true
    }

    func recordToolResult(for runID: UUID) {
        toolResultRuns.insert(runID)
    }

    func receivedToolResult(for runID: UUID) -> Bool {
        toolResultRuns.contains(runID)
    }
}

private struct DeterministicNoteProvider: ModelProvider {
    let scenario: HeadlessScenario
    let state = DeterministicNoteProviderState()
    let descriptor = ModelProviderDescriptor(
        id: "deterministic-fixture",
        capabilities: [.streaming, .multiTurn, .tools]
    )

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "fixture-\(request.runID?.uuidString ?? "none")-\(request.messages.count)", model: request.model)
            try emit(.responseStarted(info))
            if case .tool = request.messages.last {
                if let runID = request.runID {
                    await state.recordToolResult(for: runID)
                }
                if scenario == .failureAfterWrite {
                    let shouldFail = await state.shouldFailFinalResponse(for: request.runID ?? UUID())
                    if shouldFail {
                        try emit(.textDelta("The note was written, but the final reply failed."))
                        throw ModelProviderError(kind: .invalidResponse, message: "deterministic final response failure")
                    }
                    try emit(.textDelta("The note was already committed."))
                    try emit(.responseCompleted(.init(
                        info: info,
                        content: [.text("The note was already committed.")],
                        stopReason: .endTurn
                    )))
                    return
                }
                try emit(.textDelta("The Host rejected the write before execution."))
                try emit(.responseCompleted(.init(
                    info: info,
                    content: [.text("The Host rejected the write before execution.")],
                    stopReason: .endTurn
                )))
                return
            }
            let call = ToolCall(
                id: .init(rawValue: "note-call-\(request.runID?.uuidString ?? "unknown")"),
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
