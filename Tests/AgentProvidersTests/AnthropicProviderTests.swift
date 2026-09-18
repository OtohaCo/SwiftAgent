import AgentModels
import AgentCore
import AgentTools
import Foundation
import Testing
@testable import AgentProviders

struct AnthropicProviderTests {
    @Test func recoverableToolResultEncodesIsErrorTrue() throws {
        let call = ToolCall(id: .init(rawValue: "toolu-error"), name: "search_resource",
                            argumentsJSON: #"{"query":"missing"}"#, completeness: .complete)
        let payload = JSONValue.object(["code": .string("not_found"), "message": .string("No result was found.")])
        let request = ModelRequest(
            model: .init(provider: "anthropic", name: "fixture"),
            messages: [
                .user([.text("Find it")]),
                .assistant(content: [], toolCalls: [call]),
                .tool(.init(callID: call.id, content: [.json(payload)], isError: true)),
            ]
        )
        guard case .object(let body) = try AnthropicRequestEncoder.encode(
            request, maximumOutputTokens: 1_024, thinking: .disabled
        ), case .array(let messages) = body["messages"], case .object(let last) = messages.last,
              case .array(let content) = last["content"], case .object(let result) = content.last else {
            Issue.record("Missing Anthropic tool result")
            return
        }
        #expect(result["is_error"] == .bool(true))
        #expect(result["tool_use_id"] == .string(call.id.rawValue))
    }

    @Test func completedBatchKeepsSnapshotAndGroupsOrderedToolResults() async throws {
        let second = String(decoding: providerSSE([
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu-2","name":"calculator","input":{"a":5,"b":7}}}"#,
            #"{"type":"content_block_stop","index":1}"#,
        ]), as: UTF8.self)
        let wire = String(decoding: anthropicToolFixture, as: UTF8.self)
            .replacingOccurrences(of: "data: {\"type\":\"message_delta\"", with: second + "data: {\"type\":\"message_delta\"")
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe, bodies: [Data(wire.utf8), anthropicTextFixture]))
        let result = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider,
                                     tools: [ProviderCalculator()]).makeSession().run("Compute both").wait()
        #expect(result.toolCalls == 2)
        #expect(result.history.contains { message in
            if case .assistant(let content, let calls) = message, calls.count == 2 {
                return content.contains { if case .providerContinuation = $0 { true } else { false } }
            }
            return false
        })
        let requests = await probe.requests
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last?.httpBody))
        guard case .object(let object) = body, case .array(let messages) = object["messages"] else {
            Issue.record("Missing messages"); return
        }
        #expect(messages.count == 3)
        guard case .object(let last) = messages.last, case .array(let results) = last["content"] else {
            Issue.record("Missing results"); return
        }
        #expect(results == [
            .object(["type": .string("tool_result"), "tool_use_id": .string("toolu-1"), "content": .string("{\"sum\":5}"), "is_error": .bool(false)]),
            .object(["type": .string("tool_result"), "tool_use_id": .string("toolu-2"), "content": .string("{\"sum\":12}"), "is_error": .bool(false)]),
        ])
    }

    @Test func thinkingAndStructuredAnswerConfigurationPreserveTheRequestedSchema() async throws {
        let probe = ProviderRequestProbe()
        let fixture = Data(String(decoding: anthropicTextFixture, as: UTF8.self)
            .replacingOccurrences(of: #""text":"Hello""#, with: #""text":"{\"answer\":\"Hello\"}""#).utf8)
        let provider = try AnthropicProvider(apiKey: "fixture-key", maximumOutputTokens: 2_048,
                                             thinking: .enabled(budgetTokens: 1_024),
                                             transport: FixtureHTTPTransport(probe: probe, bodies: [fixture]))
        let schema = ToolSchema.object(properties: ["answer": .string], required: ["answer"]).json
        let request = ModelRequest(model: .init(provider: "anthropic", name: "fixture"), messages: [.user([.text("Hi")])],
                                   structuredOutput: .init(name: "answer", schema: schema))
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: request) { try accumulator.append(event) }
        #expect(try accumulator.finish().content.first == .text(#"{"answer":"Hello"}"#))
        #expect(provider.descriptor.capabilities.contains(.reasoning))
        #expect(provider.descriptor.capabilities.contains(.structuredOutput))
        let requests = await probe.requests
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: #require(requests.first?.httpBody)) else {
            Issue.record("Missing request"); return
        }
        #expect(body["thinking"] == .object(["type": .string("enabled"), "budget_tokens": .number(1_024)]))
        #expect(body["output_config"] == .object(["format": .object(["type": .string("json_schema"), "schema": schema])]))
        for budget in [0, 1_023, 2_048] {
            #expect(throws: ModelProviderError.self) { try AnthropicProvider(apiKey: "fixture-key", maximumOutputTokens: 2_048, thinking: .enabled(budgetTokens: budget)) }
        }
    }

    @Test func signedThinkingAndUsageSurviveTheToolRoundWithoutProviderSessionState() async throws {
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicThinkingToolFixture, anthropicTextFixture]))
        let run = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider,
                                  tools: [ProviderCalculator()]).makeSession().run("Add 2 and 3")
        var reported: [ModelUsage] = []
        for await event in run.events { if case .model(.usage(let usage)) = event { reported.append(usage) } }
        let result = try await run.wait()
        #expect(result.toolCalls == 1)
        #expect(reported.contains(.init(inputTokens: 10, outputTokens: 7, cachedInputTokens: 2, cacheWriteInputTokens: 3, reasoningTokens: 2)))
        let requests = await probe.requests
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last?.httpBody))
        guard case .object(let object) = body, case .array(let messages) = object["messages"],
              messages.count == 3, case .object(let assistant) = messages[1], case .array(let blocks) = assistant["content"] else {
            Issue.record("Missing assistant continuation"); return
        }
        #expect(blocks.first == .object(["type": .string("thinking"), "thinking": .string("Consider inputs."), "signature": .string("signature-1")]))
        #expect(blocks.count == 2)
        #expect(result.history.contains { message in
            if case .assistant(let content, _) = message { return content.contains { if case .providerContinuation = $0 { true } else { false } } }
            return false
        })
    }

    @Test func sameCoreLoopExecutesToolAndReturnsItsResultThroughTheMessagesAPI() async throws {
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicToolFixture, anthropicTextFixture]))
        let result = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider,
                                     tools: [ProviderCalculator()]).makeSession().run("Add 2 and 3").wait()
        #expect(result.toolCalls == 1)
        #expect(result.modelTurns == 2)
        let requests = await probe.requests
        #expect(requests.count == 2)
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last?.httpBody))
        guard case .object(let object) = body, case .array(let messages) = object["messages"],
              case .object(let last) = messages.last else { Issue.record("Missing tool result request"); return }
        #expect(last["role"] == .string("user"))
        #expect(last["content"] == .array([.object(["type": .string("tool_result"), "tool_use_id": .string("toolu-1"),
                                                    "content": .string("{\"sum\":5}"), "is_error": .bool(false)])]))
    }

    @Test func textStreamAndRequestUseTheMessagesContract() async throws {
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture]))
        let request = ModelRequest(model: .init(provider: "anthropic", name: "fixture"), messages: [.system("Be concise"), .user([.text("Hi")])])
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: request) { try accumulator.append(event) }
        let response = try accumulator.finish()
        #expect(response.content.first == .text("Hello"))
        #expect(response.stopReason == .endTurn)
        #expect(response.usage == .init(inputTokens: 5, outputTokens: 3))
        let requests = await probe.requests
        let sent = try #require(requests.first)
        #expect(sent.url?.path == "/v1/messages")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(sent.httpBody))
        guard case .object(let object) = body else { Issue.record("Missing request object"); return }
        #expect(object["model"] == .string("fixture"))
        #expect(object["stream"] == .bool(true))
        #expect(object["system"] == .string("Be concise"))
        #expect(object["messages"] == .array([.object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("Hi")])])])]))
    }
}

struct ProviderCalculator: AgentTool {
    struct Input: Codable, Sendable { let a: Int; let b: Int }
    struct Output: Codable, Sendable { let sum: Int }
    static let name = "calculator"
    static let description = "Add integers a and b"
    static let inputSchema = ToolSchema.object(properties: ["a": .integer, "b": .integer], required: ["a", "b"])
    static let outputSchema = ToolSchema.object(properties: ["sum": .integer], required: ["sum"])
    let policy: ToolPolicy
    let probe: ProviderExecutionProbe?
    init(probe: ProviderExecutionProbe? = nil) throws {
        self.probe = probe
        policy = try .init(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(2), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe?.record()
        let (sum, overflow) = input.a.addingReportingOverflow(input.b)
        guard !overflow else { throw ModelProviderError(kind: .invalidRequest, message: "Overflow") }
        return .init(output: .init(sum: sum))
    }
}

actor ProviderExecutionProbe {
    private(set) var count = 0
    func record() { count += 1 }
}
