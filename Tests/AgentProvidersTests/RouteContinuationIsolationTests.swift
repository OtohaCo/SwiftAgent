import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentProviders
import AgentTools
import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Route's candidates are separate service instances. Opaque continuation state one candidate
/// produced is sent only back to that candidate; no other candidate's transport ever receives it.
@Suite struct RouteContinuationIsolationTests {
    private let model = ModelID(provider: "openai", name: "fixture")

    @Test func sameRunFallbackNeverForwardsAnotherCandidatesContinuation() async throws {
        let a = IsolationEndpoint("a", replies: [.body(reasoningToolTurn), .status(503)])
        let b = IsolationEndpoint("b", replies: [.body(textTurn)])
        let route = try ModelProviderRoute(id: "openai", candidates: [try a.provider(), try b.provider()],
                                           policy: .init(maxAttempts: 2))
        let run = try await Agent(model: model, provider: route, tools: [try ProviderCalculator()]).makeSession().run("Add 2 and 3")
        await #expect(throws: ModelProviderError.self) { try await Self.expectFallbackBlocked(run) }
        try await run.waitForDrain()
        #expect(await a.requestCount == 2)
        #expect(await b.requestCount == 0)
    }

    @Test func laterRunWithContinuationHistoryStaysOnItsCandidate() async throws {
        let a = IsolationEndpoint("a", replies: [.body(reasoningToolTurn), .body(textTurn), .body(textTurn), .status(503)])
        let b = IsolationEndpoint("b", replies: [.body(textTurn), .body(textTurn)])
        let route = try ModelProviderRoute(id: "openai", candidates: [try a.provider(), try b.provider()],
                                           policy: .init(maxAttempts: 2))
        let session = try Agent(model: model, provider: route, tools: [try ProviderCalculator()]).makeSession()
        _ = try await session.run("Add 2 and 3").wait()
        #expect(await a.requestCount == 2)

        // The owning candidate serves the next Run and receives its own state back.
        _ = try await session.run("Again").wait()
        #expect(await a.lastBody.contains("encrypted-reasoning"))

        let blocked = try await session.run("Once more")
        await #expect(throws: ModelProviderError.self) { try await Self.expectFallbackBlocked(blocked) }
        try await blocked.waitForDrain()
        #expect(await a.requestCount == 4)
        #expect(await b.requestCount == 0)
    }

    @Test func fallbackWithoutContinuationStillSwitchesCandidates() async throws {
        let a = IsolationEndpoint("a", replies: [.status(503)])
        let b = IsolationEndpoint("b", replies: [.body(textTurn)])
        let route = try ModelProviderRoute(id: "openai", candidates: [try a.provider(), try b.provider()],
                                           policy: .init(maxAttempts: 2))
        let result = try await Agent(model: model, provider: route).makeSession().run("Hello").wait()
        #expect(result.outcome == .completed)
        #expect(await a.requestCount == 1)
        #expect(await b.requestCount == 1)
    }

    /// Candidate identity is declared by the Host, so it survives a restart and a new candidate order.
    @Test func reopenedSessionReachesTheOwningCandidateAfterReorder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("route-reopen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let firstA = IsolationEndpoint("a", replies: [.body(reasoningToolTurn), .body(textTurn)])
        let firstB = IsolationEndpoint("b", replies: [])
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "route-reopen")
        let first = try ModelProviderRoute(id: "openai", candidates: [
            .init(id: "primary", provider: try firstA.provider()), .init(id: "secondary", provider: try firstB.provider()),
        ], policy: .init(maxAttempts: 2))
        try await Self.finish(try await Agent(model: model, provider: first, tools: [try ProviderCalculator()])
            .makeSession(id: sessionID, journal: journal).run("Add 2 and 3"))
        try await journal.close()

        let a = IsolationEndpoint("a", replies: [.body(textTurn), .status(503)])
        let b = IsolationEndpoint("b", replies: [.body(textTurn), .body(textTurn)])
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let reordered = try ModelProviderRoute(id: "openai", candidates: [
            .init(id: "secondary", provider: try b.provider()), .init(id: "primary", provider: try a.provider()),
        ], policy: .init(maxAttempts: 2))
        let session = try Agent(model: model, provider: reordered, tools: [try ProviderCalculator()])
            .makeSession(id: sessionID, journal: reopened)
        #expect(try await Self.finish(try await session.run("Again")).outcome == .completed)
        #expect(await a.requestCount == 1)
        // The owner receives its native state, not the Route's record of which candidate produced it.
        #expect(await a.lastBody.contains("encrypted-reasoning"))
        #expect(await !a.lastBody.contains("swiftagent.route"))

