import AgentCore
import AgentJournalFileStore
import AgentCatalog
import AgentDecisions
import AgentJevProvider
import AgentModels
import AgentProviders
import AgentTools
import AgentUsage
import ExecutionReportingSupport
import Foundation
import Testing

/// Package-level consumer of the public Agent, Tool, Provider, and recovery API.
struct ExternalClientTests {
    @Test func queuedRunIsDeliveredToTheSinglePublicEventObserverAndExecutionReport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-events-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("effect.txt")
        try Data().write(to: file)
        let journal = try AgentIncrementalJournal.create(at: directory.appendingPathComponent("store"),
                                                         operationDomain: "queue-events")
        let probe = SideEffectProbe()
        let provider = MutationProvider(probe: probe)
        let tool = try ListingUpdateTool(probe: probe, file: file)
        let agent = try Agent(model: .init(provider: "external-client", name: "echo"),
                              provider: provider, tools: [tool])
        let session = try agent.makeSession(journal: journal)
        let received = try await session.enqueueFollowUp(.init(inputID: "report-1", text: "Update",
            operationID: "report-operation", configurationRef: "current-approval"))
        let observed = PublicQueueReportCapture()
        let dispatcher = try await session.startFollowUpDispatch(
            policy: .init(maxModelTurns: 3, maxToolCalls: 2, runTimeout: .seconds(10)),
            resolver: PublicQueueResolver(session: session, provider: provider, tool: tool),
            onRun: { record, run in
                var report = ExecutionReportReducer(sessionID: run.sessionID, runID: run.id)
                for await event in run.events { report.consume(event) }
                report.markStreamEnded()
                report.recordPresentation(.malformed(reason: "fixture display rejected final text"))
                do { report.recordWait(.success(try await run.wait())) }
                catch { report.recordWait(.failure(ExecutionReportReducer.classify(error))) }
                do { try await run.waitForDrain(); report.markDrainCompleted() }
                catch { /* A missing drain remains visible in coverage. */ }
                await observed.record(input: record, runID: run.id, report: report.report)
            })
        let entry = await observed.next()
        #expect(entry.input.inputID == received.inputID)
        guard case .admitted(let runID, _)? = try await session.followUp(inputID: received.inputID)?.state else {
            Issue.record("the delivered Run has no durable admission"); return
        }
        #expect(entry.runID == runID)
        #expect(entry.report.coverage.runStarted && entry.report.coverage.streamEnded)
        #expect(entry.report.coverage.terminalObserved && entry.report.coverage.drainCompleted)
        #expect(entry.report.modelText.contains("Done"))
        #expect(entry.report.toolObservations.count == 1)
        #expect(entry.report.receipts.count == 1)
        #expect(entry.report.presentation == .malformed(reason: "fixture display rejected final text"))
        #expect(probe.toolExecutions == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        try await journal.close()
    }

    @Test func disconnectedQueueObserverCannotEraseDurableMutationSettlement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-observer-exit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("effect.txt")
        try Data().write(to: file)
        let journal = try AgentIncrementalJournal.create(at: directory.appendingPathComponent("store"),
                                                         operationDomain: "queue-observer-exit")
        let probe = SideEffectProbe(), provider = MutationProvider(probe: probe)
        let tool = try ListingUpdateTool(probe: probe, file: file)
        let session = try Agent(model: .init(provider: "external-client", name: "echo"),
                                provider: provider, tools: [tool]).makeSession(journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "one", text: "Update",
            operationID: "disconnected-observer", configurationRef: "approved"))
        let observed = PublicQueueObserverExit()
        let dispatcher = try await session.startFollowUpDispatch(
            policy: .init(maxModelTurns: 3, maxToolCalls: 2, runTimeout: .seconds(10)),
            resolver: PublicQueueResolver(session: session, provider: provider, tool: tool),
            onRun: { _, run in
                for await _ in run.events { break }
                await observed.mark()
            })
        await observed.wait()
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        #expect(probe.toolExecutions == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()
    }

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
        #expect(try await journal.pendingMutations().isEmpty)
    }

    @Test func mutationAgentRecoversThroughThePublicJournalAPI() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-external-client-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let journal = try AgentIncrementalJournal.create(at: url, operationDomain: "external-client")
        #expect(journal.storage == .durable)
        let sessionID = UUID()
        let run = try await makeMutationAgent().makeSession(id: sessionID, journal: journal).run("Update the listing")
        let result = try await run.wait()
        try await run.waitForDrain()
        #expect(result.receipts.count == 1)
        #expect(try await journal.pendingMutations().isEmpty)

        try await journal.close()
        let restarted = try AgentIncrementalJournal.open(at: url)
        #expect(try await restarted.pendingMutations().isEmpty)
        _ = try makeMutationAgent().makeSession(id: sessionID, journal: restarted)
        try await restarted.close()
    }

    @Test func stableOperationIDReplaysASettledReceiptWithoutExecutingAgain() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-external-idempotency-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let probe = SideEffectProbe()
        let journal = try AgentIncrementalJournal.create(at: url, operationDomain: "external-idempotency")
        let session = try makeMutationAgent(probe: probe).makeSession(journal: journal)

        let firstRun = try await session.run("Update the listing", operationID: "logical-update-1")
        let first = try await firstRun.wait()
        try await firstRun.waitForDrain()
        let retryRun = try await session.run("Retry the update", operationID: "logical-update-1")
        let retry = try await retryRun.wait()
        try await retryRun.waitForDrain()

        #expect(probe.toolExecutions == 1)
        #expect(retry.receipts.first?.receipt == first.receipts.first?.receipt)
        try await journal.close()
    }

    @Test func fileMutationReplaysAcrossProcessesAndSessionsWithoutASecondWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("external-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appendingPathComponent("store")
        let sideEffect = directory.appendingPathComponent("effect.txt")
        try Data().write(to: sideEffect)
        let journal = try AgentIncrementalJournal.create(at: store, operationDomain: "external-file-domain")
        let first = try await makeMutationAgent(file: sideEffect)
            .makeSession(id: UUID(), journal: journal)
            .run("Update", operationID: "external-file-write")
        #expect(try await first.wait().receipts.count == 1)
        try await first.waitForDrain()
        try await journal.close()
        #expect(try String(contentsOf: sideEffect, encoding: .utf8) == "effect\n")

        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let possible = [project.appendingPathComponent(".build/out/Products/Debug/JournalReplayFixture"),
                        project.appendingPathComponent(".build/debug/JournalReplayFixture")]
        let executable = try #require(possible.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process()
        process.executableURL = executable
        process.arguments = [store.path, sideEffect.path]
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Issue.record("Child replay failed: \(String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        }
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: sideEffect, encoding: .utf8) == "effect\n")
        let reopened = try AgentIncrementalJournal.open(at: store)
        #expect(try await reopened.mutationStatus(identity: #"external-file-write/update_listing/{"id":"listing-1"}"#)?.state == .settled)
        try await reopened.close()
    }

    @Test func restartedMutationCannotBecomeReadOnlyExcerptThroughToolNameReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("historical-effect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appendingPathComponent("store")
        let effect = directory.appendingPathComponent("effect.txt")
        try Data().write(to: effect)
        let original = try AgentIncrementalJournal.create(at: store, operationDomain: "historical-effect")
        let sessionID = UUID()
        let run = try await makeMutationAgent(file: effect).makeSession(id: sessionID, journal: original)
            .run("Update", operationID: "historical-write")
        let completed = try await run.wait()
        try await run.waitForDrain()
        #expect(completed.receipts.count == 1)
        try await original.close()
        #expect(try String(contentsOf: effect, encoding: .utf8) == "effect\n")

        let reopened = try AgentIncrementalJournal.open(at: store)
        let reusedName = try Agent(model: .init(provider: "external-client", name: "echo"),
                                    provider: EchoProvider(), tools: [try ReadOnlyListingTool()])
        let restored = try reusedName.makeSession(id: sessionID, journal: reopened)
        await #expect(throws: AgentContextPipelineError.unsafeToolExcerpt) {
            try await restored.contextToolExcerpt(callID: .init(rawValue: "listing-1"), text: "shortened")
        }
        let messages = try await reopened.readMessages(sessionID: sessionID)
        let historical = try #require(messages.first(where: {
            if case .tool(let result) = $0.message { return result.callID.rawValue == "listing-1" }
            return false
        }))
        let forged = AgentContextToolExcerpt(callID: .init(rawValue: "listing-1"),
            messageID: historical.id,
            sourceDigest: try AgentContextProjectionSource.digest(messages: [historical.message]),
            text: "shortened")
        let binding = try AgentModelBinding(profileID: "reused-name", profileRevision: "1",
            model: .init(provider: "external-client", name: "echo"), provider: EchoProvider(),
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: AgentCompositeContextProjector(excerpts: [forged]))
        await #expect(throws: AgentContextPipelineError.unsafeToolExcerpt) {
            try await restored.run("next", using: binding)
        }
        #expect(try String(contentsOf: effect, encoding: .utf8) == "effect\n")
        #expect(try await reopened.mutationStatus(identity: #"historical-write/update_listing/{"id":"listing-1"}"#)?.state == .settled)
        #expect(try await restored.conversationSnapshot().messages.count == messages.count)
        try await reopened.close()
    }

    @Test func publicRecoverableToolErrorSurfaceCompilesForAReadOnlyTool() throws {
        let policy = try ToolPolicy.readOnly(
            authorization: .notRequired,
            recoverableErrors: .modelVisible
        )
        let error = try RecoverableToolError(
            code: "not_found",
            message: "No result was found.",
            details: .object(["query": .string("missing")])
        )

        #expect(policy.recoverableErrors == .modelVisible)
        #expect(error.code == "not_found")
        #expect(error.details == .object(["query": .string("missing")]))
    }

    @Test func recoverableReadOnlyFailureContinuesThroughPublicAPI() async throws {
        let agent = try Agent(
            model: ModelID(provider: "external-client", name: "recoverable"),
            provider: RecoverableSearchProvider(),
            tools: [try SearchTool()]
        )

        let result = try await agent.makeSession().run("Find the missing resource").wait()

        #expect(result.outcome == .completed)
        #expect(result.response.content == [.text("Try another source")])
    }

    @Test func decisionProductsAreConsumableThroughPublicAPI() throws {
        let request = try DecisionRequest(
            state: .object(["message": .string("I was charged twice")]),
            nouls: ["billing": .init(instructions: .string("Is this about billing?"))],
            choices: ["route": try .init(criteria: [
                .init(name: "support"), .init(name: "billing"),
            ])],
            scores: ["urgency": try .init(criteria: [.string("Can wait"), .string("Today")])]
        )
        let provider: any DecisionProvider = try JevDecisionProvider(apiKey: "fixture-only")

        #expect(request.questionCount == 3)
        #expect(provider.descriptor.id == "jev")
    }

    @Test func usageAccountingIsConsumableWithoutAgentCoreIntegration() throws {
        let sessionID = UUID()
        let runID = UUID()
        var usage = UsageAccumulator()
        let result = usage.record(.init(
            identity: .init(
                source: .modelResponse,
                sessionID: sessionID,
                runID: runID,
                invocationID: "turn-1",
                providerResponseID: "response-1",
                model: .init(provider: "external-client", name: "fixture")
            ),
            usage: .init(inputTokens: 9, outputTokens: 3),
            status: .finalized
        ))

        #expect(result.disposition == .inserted)
        #expect(usage.summary(sessionID: sessionID, runID: runID).totalTokens == 12)
    }

    @Test func localResponsesProviderIsConsumableThroughPublicAPI() throws {
        let authentication = LocalResponsesAuthentication.bearer("fixture-only")
        let provider: any ModelProvider = try LocalResponsesProvider(configuration: .init(
            baseURL: URL(string: "https://models.example.test/v1")!,
            model: "local-fixture",
            authentication: authentication,
            maximumOutputTokens: 256,
            capabilities: [.tools, .structuredOutput]
        ))

        #expect(provider.descriptor.id == "local-responses")
        #expect(provider.descriptor.capabilities.contains([.streaming, .multiTurn, .tools, .structuredOutput]))
        #expect(String(describing: authentication) == "bearer")
        #expect(!String(reflecting: authentication).contains("fixture-only"))
    }

    @Test func catalogAndDynamicRunBindingAreConsumableThroughPublicAPI() async throws {
        let scope = try ModelServiceScope(
            provider: "external-client",
            serviceInstanceID: "fixture",
            endpointScope: "https://models.example.test/v1",
            apiDialect: "fixture"
        )
        let model = ModelID(provider: "external-client", name: "future-model")
        let catalog = StaticModelCatalogProvider(manifest: try .init(
            scope: scope,
            revision: "manifest-1",
            models: [.init(
                model: model,
                deploymentID: "future-model",
                serviceScope: scope,
                capabilities: .init(multiTurn: .supported),
                sources: [.init(kind: .hostOverride)]
            )]
        ))
        let snapshot = try await ModelCatalogCache().refresh(using: catalog)
        let provider = EchoProvider()
        let binding = try AgentModelBinding(
            profileID: "future-model-defaults",
            profileRevision: snapshot.revision,
            model: model,
            provider: provider,
            deployment: .init(
                serviceInstanceID: scope.serviceInstanceID,
                endpointScope: scope.endpointScope,
                apiDialect: scope.apiDialect
            )
        )
        let session = try Agent(model: model, provider: provider).makeSession()
        let revision = try await session.conversationSnapshot().revision
        let run = try await session.run("hello", using: binding, expectedConversationRevision: revision)

        #expect(run.binding.profileID == "future-model-defaults")
        #expect(try await run.wait().outcome == .completed)
    }
}

