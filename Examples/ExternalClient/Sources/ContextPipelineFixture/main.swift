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
        let readTool = try LargeReadTool()
        let agent = try Agent(model: model, provider: provider, tools: [readTool],
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
        let dynamicHistories = try await verifyDynamicHost(agent: agent, provider: provider, model: model, journal: journal, executions: readTool.executions)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        for (id, expected) in dynamicHistories {
            let recovered = try agent.makeSession(id: id, journal: reopened)
            guard try await recovered.conversationSnapshot().messages == expected else {
                fatalError("Dynamic or cancelled Host history changed after reopen")
            }
        }
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

    /// A fixed binding owns one projector; new canonical snapshots produce new request views.
    private static func verifyDynamicHost(agent: Agent, provider: FixtureProvider, model: ModelID,
                                          journal: AgentJournal, executions: ToolExecutionCount) async throws -> [UUID: [ModelMessage]] {
        let session = try agent.makeSession(journal: journal)
        try await finish(try await session.run("intro"))
        let span = try await session.contextHistorySpan(start: 0, count: 2)
        let projector = DynamicHostProjector(sessionID: session.id, span: span)
        let binding = try AgentModelBinding(profileID: "dynamic-host", profileRevision: "1",
            model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: projector)
        let executionStart = await executions.count
        let before = await provider.requests().count
        try await finish(try await session.run("fetch", using: binding))
        let views = await projector.views
        let requests = Array(await provider.requests().dropFirst(before))
        guard await executions.count == executionStart + 1,
              views.count == 2, requests.count == 2, views[0] != views[1],
              requests[0].messages != requests[1].messages else {
            fatalError("Fixed projector did not receive exactly one fresh source per model request")
        }
        let canonical = try await session.conversationSnapshot().messages
        guard canonical.count == 6,
              canonical.filter({ if case .tool = $0 { true } else { false } }).count == 1,
              !String(describing: canonical).contains("Host request view"),
              try await journal.latestCheckpoint(sessionID: session.id)?.history == canonical else {
            fatalError("Projection changed canonical history or duplicated execution")
        }
        // A second Session uses the same dynamic contract and blocks the post-tool projection.
        let cancelled = try agent.makeSession(journal: journal)
        try await finish(try await cancelled.run("intro"))
        let cancelledSpan = try await cancelled.contextHistorySpan(start: 0, count: 2)
        let delayed = DynamicHostProjector(sessionID: cancelled.id, span: cancelledSpan, blockSecond: true)
        let cancellationBinding = try AgentModelBinding(profileID: "cancel-host", profileRevision: "1",
            model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: delayed)
        let start = await provider.requests().count
        let run = try await cancelled.run("fetch", using: cancellationBinding)
        await delayed.waitUntilBlocked()
        await run.cancel()
        do {
            _ = try await run.wait()
            fatalError("Cancelled projection invented a successful terminal")
        } catch is CancellationError {
            // Logical cancellation precedes physical projector release.
        }
        await delayed.release()
        try await run.waitForDrain()
        guard await executions.count == executionStart + 2,
              await provider.requests().count == start + 1,
              (try await cancelled.conversationSnapshot().messages).filter({
                  if case .tool = $0 { true } else { false }
              }).count == 1 else { fatalError("Late projection dispatched or lost committed tool result") }
        let cancelledHistory = try await cancelled.conversationSnapshot().messages
        print("Dynamic Host fixture passed: fixed projector, two source-correct views, single tool result, cancellation blocks late dispatch")
        return [session.id: canonical, cancelled.id: cancelledHistory]
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
    let executions = ToolExecutionCount()
    init() throws {
        policy = try .init(effect: .readOnly, execution: .parallel, idempotency: .safe,
                           timeout: .seconds(5), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await executions.record()
        return .init(output: .init(text: String(repeating: "fixture-data", count: 800)))
    }
}

/// Deterministic Host preparation, not an automatic summarizer. Immutable source requirements
/// are forwarded; the per-request material changes with the supplied canonical snapshot.
private actor DynamicHostProjector: AgentContextSourceReferencing {
    nonisolated let historySpans: [AgentContextHistorySpan]
    nonisolated let toolResultCallIDs: [ToolCallID] = []
    private let sessionID: UUID
    private let blockSecond: Bool
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked = false
    private(set) var views: [String] = []
    init(sessionID: UUID, span: AgentContextHistorySpan, blockSecond: Bool = false) {
        self.sessionID = sessionID
        historySpans = [span]
        self.blockSecond = blockSecond
    }
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        let digest = try input.sourceDigest()
        views.append(digest)
        if blockSecond && views.count == 2 {
            blocked = true
            blockedWaiters.forEach { $0.resume() }
            blockedWaiters.removeAll()
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        return try await AgentCompositeContextProjector(
            materials: [.init(id: "dynamic-view", version: "fixture-v1", kind: .file,
                sessionID: sessionID, text: "Host request view for turn \(input.modelTurn); preserve important constraints.")],
            summaries: [.init(span: historySpans[0], generatorVersion: "deterministic-fixture-v1",
                text: "The introduction was answered; preserve all current input and tool pairs.")]
        ).project(input)
    }
    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

private actor ToolExecutionCount {
    private(set) var count = 0
    func record() { count += 1 }
}
