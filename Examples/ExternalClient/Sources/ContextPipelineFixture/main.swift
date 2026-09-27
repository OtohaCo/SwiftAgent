import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

/// No credentials, sockets or live model calls. Only the temporary Journal is real.
@main struct ContextPipelineFixture {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("context-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "fixture-projects")
        let provider = FixtureProvider()
        let model = ModelID(provider: "context-fixture", name: "deterministic")
        let agent = try Agent(model: model, provider: provider, tools: [try LargeReadTool()],
                              configuration: .init(contextPolicy: .init(maxModelContextUTF8Bytes: 16 * 1024)))
        let aID = UUID(), bID = UUID()
        let a = try agent.makeSession(id: aID, journal: journal)
        let b = try agent.makeSession(id: bID, journal: journal)

        try await finish(try await a.run("intro"))
        let summaryRange = try await a.contextHistorySpan(start: 0, count: 2)
        try await finish(try await a.run("fetch"))
        let excerpt = try await a.contextToolExcerpt(callID: .init(rawValue: "read-once"),
                                                      text: "A small checked excerpt of a large read-only result.")
        let reports = AgentContextReportBuffer(capacity: 4)
        let aBinding = try AgentModelBinding(
            profileID: "project-a", profileRevision: "1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: AgentCompositeContextProjector(
                materials: [
                    .init(id: "a-skill", version: "v1", kind: .skill, sessionID: aID, text: "Use project A terminology."),
                    .init(id: "a-file", version: "v1", kind: .file, sessionID: aID, text: "A document excerpt."),
                ], summaries: [.init(span: summaryRange, generatorVersion: "fixture-v1",
                                    text: "The introduction was answered.")], excerpts: [excerpt]),
            tokenBudget: .init(maximumContextTokens: 2048, reservedOutputTokens: 512,
                               estimator: FixtureEstimator()), contextReports: reports)
        let beforeRead = await journal.storageMetrics()?.bytesRead ?? 0
        try await finish(try await a.run("continue", using: aBinding))
        let afterRead = await journal.storageMetrics()?.bytesRead ?? 0
        let bBinding = try AgentModelBinding(
            profileID: "project-b", profileRevision: "1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: AgentCompositeContextProjector(materials: [
                .init(id: "b-skill", version: "v1", kind: .skill, sessionID: bID,
                      text: "Use project B terminology.")
            ]))
        try await finish(try await b.run("other project", using: bBinding))
        guard let report = await reports.reports().last, report.excerptCount == 1,
              report.summaryCount == 1, report.estimatedInputTokens != nil else {
            fatalError("Context was not assembled and budgeted")
        }
        let requests = await provider.requests()
        guard requests.count >= 5,
              !String(describing: requests.last!.messages).contains("project A") else {
            fatalError("Session material leaked")
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try agent.makeSession(id: aID, journal: reopened)
        let fullHistory = try await restored.conversationSnapshot().messages
        guard fullHistory.contains(where: { message in
            if case .tool(let result) = message { return String(describing: result.content).utf8.count > 5000 }
            return false
        }) else { fatalError("Formal tool output was shortened") }
        try await reopened.close()
        print("Context fixture passed: two Sessions, budgeted request, source-bound summary, read-only excerpt, complete reopened Journal")
        print("Assembly: \(report.assemblyNanoseconds) ns; indexed storage bytes read during Run: \(afterRead - beforeRead); projected request: \(report.requestBytes ?? -1) bytes")
    }

    private static func finish(_ run: AgentRun) async throws {
        _ = try await run.wait()
        try await run.waitForDrain()
    }
}

private actor RequestLog {
    var values: [ModelRequest] = []
    func record(_ request: ModelRequest) { values.append(request) }
}

private struct FixtureProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "context-fixture", capabilities: [.streaming, .multiTurn, .tools])
    private let log = RequestLog()
    func requests() async -> [ModelRequest] { await log.values }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await log.record(request)
            let info = ResponseInfo(id: "fixed", model: request.model)
            try emit(.responseStarted(info))
            if request.messages.last == .user([.text("fetch")]) {
                let call = ToolCall(id: .init(rawValue: "read-once"), name: LargeReadTool.name,
                                    argumentsJSON: "{}", completeness: .complete)
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
                try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
            } else {
                try emit(.textDelta("fixture reply"))
                try emit(.responseCompleted(.init(info: info, content: [.text("fixture reply")], stopReason: .endTurn)))
            }
        }
    }
}

private struct FixtureEstimator: AgentContextTokenEstimator {
    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        let bytes = try JSONEncoder().encode(input.messages).count
        return .init(inputTokens: bytes / 3 + 1, accuracy: .estimated)
    }
}

private struct LargeReadTool: AgentTool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable { let text: String }
    static let name = "large_read"
    static let description = "Read a large fixture"
    static let inputSchema = ToolSchema.object(properties: [:], required: [])
    static let outputSchema = ToolSchema.object(properties: ["text": .string], required: ["text"])
    let policy: ToolPolicy
    init() throws {
        policy = try .init(effect: .readOnly, execution: .parallel, idempotency: .safe,
                           timeout: .seconds(5), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        .init(output: .init(text: String(repeating: "fixture-data", count: 800)))
    }
}
