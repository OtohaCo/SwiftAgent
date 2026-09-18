import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentRecoverableToolErrorTests {
    @Test func declaredRecoverableReadOnlyErrorBecomesModelVisibleAndContinues() async throws {
        let call = recoverableCall(id: "missing-call", query: "missing")
        let provider = ScriptedProvider { request, turn in
            if turn == 1 { return toolResponse(request, [call]) }
            let expected = ToolResultMessage(
                callID: call.id,
                content: [.json(.object([
                    "code": .string("not_found"),
                    "message": .string("No matching resource was found."),
                    "details": .object(["query": .string("missing")]),
                ]))],
                isError: true
            )
            #expect(request.messages.suffix(2) == [
                .assistant(content: [], toolCalls: [call]),
                .tool(expected),
            ])
            return textResponse(request, "I couldn't find it. I can try another source.")
        }
        let probe = RecoverableProbe()
        let run = try await Agent(model: fixtureModel, provider: provider,
                                  tools: [try RecoverableSearchTool(probe: probe)]).makeSession().run("Find X")
        let events = Task { await collectRecoverableEvents(run.events) }

        let result = try await run.wait()

        #expect(result.outcome == .completed)
        #expect(result.modelTurns == 2)
        #expect(result.toolCalls == 1)
        #expect(result.receipts.isEmpty)
        #expect(await probe.executions == 1)
        #expect((await events.value).contains {
            if case .toolCompleted(let message) = $0 { return message.callID == call.id && message.isError }
            return false
        })
    }

    @Test func ordinarySwiftErrorStillFailsTheRun() async throws {
        let call = recoverableCall(id: "ordinary", query: "ordinary")
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let session = try Agent(model: fixtureModel, provider: provider,
                                tools: [try RecoverableSearchTool(probe: RecoverableProbe())]).makeSession()

        await #expect(throws: RecoverableFixtureError.ordinary) {
            _ = try await session.run("Search").wait()
        }
        #expect(await provider.log.requests.count == 1)
        #expect(!(await session.history).contains {
            if case .tool(let message) = $0 { return message.isError }
            return false
        })
    }

    @Test func recoverableErrorWithoutPolicyOptInStillFailsTheRun() async throws {
        let call = recoverableCall(id: "not-opted-in", query: "missing")
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let tool = try RecoverableSearchTool(
            probe: RecoverableProbe(),
            recoverableErrors: .failClosed
        )
        let session = try Agent(model: fixtureModel, provider: provider, tools: [tool]).makeSession()

        await #expect(throws: RecoverableToolError.self) {
            _ = try await session.run("Search").wait()
        }
        #expect(await provider.log.requests.count == 1)
        #expect(!(await session.history).contains {
            if case .tool(let message) = $0 { return message.isError }
            return false
        })
    }

    @Test func mutationCannotOptIntoModelVisibleErrors() {
        #expect(throws: ToolPolicyError.mutationCannotExposeRecoverableErrors) {
            try ToolPolicy(
                effect: .mutation,
                execution: .exclusive,
                idempotency: .requiresReceipt,
                timeout: .seconds(1),
                recoverableErrors: .modelVisible
            )
        }
    }

    @Test func authorizationFailureStaysFailClosed() async throws {
        let call = recoverableCall(id: "denied", query: "missing")
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let tool = try RecoverableSearchTool(probe: RecoverableProbe(), authorization: .required)

        await #expect(throws: ToolInvocationError.authorizationDenied) {
            _ = try await Agent(model: fixtureModel, provider: provider, tools: [tool])
                .makeSession().run("Search").wait()
        }
        #expect(await provider.log.requests.count == 1)
    }

    @Test func malformedArgumentsAndUnknownToolsStayFailClosed() async throws {
        let calls = [
            ToolCall(id: .init(rawValue: "malformed"), name: RecoverableSearchTool.name,
                     argumentsJSON: #"{"query":1}"#, completeness: .complete),
            ToolCall(id: .init(rawValue: "unknown"), name: "unknown_tool",
                     argumentsJSON: "{}", completeness: .complete),
        ]
        for call in calls {
            let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
            let session = try Agent(model: fixtureModel, provider: provider,
                                    tools: [try RecoverableSearchTool(probe: RecoverableProbe())]).makeSession()
            await #expect(throws: (any Error).self) { _ = try await session.run("Search").wait() }
            #expect(await provider.log.requests.count == 1)
        }
    }

    @Test func parallelSuccessErrorSuccessPreservesProposalOrder() async throws {
        let calls = [
            recoverableCall(id: "a", query: "A"),
            recoverableCall(id: "missing", query: "missing"),
            recoverableCall(id: "c", query: "C"),
        ]
        let provider = ScriptedProvider { request, turn in
            if turn == 1 { return toolResponse(request, calls) }
            let results = request.messages.compactMap { message -> ToolResultMessage? in
                if case .tool(let result) = message { return result }
                return nil
            }
            #expect(results.map(\.callID) == calls.map(\.id))
            #expect(results.map(\.isError) == [false, true, false])
            return textResponse(request, "Done")
        }

        let result = try await Agent(model: fixtureModel, provider: provider,
                                     tools: [try RecoverableSearchTool(probe: RecoverableProbe())])
            .makeSession().run("Search all").wait()

        #expect(result.outcome == .completed)
        #expect(result.toolCalls == 3)
    }

    @Test func crossRunAndRestartPreserveRecoverableTranscript() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-recoverable-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let sessionID = UUID()
        let call = recoverableCall(id: "restart-call", query: "missing")
        let provider = ScriptedProvider { request, turn in
            if turn == 1 { return toolResponse(request, [call]) }
            if turn == 2 { return textResponse(request, "Not found") }
            #expect(request.messages.contains {
                if case .tool(let result) = $0 { return result.callID == call.id && result.isError }
                return false
            })
            return textResponse(request, "Trying another source")
        }
        let agent = try Agent(model: fixtureModel, provider: provider,
                              tools: [try RecoverableSearchTool(probe: RecoverableProbe())])
        let firstSession = try agent.makeSession(id: sessionID, journal: AgentJournal(persistenceURL: url))
        let firstRun = try await firstSession.run("Find X")
        _ = try await firstRun.wait()
        try await firstRun.waitForDrain()

        let restarted = try agent.makeSession(id: sessionID, journal: AgentJournal.load(from: url))
        let result = try await restarted.run("Try another source").wait()

        #expect(result.outcome == .completed)
    }

    @Test func recoverableFailureDoesNotPublishEvidenceOrReceipt() async throws {
        let call = recoverableCall(id: "evidence", query: "missing")
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "Done")
        }
        let result = try await Agent(model: fixtureModel, provider: provider,
                                     tools: [try RecoverableSearchTool(probe: RecoverableProbe())])
            .makeSession().run("Search").wait()

        #expect(result.receipts.isEmpty)
        #expect(result.history.contains {
            if case .tool(let message) = $0 { return message.isError }
            return false
        })
    }

    @Test func recoverablePayloadCannotMintEvidence() async throws {
        let search = ToolCall(id: .init(rawValue: "error-evidence"), name: RecoverableEvidenceTool.name,
                              argumentsJSON: "{}", completeness: .complete)
        let use = ToolCall(id: .init(rawValue: "use-evidence"), name: ResourceUse.name,
                           argumentsJSON: "{}", completeness: .complete)
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [search]) : toolResponse(request, [use])
        }
        let agent = try Agent(model: fixtureModel, provider: provider,
                              tools: [RecoverableEvidenceTool(), ResourceUse(scope: .sameRun)])

        await #expect(throws: EvidenceError.self) {
            _ = try await agent.makeSession().run("Find and use resource-1").wait()
        }
        #expect(await provider.log.requests.count == 2)
    }

    @Test func mixedRecoverableAndOrdinaryFailureStillFailsClosed() async throws {
        let calls = [
            recoverableCall(id: "success", query: "A"),
            recoverableCall(id: "recoverable", query: "missing"),
            recoverableCall(id: "fatal", query: "ordinary"),
        ]
        let provider = ScriptedProvider { request, _ in toolResponse(request, calls) }
        let session = try Agent(model: fixtureModel, provider: provider,
                                tools: [try RecoverableSearchTool(probe: RecoverableProbe())]).makeSession()

        await #expect(throws: RecoverableFixtureError.ordinary) {
            _ = try await session.run("Search all").wait()
        }
        #expect(await provider.log.requests.count == 1)
    }

    @Test func recoverableErrorRequiresStableCodeAndMessage() {
        #expect(throws: RecoverableToolErrorValidationError.emptyCode) {
            _ = try RecoverableToolError(code: " ", message: "Visible")
        }
        #expect(throws: RecoverableToolErrorValidationError.emptyMessage) {
            _ = try RecoverableToolError(code: "not_found", message: "\n")
        }
    }

    @Test func modelTurnBudgetStillAppliesAfterRecoverableError() async throws {
        let first = recoverableCall(id: "budget-first", query: "missing")
        let second = recoverableCall(id: "budget-second", query: "another")
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [first]) : toolResponse(request, [second])
        }
        let probe = RecoverableProbe()
        let loop = AgentLoop(
            model: fixtureModel,
            provider: provider,
            tools: try ToolRegistry(tools: [AnyAgentTool(try RecoverableSearchTool(probe: probe))])
        )

        await #expect(throws: AgentLoopError.modelTurnLimitReached) {
            _ = try await loop.run(messages: [], sessionID: UUID(), budget: testBudget(turns: 2))
        }
        #expect(await provider.log.requests.count == 2)
        #expect(await probe.executions == 1)
    }

    @Test func cancellationWinsOverALateRecoverableError() async throws {
        let gate = RecoverableGate()
        let entered = XCTestExpectation(description: "Recoverable tool entered")
        let returned = XCTestExpectation(description: "Recoverable tool returned")
        let call = ToolCall(id: .init(rawValue: "late-error"), name: LateRecoverableTool.name,
                            argumentsJSON: "{}", completeness: .complete)
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let tool = try LateRecoverableTool(gate: gate, entered: entered, returned: returned)
        let session = try Agent(model: fixtureModel, provider: provider, tools: [tool]).makeSession()
        let run = try await session.run("Search")

        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [returned], timeout: 1) == .completed)
        try await run.waitForDrain()

        #expect(await provider.log.requests.count == 1)
        #expect(!(await session.history).contains {
            if case .tool(let message) = $0 { return message.isError }
            return false
        })
    }
}

