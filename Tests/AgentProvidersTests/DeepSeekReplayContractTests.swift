import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentProviders

struct DeepSeekReplayContractTests {
    private let model = ModelID(provider: "deepseek", name: "deepseek-flash")

    @Test(arguments: [DeepSeekReasoningEffort.high, .none])
    func nativeToolTurnSurvivesFileCloseReopenAndLaterProviderFailure(effort: DeepSeekReasoningEffort) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let executor = ProviderExecutionProbe()
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "deepseek-replay")
        let firstProvider = try provider(effort, probe: ProviderRequestProbe(), bodies: [
            deepSeekToolWithoutReasoningFixture(call: 1), serverFailure,
        ])
        let firstBinding = try binding(firstProvider, revision: effort.rawValue)
        let session = try Agent(model: model, provider: firstProvider, tools: [ReplayMutation(probe: executor)])
            .makeSession(id: sessionID, journal: journal)
        let run = try await session.run("Commit the sum", using: firstBinding)
        let observer = Task {
            var receipts: [AgentToolReceipt] = []
            for await event in run.events {
                if case .toolReceiptValidated(let receipt) = event { receipts.append(receipt) }
            }
            return receipts
        }
        do {
            _ = try await run.wait()
            Issue.record("Expected the later server failure")
        } catch let error as ModelProviderError {
            #expect(error.kind == .invalidResponse)
            #expect(error.diagnostic == .init(stage: .server, reason: .serverFailure))
        }
        try await run.waitForDrain()
        let receipt = try #require(await observer.value.only?.receipt)
        #expect(await executor.count == 1)
        let before = try await session.conversationSnapshot()
        #expect(before.messages.contains { if case .tool(let result) = $0 { result.callID.rawValue == "call-1" && !result.isError } else { false } })
        let status = try #require(try await journal.mutationStatus(identity: receipt.operationID))
        #expect(status.state == .settled && status.receipt == receipt && status.replayOutput != nil)
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()

        // A new store and Session restore from disk; neither reads the old actor.
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let probe = ProviderRequestProbe()
        let nextProvider = try provider(effort, probe: probe, bodies: [deepSeekTextWithoutReasoningFixture])
        let nextBinding = try binding(nextProvider, revision: effort.rawValue)
        let restored = try Agent(model: model, provider: nextProvider, tools: [ReplayMutation(probe: executor)])
            .makeSession(id: sessionID, journal: reopened)
        #expect(try await restored.conversationSnapshot().messages == before.messages)
        let next = try await restored.run("Continue", using: nextBinding)
        #expect(try await next.wait().outcome == .completed)
        try await next.waitForDrain()
        let request = try #require(await probe.requests.only)
        let body = try ProviderJSON.object(JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)))
        guard case .array(let input) = body["input"] else { Issue.record("Missing input"); return }
        #expect(input.count == 4)
        #expect(input[1] == deepSeekFunctionItem(call: 1))
        #expect(input[2] == deepSeekFunctionOutput(call: 1))
        #expect(!input.contains { (try? ProviderJSON.object($0))?["type"] == .string("reasoning") })
        #expect(await executor.count == 1)
        #expect(try await reopened.mutationStatus(identity: receipt.operationID) == status)
        #expect(try await reopened.pendingMutations().isEmpty)
        try await reopened.close()
    }

    @Test func reasoningCanReturnAfterAToolOnlyTurnWithoutLosingEarlierState() async throws {
        let probe = ProviderRequestProbe()
        let configured = try provider(.high, probe: probe, bodies: [
            deepSeekReasoningToolFixture(call: 1), deepSeekToolWithoutReasoningFixture(call: 2),
            deepSeekReasoningToolFixture(call: 3), deepSeekTextWithoutReasoningFixture,
        ])
        let executor = ProviderExecutionProbe()
        let run = try await Agent(model: model, provider: configured, tools: [ProviderCalculator(probe: executor)])
            .makeSession().run("Add three times", using: binding(configured))
        #expect(try await run.wait().toolCalls == 3)
        try await run.waitForDrain()
        let requests = await probe.requests
        let body = try ProviderJSON.object(JSONDecoder().decode(JSONValue.self, from: #require(requests[3].httpBody)))
        guard case .array(let input) = body["input"] else { Issue.record("Missing input"); return }
        #expect(Array(input.suffix(8)) == [
            deepSeekReasoningItem(call: 1), deepSeekFunctionItem(call: 1), deepSeekFunctionOutput(call: 1),
            deepSeekFunctionItem(call: 2), deepSeekFunctionOutput(call: 2),
            deepSeekReasoningItem(call: 3), deepSeekFunctionItem(call: 3), deepSeekFunctionOutput(call: 3),
        ])
        #expect(await executor.count == 3) // Equal arguments do not identify one business operation.
    }

    @Test(arguments: [DeepSeekReasoningEffort.high, .none])
    func bindingChangesAreRejectedBeforeInputCommitAndHandoffUsesEncoder(effort: DeepSeekReasoningEffort) async throws {
        let source = try provider(effort, probe: ProviderRequestProbe(), bodies: [
            deepSeekToolWithoutReasoningFixture(call: 1), deepSeekTextWithoutReasoningFixture,
        ])
        let session = try Agent(model: model, provider: source, tools: [ProviderCalculator()]).makeSession()
        let first = try await session.run("Add", using: binding(source, revision: effort.rawValue))
        _ = try await first.wait()
        try await first.waitForDrain()
        let snapshot = try await session.conversationSnapshot()
        let probe = ProviderRequestProbe()
        let target = try provider(effort == .none ? .high : .none, probe: probe, bodies: [deepSeekTextWithoutReasoningFixture])
        let changes: [AgentModelBinding] = [
            try binding(target, revision: "changed-effort"),
            try binding(target, revision: "changed-version"),
            try binding(target, revision: effort.rawValue, endpoint: "other-endpoint"),
            try binding(target, revision: effort.rawValue, targetModel: .init(provider: "deepseek", name: "deepseek-v4-pro")),
        ]
        for changed in changes {
            await #expect(throws: AgentModelBindingError.incompatibleContinuation) {
                try await session.run("must not commit", using: changed)
            }
            #expect(try await session.conversationSnapshot() == snapshot)
        }
        #expect(await probe.requests.isEmpty)

        await #expect(throws: AgentModelBindingError.invalidProjection) {
            try await session.run("must not commit", using: binding(source, revision: effort.rawValue, projector: UnresolvedToolProjector()))
        }
        #expect(try await session.conversationSnapshot() == snapshot)

        // Semantic handoff keeps closed call/result history but strips native state.
        // Thinking+tools cannot certify that history; thinking-off supports canonical encoding.
        let high = try provider(.high, probe: probe, bodies: [])
        do {
            _ = try await session.run("must not commit", using: binding(high, revision: "handoff", projector: AgentSemanticHandoffProjector()))
            Issue.record("Expected missing native state")
        } catch let error as ModelProviderError {
            #expect(error.kind == .invalidRequest)
            #expect(error.diagnostic == .init(stage: .requestValidation, reason: .missingContinuation))
        }
        #expect(try await session.conversationSnapshot() == snapshot)
        #expect(await probe.requests.isEmpty)
        let off = try provider(.none, probe: probe, bodies: [deepSeekTextWithoutReasoningFixture])
        let next = try await session.run("Continue", using: binding(off, revision: "handoff", projector: AgentSemanticHandoffProjector()))
        _ = try await next.wait()
        try await next.waitForDrain()
        let http = try #require(await probe.requests.only)
        let body = try ProviderJSON.object(JSONDecoder().decode(JSONValue.self, from: #require(http.httpBody)))
        guard case .array(let input) = body["input"] else { Issue.record("Missing input"); return }
        let calls = input.compactMap { try? ProviderJSON.object($0) }.filter { $0["type"] == .string("function_call") }
        #expect(calls.count == 1 && calls[0]["call_id"] == .string("call-1"))
        #expect(calls[0]["id"] == nil)
        #expect(input.contains(deepSeekFunctionOutput(call: 1)))
        #expect((await session.history).starts(with: snapshot.messages))
    }

    @Test func continuationMismatchReasonsArePrecise() throws {
        let calls = (1...2).map { ToolCall(id: .init(rawValue: "call-\($0)"), name: "calculator", argumentsJSON: #"{"a":2,"b":3}"#, completeness: .complete) }
        let state = try #require(try DeepSeekResponsesContinuation.make(
            items: [deepSeekReasoningItem(call: 1)] + (1...2).map(deepSeekFunctionItem),
            content: [.reasoning("Reason 1.")], calls: calls, model: model
        ))
        let content: [ModelContent] = [.reasoning("Reason 1."), .providerContinuation(state)]
        let changedArguments = ToolCall(id: calls[0].id, name: calls[0].name, argumentsJSON: #"{ "a":2,"b":3}"#, completeness: .complete)
        let variants: [([ModelContent], [ToolCall])] = [
            (content, [changedArguments, calls[1]]), (content, calls.reversed()),
            (content, [calls[0]]), ([.providerContinuation(state)], calls),
            ([.reasoning("Changed"), .providerContinuation(state)], calls),
            (content, [ToolCall(id: .init(rawValue: "replacement"), name: calls[0].name, argumentsJSON: calls[0].argumentsJSON, completeness: .complete), calls[1]]),
            (content, [ToolCall(id: calls[0].id, name: calls[0].name, argumentsJSON: calls[0].argumentsJSON, completeness: .incomplete), calls[1]]),
        ]
        for (parts, canonicalCalls) in variants {
            try expectContinuationMismatch(content: parts, calls: canonicalCalls)
        }
    }

    @Test func continuationRejectsChangedArgumentBytesEvenWhenUnicodeIsEquivalent() throws {
        let nativeArguments = "{\"value\":\"é\"}"
        let changedArguments = "{\"value\":\"e\u{301}\"}"
        #expect(!nativeArguments.utf8.elementsEqual(changedArguments.utf8))
        let call = ToolCall(id: .init(rawValue: "call-1"), name: "calculator", argumentsJSON: nativeArguments, completeness: .complete)
        var item = try ProviderJSON.object(deepSeekFunctionItem(call: 1))
        item["arguments"] = .string(nativeArguments)
        let state = try #require(try DeepSeekResponsesContinuation.make(items: [.object(item)], content: [], calls: [call], model: model))
        let changed = ToolCall(id: call.id, name: call.name, argumentsJSON: changedArguments, completeness: .complete)
        try expectContinuationMismatch(content: [.providerContinuation(state)], calls: [changed])
    }

    @Test func continuationRejectsChangedNativeCompletionStatus() throws {
        let call = ToolCall(id: .init(rawValue: "call-1"), name: "calculator", argumentsJSON: #"{"a":2,"b":3}"#, completeness: .complete)
        let state = try #require(try DeepSeekResponsesContinuation.make(items: [deepSeekFunctionItem(call: 1)], content: [], calls: [call], model: model))
        var payload = try ProviderJSON.object(JSONDecoder().decode(JSONValue.self, from: state.payload))
        var item = try ProviderJSON.object(deepSeekFunctionItem(call: 1))
        item["status"] = .string("incomplete")
        payload["items"] = .array([.object(item)])
        let tampered = ModelProviderContinuation(model: model, format: state.format, payload: try JSONEncoder().encode(JSONValue.object(payload)))
        try expectContinuationMismatch(content: [.providerContinuation(tampered)], calls: [call])
    }

    @Test func omittedNativeStatusRemainsReplayable() throws {
        let call = ToolCall(id: .init(rawValue: "call-1"), name: "calculator", argumentsJSON: #"{"a":2,"b":3}"#, completeness: .complete)
        var item = try ProviderJSON.object(deepSeekFunctionItem(call: 1))
        item.removeValue(forKey: "status")
        let state = try #require(try DeepSeekResponsesContinuation.make(items: [.object(item)], content: [], calls: [call], model: model))
        #expect(try DeepSeekResponsesContinuation.restore(content: [.providerContinuation(state)], calls: [call], model: model)?.items == [.object(item)])
    }

    @Test func finalSnapshotMustPreserveArgumentBytes() async throws {
        let arguments = "{\"value\":\"é\"}"
        var item = try ProviderJSON.object(deepSeekFunctionItem(call: 1))
        item["arguments"] = .string(arguments)
        var added = item
        added["arguments"] = .string("")
        added["status"] = .string("in_progress")
        var changed = item
        changed["arguments"] = .string("{\"value\":\"e\u{301}\"}")
        func json(_ object: [String: JSONValue]) throws -> String {
            String(decoding: try JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self)
        }
        let frames: [(String, String)] = [
            ("response.created", #"{"type":"response.created","response":{"id":"r","model":"deepseek-flash","status":"in_progress"}}"#),
            ("response.output_item.added", try json(["type": .string("response.output_item.added"), "output_index": .number(0), "item": .object(added)])),
            ("response.function_call_arguments.delta", try json(["type": .string("response.function_call_arguments.delta"), "output_index": .number(0), "item_id": .string("fc-1"), "delta": .string(arguments)])),
            ("response.function_call_arguments.done", try json(["type": .string("response.function_call_arguments.done"), "output_index": .number(0), "item_id": .string("fc-1"), "arguments": .string(arguments)])),
            ("response.output_item.done", try json(["type": .string("response.output_item.done"), "output_index": .number(0), "item": .object(item)])),
            ("response.completed", try json(["type": .string("response.completed"), "response": .object([
                "id": .string("r"), "model": .string(model.name), "status": .string("completed"), "output": .array([.object(changed)]),
            ])])),
        ]
        let configured = try provider(.high, probe: ProviderRequestProbe(), bodies: [providerNamedSSE(frames)])
        do {
            for try await _ in configured.stream(request: .init(model: model, messages: [.user([.text("Use tool")])])) {}
            Issue.record("Expected argument snapshot mismatch")
        } catch let error as ModelProviderError {
            #expect(error.kind == .invalidResponse)
            #expect(error.diagnostic == .init(stage: .responseValidation, reason: .finalSnapshotMismatch))
        }
    }

    private func provider(_ effort: DeepSeekReasoningEffort, probe: ProviderRequestProbe, bodies: [Data]) throws -> DeepSeekResponsesProvider {
        try .init(apiKey: "fixture-key", reasoningEffort: effort, transport: FixtureHTTPTransport(probe: probe, bodies: bodies))
    }

    private func expectContinuationMismatch(content: [ModelContent], calls: [ToolCall]) throws {
        do {
            _ = try DeepSeekResponsesContinuation.restore(content: content, calls: calls, model: model)
            Issue.record("Expected canonical/native mismatch")
        } catch let error as ModelProviderError {
            #expect(error.kind == .invalidRequest)
            #expect(error.diagnostic == .init(stage: .continuation, reason: .continuationMismatch))
        }
    }

    private func binding(_ provider: DeepSeekResponsesProvider, revision: String = "high", endpoint: String = "fixture", targetModel: ModelID? = nil,
                         projector: any AgentContextProjector = AgentIdentityContextProjector()) throws -> AgentModelBinding {
        try .init(profileID: "deepseek", profileRevision: revision, model: targetModel ?? model, provider: provider,
                  deployment: .init(serviceInstanceID: "fixture", endpointScope: endpoint, apiDialect: "responses"), projector: projector)
    }

    private var serverFailure: Data {
        providerNamedSSE([("response.failed", #"{"type":"response.failed","response":{"error":{"code":"fixture_failure","message":"private detail"}}}"#)])
    }
}

private struct UnresolvedToolProjector: AgentContextProjector {
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        let identity = try await AgentIdentityContextProjector().project(input)
        return .init(messages: identity.messages.filter { if case .tool = $0 { false } else { true } }, plan: identity.plan)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private struct ReplayMutation: AgentTool {
    struct Input: Codable, Sendable { let a: Int; let b: Int }
    struct Output: Codable, Sendable { let sum: Int }
    static let name = "calculator"
    static let description = "Commit a fixture sum"
    static let inputSchema = ToolSchema.object(properties: ["a": .integer, "b": .integer], required: ["a", "b"])
    static let outputSchema = ToolSchema.object(properties: ["sum": .integer], required: ["sum"])
    let probe: ProviderExecutionProbe
    let policy: ToolPolicy
    init(probe: ProviderExecutionProbe) throws {
        self.probe = probe
        policy = try .mutation(authorization: .notRequired, evidence: .none)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "fixture.sum", id: "one"))] }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "fixture.sum", id: "one")], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.record()
        return .init(output: .init(sum: input.a + input.b), receipt: .init(
            operationID: context.idempotencyKey ?? "", status: .succeeded,
            confirmedTargets: [.init(namespace: "fixture.sum", id: "one")], revision: "v1"))
    }
}
