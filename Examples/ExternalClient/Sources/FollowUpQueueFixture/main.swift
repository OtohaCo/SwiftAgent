import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

@main struct FollowUpQueueFixture {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let effect = directory.appendingPathComponent("effect.txt")
        try Data().write(to: effect)
        let store = directory.appendingPathComponent("journal")
        let provider = QueueExampleProvider()
        let scheduler = ToolScheduler()
        let model = ModelID(provider: "queue-example", name: "fixed")
        let agent = try Agent(model: model, provider: provider,
                              configuration: .init(scheduler: scheduler))
        let aID = UUID(), bID = UUID()
        let journal = try AgentIncrementalJournal.create(at: store, operationDomain: "shared-example")
        let a = try agent.makeSession(id: aID, journal: journal)
        _ = try agent.makeSession(id: bID, journal: journal)
        let current = try await a.run("current")
        await provider.currentEntered()
        let first = AgentFollowUpInput(inputID: "A-1", text: "read A first",
                                       operationID: "read-A-first", configurationRef: "project-A")
        _ = try await a.enqueueFollowUp(first)
        _ = try await a.enqueueFollowUp(.init(inputID: "A-remove", text: "withdraw me",
            operationID: "remove-A", configurationRef: "project-A"))
        _ = try await a.enqueueFollowUp(.init(inputID: "A-2", text: "read A later",
            operationID: "read-A-later", configurationRef: "hold-A"))
        guard (await a.history).contains(.user([.text("current")])),
              !(await a.history).contains(.user([.text("read A first")])),
              try await a.withdrawFollowUp(inputID: "A-remove") == .withdrawn else {
            fatalError("enqueue changed formal history or withdrawal failed")
        }
        let hold = QueueExampleGate()
        let aDispatcher = try await a.startFollowUpDispatch(
            policy: .init(maxModelTurns: 4, maxToolCalls: 4, runTimeout: .seconds(15)),
            resolver: QueueExampleResolver(session: a, provider: provider, project: "A", file: effect,
                                           hold: hold))
        await provider.releaseCurrent()
        _ = try await current.wait()
        try await current.waitForDrain()
        await hold.waitUntilEntered() // A-1 has completed and physically drained.
        await aDispatcher.pause()
        await aDispatcher.stop()
        await hold.open()
        try await aDispatcher.waitForDrain()
        guard try await a.followUp(inputID: "A-1")?.state != .queued,
              try await a.followUp(inputID: "A-2")?.state == .queued,
              try await a.followUp(inputID: "A-remove")?.state == .withdrawn else {
            fatalError("FIFO or stop/pause changed queue facts")
        }
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: store)
        let restoredA = try agent.makeSession(id: aID, journal: reopened)
        let restoredB = try agent.makeSession(id: bID, journal: reopened)
        guard try await restoredA.followUp(inputID: "A-2")?.state == .queued,
              await provider.requestCount(for: "read A later") == 0 else {
            fatalError("reopen implicitly dispatched a queued input")
        }
        let resumed = try await restoredA.startFollowUpDispatch(
            policy: .init(maxModelTurns: 4, maxToolCalls: 4, runTimeout: .seconds(15)),
            resolver: QueueExampleResolver(session: restoredA, provider: provider, project: "A", file: effect))
        await provider.waitForUser("read A later")
        await resumed.stop()
        try await resumed.waitForDrain()

        let mutation = AgentFollowUpInput(inputID: "B-write", text: "write B",
            operationID: "one-logical-write-B", configurationRef: "project-B")
        _ = try await restoredB.enqueueFollowUp(mutation)
        let bDispatcher = try await restoredB.startFollowUpDispatch(
            policy: .init(maxModelTurns: 4, maxToolCalls: 4, runTimeout: .seconds(15)),
            resolver: QueueExampleResolver(session: restoredB, provider: provider, project: "B", file: effect))
        await provider.waitForUser("write B")
        await bDispatcher.stop()
        try await bDispatcher.waitForDrain()
        guard try String(contentsOf: effect, encoding: .utf8) == "effect\n",
              try await restoredB.followUp(inputID: "B-write")?.state != .queued else {
            fatalError("durable mutation did not settle")
        }
        try await reopened.close()

        let third = try AgentIncrementalJournal.open(at: store)
        let retryB = try agent.makeSession(id: bID, journal: third)
        guard try await retryB.enqueueFollowUp(mutation).state != .queued else {
            fatalError("inputID was forgotten after restart")
        }
        let freshScope = try await retryB.bindCapabilities(identity: "B", version: "v2",
            backendInstanceID: "fixture", backendVersion: "v2",
            allowedResources: [.named(.init(namespace: "queue.example", id: "B"))],
            tools: [.init(id: "write", version: "v2", tool: try QueueWriteTool(file: effect))])
        let retry = try await retryB.run("write B", capabilities: freshScope,
                                         operationID: "one-logical-write-B")
        guard try await retry.wait().receipts.count == 1 else { fatalError("settled replay lacks receipt") }
        try await retry.waitForDrain()
        guard try String(contentsOf: effect, encoding: .utf8) == "effect\n",
              await freshScope.status().finalAdmissions == 0 else {
            fatalError("replay re-entered the file executor")
        }
        try await third.close()
        print("Follow-up fixture passed: FIFO, withdrawn input, paused reopen, fresh scoped bindings, one durable file write and no-replay retry")
    }
}