        let blocked = try await session.run("Once more")
        await #expect(throws: ModelProviderError.self) { try await Self.expectFallbackBlocked(blocked) }
        try await blocked.waitForDrain()
        #expect(await a.requestCount == 2)
        #expect(await b.requestCount == 0)
        try await reopened.close()
    }

    /// State the Route cannot attribute to one of its candidates is not sent to any of them.
    @Test(arguments: [UnknownOrigin.directProvider, .anonymousRouteBeforeRestart, .removedCandidate])
    func continuationOfUnknownOriginIsRefusedBeforeAnyRequest(_ origin: UnknownOrigin) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("route-unknown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let producer = IsolationEndpoint("a", replies: [.body(reasoningToolTurn), .body(textTurn)])
        let first: any ModelProvider
        switch origin {
        case .directProvider: first = try producer.provider()
        case .anonymousRouteBeforeRestart:
            first = try ModelProviderRoute(id: "openai", candidates: [try producer.provider()])
        case .removedCandidate:
            first = try ModelProviderRoute(id: "openai", candidates: [.init(id: "retired", provider: try producer.provider())])
        }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "route-unknown")
        try await Self.finish(try await Agent(model: model, provider: first, tools: [try ProviderCalculator()])
            .makeSession(id: sessionID, journal: journal).run("Add 2 and 3"))
        try await journal.close()

        let a = IsolationEndpoint("a", replies: [.body(textTurn)])
        let b = IsolationEndpoint("b", replies: [.body(textTurn)])
        let route: ModelProviderRoute = origin == .anonymousRouteBeforeRestart
            ? try ModelProviderRoute(id: "openai", candidates: [try a.provider(), try b.provider()])
            : try ModelProviderRoute(id: "openai", candidates: [.init(id: "primary", provider: try a.provider()),
                                                               .init(id: "secondary", provider: try b.provider())])
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let run = try await Agent(model: model, provider: route, tools: [try ProviderCalculator()])
            .makeSession(id: sessionID, journal: reopened).run("Again")
        await #expect(throws: ModelProviderError.self) { try await Self.expectFallbackBlocked(run) }
        try await run.waitForDrain()
        #expect(await a.requestCount == 0)
        #expect(await b.requestCount == 0)
        try await reopened.close()
    }

    @Test func candidateIdentitiesMustBeUniqueAndNonEmpty() throws {
        let a = IsolationEndpoint("a", replies: [])
        for ids in [["same", "same"], ["", "b"], [" ", "b"]] {
            #expect(throws: ModelProviderFallbackPolicyError.self, "\(ids)") {
                _ = try ModelProviderRoute(id: "openai", candidates: try ids.map { .init(id: $0, provider: try a.provider()) })
            }
        }
    }

    enum UnknownOrigin: Sendable { case directProvider, anonymousRouteBeforeRestart, removedCandidate }

    @discardableResult
    private static func finish(_ run: AgentRun) async throws -> AgentLoopResult {
        let result = try await run.wait()
        try await run.waitForDrain()
        return result
    }

    private static func expectFallbackBlocked(_ run: AgentRun) async throws {
        do { _ = try await run.wait() } catch let error as ModelProviderError {
            #expect(error.kind == .fallbackBlocked, "\(error)")
            throw error
        }
    }
}

/// One fake service instance: its own endpoint, key and scripted replies; it records every request.
private actor IsolationEndpoint {
    enum Reply: Sendable { case body(Data), status(Int) }
    nonisolated let name: String
    private let replies: [Reply]
    private var requests: [URLRequest] = []

    init(_ name: String, replies: [Reply]) {
        self.name = name
        self.replies = replies
    }

    var requestCount: Int { requests.count }
    var lastBody: String { String(decoding: requests.last?.httpBody ?? Data(), as: UTF8.self) }

    nonisolated func provider() throws -> OpenAIResponsesProvider {
        try OpenAIResponsesProvider(apiKey: "key-\(name)", endpoint: URL(string: "https://\(name).example/v1/responses"),
                                    reasoningEffort: .medium, transport: IsolationTransport(endpoint: self))
    }

    func reply(to request: URLRequest) -> Reply? {
        requests.append(request)
        return replies.indices.contains(requests.count - 1) ? replies[requests.count - 1] : nil
    }
}

private struct IsolationTransport: ProviderHTTPTransport {
    let endpoint: IsolationEndpoint

    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch await endpoint.reply(to: request) {
                case .body(let data):
                    continuation.yield(.response(status: 200, headers: ["Content-Type": "text/event-stream"]))
                    continuation.yield(.data(data))
                case .status(let status):
                    continuation.yield(.response(status: status, headers: ["Content-Type": "application/json"]))
                    continuation.yield(.data(Data(#"{"error":{"message":"unavailable"}}"#.utf8)))
                case nil:
                    continuation.finish(throwing: ModelProviderError(kind: .transport, message: "Fixture replies exhausted."))
                    return
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private let reasoningToolTurn = providerNamedSSE([
    ("response.created", #"{"type":"response.created","response":{"id":"resp-reasoning","model":"fixture","status":"in_progress"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs-1","type":"reasoning","summary":[]}}"#),
    ("response.reasoning_summary_part.added", #"{"type":"response.reasoning_summary_part.added","item_id":"rs-1","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""}}"#),
    ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"rs-1","output_index":0,"summary_index":0,"delta":"Checked inputs."}"#),
    ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs-1","type":"reasoning","summary":[{"type":"summary_text","text":"Checked inputs."}],"encrypted_content":"encrypted-reasoning"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"","status":"in_progress"}}"#),
    ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","item_id":"fc-1","output_index":1,"delta":"{\"a\":2,\"b\":3}"}"#),
    ("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","item_id":"fc-1","output_index":1,"arguments":"{\"a\":2,\"b\":3}"}"#),
    ("response.output_item.done", #"{"type":"response.output_item.done","output_index":1,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"}}"#),
    ("response.completed", #"{"type":"response.completed","response":{"id":"resp-reasoning","model":"fixture","status":"completed","output":[{"id":"rs-1","type":"reasoning","summary":[{"type":"summary_text","text":"Checked inputs."}],"encrypted_content":"encrypted-reasoning"},{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"}],"usage":{"input_tokens":8,"output_tokens":7,"output_tokens_details":{"reasoning_tokens":2}}}}"#),
])

private let textTurn = openAITextFixture
