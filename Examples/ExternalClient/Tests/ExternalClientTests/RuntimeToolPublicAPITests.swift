import AgentCatalog
import AgentCore
import AgentDecisions
import AgentJevProvider
import AgentJournalFileStore
import AgentModels
import AgentTools
import AgentUsage
import Foundation
import Testing

/// Tools defined at runtime, used only through the published API. One runtime type serves several
/// bound tools, each checked against its own schemas and revoked with its binding. A mutation through
/// one settles with its Receipt, and a retry after the Journal reopens does not reach the executor.
struct RuntimeToolPublicAPITests {
    @Test func oneRuntimeTypeServesSeveralBoundToolsCheckedAgainstTheirOwnSchemas() async throws {
        let log = ConnectorLog()
        let provider = ConnectorProvider()
        let agent = try Agent(model: connectorModel, provider: provider)
        func bound(_ session: AgentSession) async throws -> AgentCapabilityBinding {
            try await session.bindCapabilities(identity: "connector", version: "1",
                backendInstanceID: "fixture", backendVersion: "1",
                allowedResources: [.named(connectorResource("A")), .named(connectorResource("broken"))],
                tools: [.init(id: "read", version: "1", tool: try ConnectorTool.read(log: log)),
                        .init(id: "lookup", version: "1", tool: try ConnectorTool.lookup(log: log))])
        }

        let session = try agent.makeSession()
        let binding = try await bound(session)
        #expect(binding.info.tools.map(\.name) == ["cap_lookup", "cap_read"])
        let read = try await session.run("read A", capabilities: binding)
        #expect(try await read.wait().outcome == .completed)
        try await read.waitForDrain()
        let offered = try #require(await provider.requests().first).tools
        #expect(offered.map(\.name).sorted() == ["cap_lookup", "cap_read"])
        #expect(offered.first { $0.name == "cap_read" } == ConnectorTool.readDefinition)
        #expect(await session.history.contains(.tool(.init(
            callID: .init(rawValue: "call-read A"),
            content: [.json(.object(["id": .string("A"), "text": .string("contents of A")]))], isError: false))))

        let badInputSession = try agent.makeSession()
        let badInput = try await badInputSession.run("read with a number", capabilities: try await bound(badInputSession))
        await #expect(throws: ToolRegistryError.self) {
            do { _ = try await badInput.wait() } catch let error as ToolRegistryError {
                guard case .invalidArguments = error else { throw ConnectorFailure.unexpected("\(error)") }
                throw error
            }
        }
        try await badInput.waitForDrain()

        let badOutputSession = try agent.makeSession()
        let badOutput = try await badOutputSession.run("lookup broken", capabilities: try await bound(badOutputSession))
        await #expect(throws: ToolRegistryError.self) {
            do { _ = try await badOutput.wait() } catch let error as ToolRegistryError {
                guard case .invalidOutput = error else { throw ConnectorFailure.unexpected("\(error)") }
                throw error
            }
        }
        try await badOutput.waitForDrain()
        // The ill-typed argument never reached an executor; the ill-typed answer did, and was refused.
        #expect(await log.calls == ["cap_read:A", "cap_lookup:broken"])
    }

    @Test func revokingARuntimeBindingStopsItsTools() async throws {
        let log = ConnectorLog()
        let session = try Agent(model: connectorModel, provider: ConnectorProvider()).makeSession()
        let binding = try await session.bindCapabilities(identity: "connector", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.named(connectorResource("A"))],
            tools: [.init(id: "read", version: "1", tool: try ConnectorTool.read(log: log))])
        #expect(binding.info.tools.map(\.name) == ["cap_read"])
        let first = try await session.run("read A", capabilities: binding)
        _ = try await first.wait()
        try await first.waitForDrain()

        await binding.revoke()
        await #expect(throws: AgentCapabilityError.revoked) {
            _ = try await session.run("read A", capabilities: binding)
        }
        #expect(await binding.status().revoked)
        #expect(await log.calls == ["cap_read:A"])
    }

    @Test func runtimeMutationSettlesWithItsReceiptAndIsNotReplayedAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-tool-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("A.txt")
        try Data().write(to: file)
        let journalURL = directory.appendingPathComponent("journal")
        let log = ConnectorLog()
        let agent = try Agent(model: connectorModel, provider: ConnectorProvider())
        func bound(_ session: AgentSession, version: String) async throws -> AgentCapabilityBinding {
            try await session.bindCapabilities(identity: "connector", version: version,
                backendInstanceID: "fixture", backendVersion: version,
                allowedResources: [.named(connectorResource("A"))],
                tools: [.init(id: "read", version: version, tool: try ConnectorTool.read(log: log)),
                        .init(id: "write", version: version, tool: try ConnectorTool.write(file: file, log: log))])
        }

        let journal = try AgentIncrementalJournal.create(at: journalURL, operationDomain: "runtime-tools")
        let session = try agent.makeSession(journal: journal)
        let binding = try await bound(session, version: "1")
        let run = try await session.run("write A", capabilities: binding, operationID: "append-once")
        let settled = try await run.wait()
        try await run.waitForDrain()
        let receipt = try #require(settled.receipts.first)
        #expect(settled.receipts.count == 1)
        #expect(receipt.effect == .mutation)
        #expect(receipt.receipt.status == .succeeded)
        #expect(receipt.receipt.confirmedTargets == [connectorResource("A")])
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
        #expect(await binding.status().finalAdmissions == 1)
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()

        // Another instance of the runtime type with the same definition, after the Journal reopens.
        let reopened = try AgentIncrementalJournal.open(at: journalURL)
        let retrySession = try agent.makeSession(journal: reopened)
        let retryBinding = try await bound(retrySession, version: "2")
        let retry = try await retrySession.run("write A", capabilities: retryBinding, operationID: "append-once")
        let replayed = try await retry.wait()
        try await retry.waitForDrain()
        #expect(replayed.receipts.map(\.receipt) == [receipt.receipt])
        #expect(await retryBinding.status().finalAdmissions == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect\n")
        #expect(await log.calls == ["cap_write:A"])
        try await reopened.close()
    }
}