private actor QueueExampleGate {
    private var entered = false, opened = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let current = observers; observers.removeAll(); current.forEach { $0.resume() }
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func open() {
        opened = true
        let current = waiters; waiters.removeAll(); current.forEach { $0.resume() }
    }
}

private actor QueueExampleRequests {
    private var requests: [ModelRequest] = []
    private var observers: [(String, CheckedContinuation<Void, Never>)] = []
    func append(_ request: ModelRequest) {
        requests.append(request)
        let current = observers.filter { name, _ in Self.userText(request) == name }
        observers.removeAll { name, _ in Self.userText(request) == name }
        current.forEach { $0.1.resume() }
    }
    func waitForUser(_ text: String) async {
        if requests.contains(where: { Self.userText($0) == text }) { return }
        await withCheckedContinuation { observers.append((text, $0)) }
    }
    func count(for text: String) -> Int { requests.filter { Self.userText($0) == text }.count }
    private static func userText(_ request: ModelRequest) -> String? {
        guard case .user(let content)? = request.messages.last,
              case .text(let text)? = content.first else { return nil }
        return text
    }
}

private struct QueueExampleProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "queue-example", capabilities: [.streaming, .multiTurn, .tools])
    private let log = QueueExampleRequests()
    private let current = QueueExampleGate()
    func currentEntered() async { await current.waitUntilEntered() }
    func releaseCurrent() async { await current.open() }
    func waitForUser(_ text: String) async { await log.waitForUser(text) }
    func requestCount(for text: String) async -> Int { await log.count(for: text) }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await log.append(request)
            let info = ResponseInfo(id: "fixed", model: request.model)
            try emit(.responseStarted(info))
            if case .user(let content)? = request.messages.last,
               case .text(let text)? = content.first {
                if text == "current" { await current.wait() }
                if text.hasPrefix("read A") || text == "write B" {
                    let name = text == "write B" ? QueueWriteTool.name : QueueReadTool.name
                    let id = text == "write B" ? "B" : "A"
                    let call = ToolCall(id: .init(rawValue: UUID().uuidString), name: name,
                                        argumentsJSON: "{\"id\":\"\(id)\"}", completeness: .complete)
                    try emit(.toolCallStarted(call.id, name: name))
                    try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                    try emit(.toolCallCompleted(call))
                    try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
                    return
                }
            }
            try emit(.textDelta("done"))
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
        }
    }
}

private struct QueueExampleResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: QueueExampleProvider
    let project: String
    let file: URL
    var hold: QueueExampleGate? = nil
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        if request.record.configurationRef == "hold-A" { await hold?.wait() }
        let resource = ToolResource.named(.init(namespace: "queue.example", id: project))
        let tools: [AgentCapabilityTool]
        if project == "B" {
            tools = [.init(id: "write", version: "v1", tool: try QueueWriteTool(file: file))]
        } else {
            tools = [.init(id: "read", version: "v1", tool: try QueueReadTool())]
        }
        let scope = try await session.bindCapabilities(identity: project, version: "current",
            backendInstanceID: "fixture", backendVersion: "current",
            allowedResources: [resource], tools: tools)
        let binding = try AgentModelBinding(profileID: "queue-example", profileRevision: "1",
            model: .init(provider: "queue-example", name: "fixed"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"))
        return .init(model: binding, capabilities: scope)
    }
}

private struct QueueReadTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let id: String }
    static let name = "read_project"
    static let description = "Read approved project material"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    let policy: ToolPolicy
    init() throws { policy = try .readOnly(authorization: .notRequired) }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "queue.example", id: input.id))]
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        .init(output: .init(id: input.id))
    }
}

private struct QueueWriteTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = "write_project"
    static let description = "Append to the temporary project file"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let file: URL
    let policy: ToolPolicy
    init(file: URL) throws { self.file = file; policy = try .mutation(authorization: .notRequired, evidence: .none) }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "queue.example", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "queue.example", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("effect\n".utf8))
        try handle.synchronize()
        try handle.close()
        return .init(output: .init(updated: true), receipt: .init(
            operationID: context.idempotencyKey ?? "", status: .succeeded,
            confirmedTargets: [.init(namespace: "queue.example", id: input.id)], revision: "v1"))
    }
}
