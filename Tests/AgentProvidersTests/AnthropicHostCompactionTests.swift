import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentProviders
import AgentTools
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct AnthropicHostCompactionTests {
    let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    let model = ModelID(provider: "anthropic", name: "claude-sonnet-5-5")
    func provider(_ probe: ProviderRequestProbe, bodies: [Data]) throws -> AnthropicProvider {
        try .init(apiKey: "fixture", thinking: .serviceDefault,
            nativeContext: .init(qualification: .init(endpoint: endpoint, resolvedModelNames: [model.name], modes: [.anthropicOnDemand]),
                inlineToolChanges: true, runReminders: true),
            transport: FixtureHTTPTransport(probe: probe, bodies: bodies, chunkBytes: 7))
    }
    func binding(_ provider: AnthropicProvider, beforeGeneration: Bool = false) throws -> AgentModelBinding {
        try .init(profileID: "host-reminder", profileRevision: "1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"),
            nativeContextPolicy: beforeGeneration ? .init(compactBeforeGeneration: .anthropicOnDemand) : nil)
    }
    func fixture(_ data: Data, second: Bool = false) -> Data {
        Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"model\":\"fixture\"", with: "\"model\":\"claude-sonnet-5-5\"")
            .replacingOccurrences(of: "toolu-1", with: second ? "toolu-2" : "toolu-1").utf8)
    }
    func summary() throws -> Data {
        try AnthropicNativeContextTests().fixture(block: .object(["type": .string("compaction"), "content": .string("earlier facts"),
            "signature": .string("fixture-only-signature"), "tool_changes": .array([])]), threshold: false)
    }
    @Test(arguments: [false, true])
    func completedReminderTurnCanCompactThenResumeWithNewReminder(_ reopen: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-reminder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "host", supportsNativeContext: true)
        let probe = ProviderRequestProbe()
        let adapter = try provider(probe, bodies: [fixture(anthropicToolFixture), fixture(anthropicTextFixture), fixture(try summary()),
            fixture(anthropicToolFixture, second: true), fixture(anthropicTextFixture)])
        let agent = try Agent(binding: binding(adapter), tools: [HostEnglishTool()], configuration: .init(instructions: "Trusted root constraint"))
        var session = try agent.makeSession(journal: journal)
        let one = try await session.run("real user one", contextControls: .init(reminder: "本轮请用中文回答"))
        #expect(try await one.wait().outcome == .completed); try await one.waitForDrain()
        let canonical = await session.history
        let operation = try await session.compact(mode: .anthropicOnDemand)
        #expect(try await operation.wait().checkpoint != nil); try await operation.waitForDrain()
        #expect(await session.history == canonical)
        let checkpoint = try #require(try await journal.nativeContextCheckpoint(sessionID: session.id))
        if reopen {
            let id = session.id
            try await journal.close()
            journal = try AgentIncrementalJournal.open(at: directory)
            session = try agent.makeSession(id: id, journal: journal)
        }
        let two = try await session.run("real user two", contextControls: .init(reminder: "新一轮请用中文回答"))
        #expect(try await two.wait().outcome == .completed); try await two.waitForDrain()
        #expect(try await journal.nativeContextCheckpoint(sessionID: session.id)?.id == checkpoint.id)
        #expect(Array(await session.history.prefix(canonical.count)) == canonical)
        let requests = await probe.requests
        #expect(requests.count == 5)
        for request in requests {
            guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!) else { Issue.record("missing request"); continue }
            #expect(fields["thinking"] == nil)
        }
        let body = try JSONDecoder().decode(JSONValue.self, from: requests[4].httpBody!)
        guard case .object(let fields) = body, case .array(let messages) = fields["messages"] else { Issue.record("missing messages"); return }
        let encoded = String(decoding: requests[4].httpBody!, as: UTF8.self)
        #expect(!encoded.contains("real user one"))
        #expect(!encoded.contains("本轮请用中文回答"))
        #expect(encoded.contains("English tool result"))
        #expect(messages.filter { value in
            guard case .object(let fields) = value else { return false }
            return fields["role"] == .string("system") && fields["clear_at"] == .string("next_user_message")
        }.count == 2)
        #expect(try await journal.readMessages(sessionID: session.id).map(\.message) == Array(session.history.dropFirst()))
        try await journal.close()
    }
    @Test(arguments: [false, true])
    func completedReminderCanCompactRepeatedlyInMemoryOrAfterFileReopen(_ durable: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("repeat-reminder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ProviderRequestProbe()
        let adapter = try provider(probe, bodies: [fixture(anthropicTextFixture), fixture(try summary()), fixture(try summary())])
        let agent = try Agent(binding: binding(adapter))
        var journal = durable ? try AgentIncrementalJournal.create(at: directory, operationDomain: "host", supportsNativeContext: true) : AgentJournal()
        var session = try agent.makeSession(journal: journal)
        let run = try await session.run("user", contextControls: .init(reminder: "turn reminder"))
        _ = try await run.wait(); try await run.waitForDrain()
        let canonical = await session.history
        for _ in 0..<2 {
            if durable {
                let id = session.id
                try await journal.close(); journal = try AgentIncrementalJournal.open(at: directory)
                session = try agent.makeSession(id: id, journal: journal)
            }
            let op = try await session.compact(mode: .anthropicOnDemand)
            #expect(try await op.wait().checkpoint != nil); try await op.waitForDrain()
        }
        #expect(await session.history == canonical)
        #expect(await probe.requests.count == 3)
        try await journal.close()
    }

    @Test(arguments: [false, true])
    func failedOrCancelledSummaryRetainsPublishedCheckpointAndControls(_ cancel: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-summary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "host", supportsNativeContext: true)
        let probe = ProviderRequestProbe(), gate = HostSummaryGate()
        let transport = HostSummaryTransport(probe: probe, bodies: [fixture(anthropicTextFixture), fixture(try summary()), fixture(anthropicTextFixture)], gate: cancel ? gate : nil)
        let adapter = try AnthropicProvider(apiKey: "fixture", thinking: .serviceDefault,
            nativeContext: .init(qualification: .init(endpoint: endpoint, resolvedModelNames: [model.name], modes: [.anthropicOnDemand]), runReminders: true), transport: transport)
        let session = try Agent(binding: binding(adapter)).makeSession(journal: journal)
        let run = try await session.run("user", contextControls: .init(reminder: "trusted reminder"))
        _ = try await run.wait(); try await run.waitForDrain()
        let first = try await session.compact(mode: .anthropicOnDemand)
        let checkpoint = try #require(try await first.wait().checkpoint); try await first.waitForDrain()
        let before = try await session.conversationSnapshot()
        let second = try await session.compact(mode: .anthropicOnDemand)
        if cancel { await gate.waitEntered(); await second.cancel(); await gate.release() }
        await #expect(throws: (any Error).self) { try await second.wait() }
        try await second.waitForDrain()
        #expect(try await session.conversationSnapshot() == before)
        #expect(try await journal.nativeContextCheckpoint(sessionID: session.id) == checkpoint)
        #expect(await probe.requests.count == 3)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.nativeContextCheckpoint(sessionID: session.id) == checkpoint)
        #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.history == before.messages)
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func failedDurableOrUnknownRestoredReminderTerminalCannotCompact(_ unknown: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-terminal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = unknown ? AgentJournal() : try AgentIncrementalJournal.create(at: directory, operationDomain: "host", supportsNativeContext: true)
        let probe = ProviderRequestProbe()
        let adapter = try provider(probe, bodies: unknown ? [fixture(anthropicTextFixture)] : [])
        let agent = try Agent(binding: binding(adapter))
        var session = try agent.makeSession(journal: journal)
        let run = try await session.run("user", contextControls: .init(reminder: "required reminder"))
        if unknown { _ = try await run.wait() }
        else { await #expect(throws: ModelProviderError.self) { try await run.wait() } }
        try await run.waitForDrain()
        session = try agent.makeSession(id: session.id, journal: journal)
        let canonical = try await session.conversationSnapshot()
        let operation = try await session.compact(mode: .anthropicOnDemand)
        do { _ = try await operation.wait(); Issue.record("unproved terminal compacted") }
        catch let error as ModelProviderError { #expect(error.kind == .unsupportedCapability) }
        try await operation.waitForDrain()
        #expect(try await session.conversationSnapshot() == canonical)
        #expect(try await journal.nativeContextCheckpoint(sessionID: session.id) == nil)
        #expect(await probe.requests.count == 1)
        try await journal.close()
    }

    @Test(arguments: [false, true])
    func runLocalCompactCannotEraseRequiredReminderBeforeGeneration(_ durable: Bool) async throws {
        let probe = ProviderRequestProbe()
        let adapter = try provider(probe, bodies: [fixture(try summary()), fixture(anthropicTextFixture)])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("run-local-reminder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = durable ? try AgentIncrementalJournal.create(at: directory, operationDomain: "host", supportsNativeContext: true) : AgentJournal()
        let session = try Agent(binding: binding(adapter, beforeGeneration: true)).makeSession(journal: journal)
        let correlation = try AgentRunCorrelation(key: "preflight-refusal", payloadDigest: "fixture")
        do {
            let run = try await session.run("current user", contextControls: .init(reminder: "Required current turn instruction"), correlation: durable ? correlation : nil)
            _ = try await run.wait(); try await run.waitForDrain()
            Issue.record("run-local compaction erased the required reminder")
        } catch let error as ModelProviderError { #expect(error.kind == .unsupportedCapability) }
        #expect(await probe.requests.isEmpty)
        #expect(await session.history.isEmpty)
        #expect(try await journal.nativeContextCheckpoint(sessionID: session.id) == nil)
        if durable { #expect(try await journal.runRecord(sessionID: session.id, correlationKey: correlation.key) == .notAdmitted) }
        try await journal.close()
    }
}
private struct HostEnglishTool: AgentTool {
    typealias Input = ProviderCalculator.Input
    struct Output: Codable, Sendable { let result: String }
    static let name = "calculator"
    static let description = ProviderCalculator.description
    static let inputSchema = ProviderCalculator.inputSchema
    static let outputSchema = ToolSchema.object(properties: ["result": .string], required: ["result"])
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired)
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        .init(output: .init(result: "English tool result"))
    }
}

actor HostSummaryGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { c in
            blocked = c; entered = true
            observers.forEach { $0.resume() }; observers.removeAll()
        }
    }
    func waitEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { blocked?.resume(); blocked = nil }
}
struct HostSummaryTransport: ProviderHTTPTransport {
    let probe: ProviderRequestProbe
    let bodies: [Data]
    let gate: HostSummaryGate?
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                let index = await probe.record(request) - 1
                if index == 2, let gate { await gate.pause() }
                c.yield(.response(status: 200, headers: ["Content-Type": "text/event-stream"]))
                c.yield(.data(bodies[index])); c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}