private let connectorModel = ModelID(provider: "connector-fixture", name: "fixed")

private func connectorResource(_ id: String) -> EvidenceReference {
    EvidenceReference(namespace: "fixture.connector", id: id)
}

private enum ConnectorFailure: Error { case unexpected(String) }

private actor ConnectorLog {
    private(set) var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
}

/// One type for every connector tool; each instance is named and described when it is made.
private struct ConnectorTool: RuntimeAgentTool {
    enum Behavior: Sendable { case read, lookup, write(URL) }

    static let readDefinition = definition(name: "cap_read", output: ["id": .string, "text": .string])

    let runtimeDefinition: ModelToolDefinition
    let policy: ToolPolicy
    let behavior: Behavior
    let log: ConnectorLog

    static func read(log: ConnectorLog) throws -> Self {
        .init(runtimeDefinition: readDefinition, policy: try .readOnly(authorization: .notRequired),
              behavior: .read, log: log)
    }

    static func lookup(log: ConnectorLog) throws -> Self {
        .init(runtimeDefinition: definition(name: "cap_lookup", output: ["id": .string, "text": .string]),
              policy: try .readOnly(authorization: .notRequired), behavior: .lookup, log: log)
    }

    static func write(file: URL, log: ConnectorLog) throws -> Self {
        .init(runtimeDefinition: definition(name: "cap_write", output: ["written": .boolean]),
              policy: try .mutation(authorization: .notRequired, evidence: .none), behavior: .write(file), log: log)
    }

    private static func definition(name: String, output: [String: ToolSchema]) -> ModelToolDefinition {
        ModelToolDefinition(
            name: name, description: "Connector tool \(name)",
            inputSchema: ToolSchema.object(properties: ["id": .string], required: ["id"]).json,
            outputSchema: ToolSchema.object(properties: output, required: Set(output.keys)).json
        )
    }

    func resourceRequirements(for input: JSONValue) throws -> [ToolResource] {
        [.named(connectorResource(try Self.id(input)))]
    }

    func receiptExpectation(for input: JSONValue) throws -> ToolReceiptExpectation? {
        guard case .write = behavior else { return nil }
        return try .init(targets: [connectorResource(try Self.id(input))], revision: .present)
    }

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        let id = try Self.id(input)
        await log.record("\(runtimeDefinition.name):\(id)")
        switch behavior {
        case .read:
            return .init(output: .object(["id": .string(id), "text": .string("contents of \(id)")]))
        case .lookup:
            return .init(output: .object(["unexpected": .bool(true)]))
        case .write(let file):
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("effect\n".utf8))
            try handle.synchronize()
            try handle.close()
            return .init(output: .object(["written": .bool(true)]), receipt: .init(
                operationID: context.idempotencyKey ?? "", status: .succeeded,
                confirmedTargets: [connectorResource(id)], revision: "v1"))
        }
    }

    private static func id(_ input: JSONValue) throws -> String {
        guard case .object(let fields) = input, case .string(let id)? = fields["id"] else {
            throw ToolInvocationError.invalidArguments
        }
        return id
    }
}

/// Calls the tool named by the user's text, then answers once the result is in history.
private struct ConnectorProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "connector-fixture", capabilities: [.streaming, .multiTurn, .tools])
    private let log = ConnectorRequests()
    func requests() async -> [ModelRequest] { await log.values }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await log.append(request)
            let info = ResponseInfo(id: "fixed", model: request.model)
            try emit(.responseStarted(info))
            if case .user(let content)? = request.messages.last, case .text(let text)? = content.first,
               let (name, arguments) = Self.call(for: text) {
                let call = ToolCall(id: .init(rawValue: "call-\(text)"), name: name, argumentsJSON: arguments,
                                    completeness: .complete)
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
                try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
                return
            }
            try emit(.textDelta("done"))
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
        }
    }

    private static func call(for text: String) -> (String, String)? {
        switch text {
        case "read A": ("cap_read", #"{"id":"A"}"#)
        case "read with a number": ("cap_read", #"{"id":7}"#)
        case "lookup broken": ("cap_lookup", #"{"id":"broken"}"#)
        case "write A": ("cap_write", #"{"id":"A"}"#)
        default: nil
        }
    }
}

private actor ConnectorRequests {
    var values: [ModelRequest] = []
    func append(_ request: ModelRequest) { values.append(request) }
}
