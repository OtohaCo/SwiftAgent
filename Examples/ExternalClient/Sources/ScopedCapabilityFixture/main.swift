import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

/// Entirely local. The model is a deterministic fixture; the Journal and file
/// mutation use real temporary filesystem I/O.
@main struct ScopedCapabilityFixture {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let effect = directory.appendingPathComponent("effect.txt")
        try Data().write(to: effect)
        let journal = try AgentIncrementalJournal.create(at: directory.appendingPathComponent("journal"),
                                                          operationDomain: "fixture-shared-domain")
        let scheduler = ToolScheduler()
        let provider = ScopedFixtureProvider()
        let model = ModelID(provider: "scope-fixture", name: "fixed")
        let agent = try Agent(model: model, provider: provider,
                              configuration: .init(scheduler: scheduler))
        let a = try agent.makeSession(journal: journal)
        let b = try agent.makeSession(journal: journal)
        let aScope = try await a.bindCapabilities(identity: "project-A", version: "v1",
            backendInstanceID: "local", backendVersion: "v1",
            allowedResources: [.named(.init(namespace: "fixture.file", id: "A"))],
            tools: [.init(id: "read", version: "v1", tool: try FixtureReadTool())])
        let bScope = try await b.bindCapabilities(identity: "project-B", version: "v1",
            backendInstanceID: "local", backendVersion: "v1",
            allowedResources: [.named(.init(namespace: "fixture.file", id: "B"))],
            tools: [.init(id: "write", version: "v1", tool: try FixtureWriteTool(file: effect))])
        try await finish(try await a.run("read A", capabilities: aScope))
        let aRequest = try require(await provider.requests().last)
        guard aRequest.tools.map(\.name) == [FixtureReadTool.name] else { fatalError("A tool snapshot drifted") }

        let guessed = try await a.run("guess hidden", capabilities: aScope)
        do { _ = try await guessed.wait(); fatalError("unpublished tool was executable") }
        catch ToolRegistryError.unknownTool { /* expected */ }
        try await guessed.waitForDrain()
        let outOfScope = try await a.run("read B", capabilities: aScope)
        do { _ = try await outOfScope.wait(); fatalError("resource escaped A") }
        catch AgentCapabilityError.resourceOutsideScope { /* expected */ }
        try await outOfScope.waitForDrain()
        await aScope.revoke()
        do { _ = try await a.run("read A", capabilities: aScope); fatalError("old generation revived") }
        catch AgentCapabilityError.revoked { /* expected */ }

        let first = try await b.run("write B", capabilities: bScope, operationID: "one-effect")
        let firstResult = try await first.wait()
        try await first.waitForDrain()
        guard firstResult.receipts.count == 1,
              try String(contentsOf: effect, encoding: .utf8) == "effect\n",
              await bScope.status().finalAdmissions == 1 else { fatalError("B mutation was not settled") }
        let bRequest = try require(await provider.requests().last(where: { $0.sessionID == b.id && $0.tools.count == 1 }))
        guard bRequest.tools.map(\.name) == [FixtureWriteTool.name] else { fatalError("B tool snapshot drifted") }
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory.appendingPathComponent("journal"))
        let retrySession = try agent.makeSession(journal: reopened)
        let retryScope = try await retrySession.bindCapabilities(identity: "project-B", version: "v2",
            backendInstanceID: "local", backendVersion: "v2",
            allowedResources: [.named(.init(namespace: "fixture.file", id: "B"))],
            tools: [.init(id: "write", version: "v2", tool: try FixtureWriteTool(file: effect))])
        let retry = try await retrySession.run("write B", capabilities: retryScope, operationID: "one-effect")
        let reused = try await retry.wait()
        try await retry.waitForDrain()
        guard reused.receipts.first?.receipt == firstResult.receipts.first?.receipt,
              await retryScope.status().finalAdmissions == 0,
              try String(contentsOf: effect, encoding: .utf8) == "effect\n" else {
            fatalError("settled operation re-entered the executor")
        }
        try await reopened.close()
        print("Scoped fixture passed: two Sessions, isolated tool sets, forbidden name/resource, revoke, durable settlement and no-replay restart")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureError.missingRequest }
        return value
    }

    private static func finish(_ run: AgentRun) async throws {
        _ = try await run.wait()
        try await run.waitForDrain()
    }
}

private enum FixtureError: Error { case missingRequest }

private actor FixtureRequests {
    var values: [ModelRequest] = []
    func append(_ request: ModelRequest) { values.append(request) }
}

private struct ScopedFixtureProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "scope-fixture", capabilities: [.streaming, .multiTurn, .tools])
    private let log = FixtureRequests()
    func requests() async -> [ModelRequest] { await log.values }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await log.append(request)
            let info = ResponseInfo(id: "fixed", model: request.model)
            try emit(.responseStarted(info))
            if case .user(let content)? = request.messages.last,
               case .text(let text)? = content.first {
                let name: String
                let arguments: String
                switch text {
                case "read A": name = FixtureReadTool.name; arguments = #"{"id":"A"}"#
                case "read B": name = FixtureReadTool.name; arguments = #"{"id":"B"}"#
                case "guess hidden": name = FixtureWriteTool.name; arguments = #"{"id":"B"}"#
                case "write B": name = FixtureWriteTool.name; arguments = #"{"id":"B"}"#
                default: name = ""; arguments = "{}"
                }
                if !name.isEmpty {
                    let call = ToolCall(id: .init(rawValue: "fixture-\(UUID())"), name: name,
                                        argumentsJSON: arguments, completeness: .complete)
                    try emit(.toolCallStarted(call.id, name: call.name))
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

private struct FixtureReadTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let id: String }
    static let name = "read_file"
    static let description = "Read a fixture resource"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    let policy: ToolPolicy
    init() throws { policy = try .readOnly(authorization: .notRequired) }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "fixture.file", id: input.id))]
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        .init(output: .init(id: input.id))
    }
}

private struct FixtureWriteTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = "write_file"
    static let description = "Append to a temporary fixture file"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let file: URL
    let policy: ToolPolicy
    init(file: URL) throws {
        self.file = file
        policy = try .mutation(authorization: .notRequired, evidence: .none)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "fixture.file", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "fixture.file", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("effect\n".utf8))
        try handle.synchronize()
        try handle.close()
        return .init(output: .init(updated: true), receipt: .init(
            operationID: context.idempotencyKey ?? "", status: .succeeded,
            confirmedTargets: [.init(namespace: "fixture.file", id: input.id)], revision: "v1"))
    }
}