private actor RecoverableProbe {
    private(set) var executions = 0
    func record() { executions += 1 }
}

private enum RecoverableFixtureError: Error, Equatable { case ordinary }

private actor RecoverableGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { waiters.append(continuation) }
        }
    }

    func open() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private struct LateRecoverableTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String

    static let name = "late_recoverable"
    static let description = "Return a recoverable error after release"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string

    let gate: RecoverableGate
    let entered: XCTestExpectation
    let returned: XCTestExpectation
    let policy: ToolPolicy

    init(gate: RecoverableGate, entered: XCTestExpectation, returned: XCTestExpectation) throws {
        self.gate = gate
        self.entered = entered
        self.returned = returned
        policy = try .readOnly(
            timeout: .seconds(5),
            authorization: .notRequired,
            recoverableErrors: .modelVisible
        )
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        entered.fulfill()
        await gate.wait()
        returned.fulfill()
        throw try RecoverableToolError(code: "not_found", message: "No result was found.")
    }
}

private struct RecoverableSearchTool: AgentTool {
    struct Input: Codable, Sendable { let query: String }
    struct Output: Codable, Sendable { let resources: [String] }

    static let name = "search_resource"
    static let description = "Search generic resources"
    static let inputSchema = ToolSchema.object(properties: ["query": .string], required: ["query"])
    static let outputSchema = ToolSchema.object(
        properties: ["resources": .array(items: .string)], required: ["resources"]
    )

