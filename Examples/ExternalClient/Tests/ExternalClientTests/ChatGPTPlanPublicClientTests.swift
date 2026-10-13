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

/// Public-only Host fixture; no OAuth, network or paid inference. Bodies are real adapter output.
struct ChatGPTPlanPublicClientTests {
    @Test func namespacedToolLoopAndReopenPreserveCanonicalHistoryAndExecutionFacts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plan-client-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = PublicPlanProbe(), credentials = OpenAIChatGPTPlanCredentials(accessToken: { await probe.token() })
        let provider = OpenAIChatGPTPlanProvider(credentials: credentials, transport: PublicPlanTransport(probe: probe))
        let agent = try Agent(model: .init(provider: "openai", name: "fixture"), provider: provider,
            tools: [try PublicPlanTool(probe: probe)], configuration: .init(instructions: "Preserve this constraint"))
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "public-plan", supportsRunRecords: true)
        let id = UUID(), session = try agent.makeSession(id: id, journal: journal)
        let run = try await session.run("Use the tool", correlation: .init(key: "one", payloadDigest: "fixture"))
        #expect(try await run.wait().outcome == .completed)
        try await run.waitForDrain()
        let history = try #require(try await journal.latestCheckpoint(sessionID: id)).history
        // Runtime root instructions come from Agent configuration, not the durable checkpoint.
        #expect(await session.history == [.system("Preserve this constraint")] + history)
        #expect(history.first == .user([.text("Use the tool")]))
        #expect(history.filter { if case .tool = $0 { return true }; return false }.count == 1)
        #expect(await probe.executions == 1)
        let originalRecord = try await session.runRecord(runID: run.id)
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: id)?.history == history)
        let fresh = try agent.makeSession(id: id, journal: reopened)
        let next = try await fresh.run("Continue")
        #expect(try await next.wait().outcome == .completed)
        try await next.waitForDrain()
        #expect(try await fresh.runRecord(runID: run.id) == originalRecord)
        #expect(await probe.executions == 1)
        let final = try #require(try await reopened.latestCheckpoint(sessionID: id)).history
        #expect(Array(final.prefix(history.count)) == history)
        #expect(await fresh.history == [.system("Preserve this constraint")] + final)
        let requests = await probe.requests
        #expect(requests.count == 3)
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer public-1", "Bearer public-2", "Bearer public-3"])
        for request in requests {
            let body = try object(JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)))
            #expect(body["max_output_tokens"] == nil && body["include"] == nil && body["previous_response_id"] == nil)
            guard case .array(let input) = body["input"], case .array(let tools) = body["tools"] else { Issue.record("Missing input/tools"); return }
            #expect(try object(input[0])["role"] == .string("developer"))
            #expect(try object(input[0])["content"] == .string("Preserve this constraint"))
            #expect(try object(tools[0])["type"] == .string("namespace"))
        }
        let second = try object(JSONDecoder().decode(JSONValue.self, from: #require(requests[1].httpBody)))
        guard case .array(let input) = second["input"] else { Issue.record("Missing second input"); return }
        let calls = try input.map(object).filter { $0["type"] == .string("function_call") }
        #expect(calls.count == 1 && calls[0]["namespace"] == .string("swiftagent") && calls[0]["name"] == .string("plan_echo"))
        try await reopened.close()
    }
}

private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw PublicPlanFailure.shape }; return fields
}
private enum PublicPlanFailure: Error { case shape }
private actor PublicPlanProbe {
    private(set) var requests: [URLRequest] = []
    private(set) var executions = 0
    private var tokens = 0
    func token() -> String { tokens += 1; return "public-\(tokens)" }
    func execute() { executions += 1 }
    func record(_ request: URLRequest) -> Int { requests.append(request); return requests.count }
}
private struct PublicPlanTool: AgentTool {
    struct Input: Codable, Sendable { let text: String }
    struct Output: Codable, Sendable { let text: String }
    static let name = "plan_echo", description = "Echo the input"
    static let inputSchema = ToolSchema.object(properties: ["text": .string], required: ["text"])
    static let outputSchema = inputSchema
    let policy: ToolPolicy
    let probe: PublicPlanProbe
    init(probe: PublicPlanProbe) throws {
        self.probe = probe
        policy = try .init(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(2), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.execute(); return .init(output: .init(text: input.text))
    }
}
private struct PublicPlanTransport: ProviderHTTPTransport {
    let probe: PublicPlanProbe
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                let turn = await probe.record(request)
                let frames: [(String, String)]
                if turn == 1 {
                    frames = [
                        ("response.created", #"{"type":"response.created","response":{"id":"r1","model":"fixture","status":"in_progress"}}"#),
                        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc","type":"function_call","call_id":"call","namespace":"swiftagent","name":"plan_echo","arguments":"","status":"in_progress"}}"#),
                        ("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","output_index":0,"item_id":"fc","arguments":"{\"text\":\"keep\"}"}"#),
                        ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"fc","type":"function_call","call_id":"call","namespace":"swiftagent","name":"plan_echo","arguments":"{\"text\":\"keep\"}","status":"completed"}}"#),
                        ("response.completed", #"{"type":"response.completed","response":{"id":"r1","model":"fixture","status":"completed","output":[{"id":"fc","type":"function_call","call_id":"call","namespace":"swiftagent","name":"plan_echo","arguments":"{\"text\":\"keep\"}","status":"completed"}]}}"#),
                    ]
                } else {
                    frames = [
                        ("response.created", #"{"type":"response.created","response":{"id":"r2","model":"fixture","status":"in_progress"}}"#),
                        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
                        ("response.content_part.added", #"{"type":"response.content_part.added","output_index":0,"item_id":"msg","content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
                        ("response.output_text.delta", #"{"type":"response.output_text.delta","output_index":0,"item_id":"msg","content_index":0,"delta":"done"}"#),
                        ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"done","annotations":[]}]}}"#),
                        ("response.completed", #"{"type":"response.completed","response":{"id":"r2","model":"fixture","status":"completed","output":[{"id":"msg","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"done","annotations":[]}]}]}}"#),
                    ]
                }
                do {
                    let text = try frames.enumerated().map { index, frame in
                        var fields = try object(JSONDecoder().decode(JSONValue.self, from: Data(frame.1.utf8)))
                        fields["sequence_number"] = .number(Decimal(index))
                        let encoded = try JSONEncoder().encode(JSONValue.object(fields))
                        return "event: \(frame.0)\ndata: \(String(decoding: encoded, as: UTF8.self))\n\n"
                    }.joined()
                    continuation.yield(.response(status: 200, headers: ["Content-Type": "text/event-stream"]))
                    continuation.yield(.data(Data(text.utf8)))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}