private actor PublicQueueReportCapture {
    struct Entry: Sendable {
        let input: AgentFollowUpRecord
        let runID: UUID
        let report: RunExecutionReport
    }
    private var value: Entry?
    private var waiters: [CheckedContinuation<Entry, Never>] = []
    func record(input: AgentFollowUpRecord, runID: UUID, report: RunExecutionReport) {
        let entry = Entry(input: input, runID: runID, report: report)
        value = entry
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: entry) }
    }
    func next() async -> Entry {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private actor PublicQueueObserverExit {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func mark() {
        finished = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func wait() async {
        if finished { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct PublicQueueResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: MutationProvider
    let tool: ListingUpdateTool
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        let scope = try await session.bindCapabilities(identity: "report", version: "1",
            backendInstanceID: "temp-file", backendVersion: "1",
            allowedResources: [.named(.init(namespace: "listing", id: "listing-1"))],
            tools: [.init(id: "write", version: "1", tool: tool)])
        return .init(model: try AgentModelBinding(profileID: "report", profileRevision: "1",
            model: .init(provider: "external-client", name: "echo"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")),
            capabilities: scope)
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

private func makeMutationAgent(probe: SideEffectProbe? = nil, file: URL? = nil) throws -> Agent {
    try Agent(
        model: ModelID(provider: "external-client", name: "echo"),
        provider: MutationProvider(probe: probe),
        tools: [try ListingUpdateTool(probe: probe, file: file)]
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
            if request.messages.last?.role == .tool {
                try emit(.responseStarted(info))
                try emit(.textDelta("Done"))
                try emit(.responseCompleted(.init(info: info, content: [.text("Done")], stopReason: .endTurn)))
                return
            }
            let call = ToolCall(
                id: .init(rawValue: "listing-\(probe?.modelStarts ?? 1)"),
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

private struct RecoverableSearchProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "external-client", capabilities: [.multiTurn, .tools])

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "recoverable", model: request.model)
            if case .tool(let result)? = request.messages.last {
                guard result.isError,
                      result.callID == .init(rawValue: "search-missing"),
                      result.content == [.json(.object([
                          "code": .string("not_found"),
                          "message": .string("No result was found."),
                          "details": .object(["query": .string("missing")]),
                      ]))] else {
                    throw ModelProviderError(kind: .invalidRequest, message: "missing recoverable tool result")
                }
                try emit(.responseStarted(info))
                try emit(.textDelta("Try another source"))
                try emit(.responseCompleted(.init(
                    info: info, content: [.text("Try another source")], stopReason: .endTurn
                )))
                return
            }
            let call = ToolCall(
                id: .init(rawValue: "search-missing"), name: SearchTool.name,
                argumentsJSON: #"{"query":"missing"}"#, completeness: .complete
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
        policy = try .readOnly(authorization: .notRequired, recoverableErrors: .modelVisible)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        if input.query == "missing" {
            throw try RecoverableToolError(
                code: "not_found",
                message: "No result was found.",
                details: .object(["query": .string(input.query)])
            )
        }
        return ToolResult(output: Output(results: [input.query]))
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
    let file: URL?

    init(probe: SideEffectProbe? = nil, file: URL? = nil) throws {
        self.probe = probe
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
        probe?.recordTool()
        if let file {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("effect\n".utf8))
            try handle.synchronize()
        }
        let receipt = ToolReceipt(
            operationID: context.idempotencyKey ?? "missing",
            status: .succeeded,
            confirmedTargets: [.init(namespace: "listing", id: input.id)],
            revision: "v2"
        )
        return ToolResult(output: .init(updated: true), receipt: receipt)
    }
}

private struct ReadOnlyListingTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = ListingUpdateTool.name
    static let description = "Read a listing without changing it"
    static let inputSchema = ListingUpdateTool.inputSchema
    static let outputSchema = ListingUpdateTool.outputSchema
    let policy: ToolPolicy

    init() throws { policy = try .readOnly(authorization: .notRequired) }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        .init(output: .init(updated: false))
    }
}