    let probe: RecoverableProbe
    let policy: ToolPolicy

    init(
        probe: RecoverableProbe,
        authorization: ToolPolicy.Authorization = .notRequired,
        recoverableErrors: ToolPolicy.RecoverableErrors = .modelVisible
    ) throws {
        self.probe = probe
        policy = try ToolPolicy.readOnly(
            authorization: authorization,
            recoverableErrors: recoverableErrors
        )
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization { .denied }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.record()
        if input.query == "missing" {
            throw try RecoverableToolError(
                code: "not_found",
                message: "No matching resource was found.",
                details: .object(["query": .string(input.query)])
            )
        }
        if input.query == "ordinary" { throw RecoverableFixtureError.ordinary }
        return ToolResult(output: .init(resources: [input.query]))
    }
}

private struct RecoverableEvidenceTool: AgentTool {
    typealias Input = BlockingTool.Input
    typealias Output = String
    static let name = "recoverable_evidence_search"
    static let description = "Fail without publishing evidence"
    static let inputSchema = BlockingTool.inputSchema
    static let outputSchema = ToolSchema.string
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired, recoverableErrors: .modelVisible)

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        throw try RecoverableToolError(
            code: "not_found",
            message: "resource-1 was not found.",
            details: .object(["resource": .string("resource-1")])
        )
    }
}

private func recoverableCall(id: String, query: String) -> ToolCall {
    .init(id: .init(rawValue: id), name: RecoverableSearchTool.name,
          argumentsJSON: #"{"query":"\#(query)"}"#, completeness: .complete)
}

private func collectRecoverableEvents(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in stream { events.append(event) }
    return events
}
