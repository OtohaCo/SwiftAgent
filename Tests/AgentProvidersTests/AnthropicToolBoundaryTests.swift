import AgentCore
import AgentModels
import Foundation
import Testing
@testable import AgentProviders

struct AnthropicToolBoundaryTests {
    @Test func reasoningOnlyTruncationDoesNotPoisonTheNextUserTurn() async throws {
        let partial = providerSSE([
            #"{"type":"message_start","message":{"id":"partial","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":5,"output_tokens":0}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Consider inputs."}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":7}}"#,
            #"{"type":"message_stop"}"#,
        ])
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe, bodies: [partial, anthropicTextFixture]))
        let session = try Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider).makeSession()
        #expect(try await session.run("Compute").wait().outcome == .incomplete(.maxOutputTokens))
        #expect(try await session.run("Continue").wait().outcome == .completed)
        #expect(await session.history.contains(.assistant(content: [.reasoning("Consider inputs.")], toolCalls: [])))
        let requests = await probe.requests
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last?.httpBody)),
              case .array(let messages) = body["messages"] else { Issue.record("Missing messages"); return }
        #expect(messages == [.object(["role": .string("user"), "content": .array([
            .object(["type": .string("text"), "text": .string("Compute")]),
            .object(["type": .string("text"), "text": .string("Continue")]),
        ])])])
    }

    @Test func truncatedCallRemainsIncompleteAndNeverExecutes() async throws {
        let execution = ProviderExecutionProbe()
        let requestProbe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: requestProbe,
            bodies: [try toolStream(arguments: "{\"a\":2", stop: "max_tokens")]))
        let result = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider,
                                     tools: [ProviderCalculator(probe: execution)]).makeSession().run("Compute").wait()
        #expect(result.outcome == .incomplete(.maxOutputTokens))
        #expect(result.response.toolCalls.first?.completeness == .incomplete)
        #expect(result.response.toolCalls.first?.argumentsJSON == "{\"a\":2")
        #expect(await execution.count == 0)
        #expect(await requestProbe.requests.count == 1)
    }

    @Test func missingTerminalAndTrailingEventsCannotDispatch() async throws {
        let normal = String(decoding: anthropicToolFixture, as: UTF8.self)
        let missing = Data(normal.replacingOccurrences(of: "data: {\"type\":\"message_stop\"}\n\n", with: "").utf8)
        let trailing = anthropicToolFixture + providerSSE([#"{"type":"content_block_stop","index":0}"#])
        let invalid = [missing, trailing]
        for body in invalid {
            let execution = ProviderExecutionProbe()
            let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body]))
            do {
                _ = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider,
                                     tools: [ProviderCalculator(probe: execution)]).makeSession().run("Compute").wait()
                Issue.record("Invalid stream must not succeed")
            } catch { #expect((error as? ModelProviderError)?.kind == .invalidResponse) }
            #expect(await execution.count == 0)
        }
    }

    /// Malformed or ambiguous input is a model mistake: the tool does not run, the model is told,
    /// and the next request replays the call with `{}` input, which the Messages API accepts.
    @Test(arguments: ["{", "{\"a\":2,\"a\":3,\"b\":4}"])
    func malformedArgumentsGoBackToTheModelAndTheNextRequestEncodes(_ arguments: String) async throws {
        let execution = ProviderExecutionProbe()
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe,
            bodies: [try toolStream(arguments: arguments, stop: "tool_use"), anthropicTextFixture]))
        let result = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider,
                                     tools: [ProviderCalculator(probe: execution)]).makeSession().run("Compute").wait()
        #expect(result.outcome == .completed)
        #expect(await execution.count == 0)
        let requests = await probe.requests
        #expect(requests.count == 2)
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last?.httpBody)),
              case .array(let messages) = body["messages"], messages.count == 3,
              case .object(let assistant) = messages[1], case .object(let user) = messages[2],
              case .array(let blocks) = user["content"], case .object(let toolResult) = blocks.last else {
            Issue.record("Missing replayed tool round"); return
        }
        #expect(assistant["content"] == .array([.object(["type": .string("tool_use"), "id": .string("toolu-1"),
                                                         "name": .string("calculator"), "input": .object([:])])]))
        #expect(toolResult["tool_use_id"] == .string("toolu-1"))
        #expect(toolResult["is_error"] == .bool(true))
        guard case .string(let text) = toolResult["content"] else { Issue.record("Missing tool result text"); return }
        #expect(text.contains("invalid_arguments"))
    }

    /// With thinking, the Messages API needs the signed thinking block before a replayed tool call;
    /// replacing invalid input must keep the continuation that carries it.
    @Test func malformedArgumentsAfterThinkingKeepTheSignedThinkingBlock() async throws {
        let thinking = String(decoding: anthropicThinkingToolFixture, as: UTF8.self)
            .replacingOccurrences(of: #"{\"a\":2,\"b\":3}"#, with: #"{\"a\":2,"#)
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe,
            bodies: [Data(thinking.utf8), anthropicTextFixture]))
        let result = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider,
                                     tools: [ProviderCalculator()]).makeSession().run("Compute").wait()
        #expect(result.outcome == .completed)
        let requests = await probe.requests
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last?.httpBody)),
              case .array(let messages) = body["messages"], messages.count == 3,
              case .object(let assistant) = messages[1] else { Issue.record("Missing replayed tool round"); return }
        #expect(assistant["content"] == .array([
            .object(["type": .string("thinking"), "thinking": .string("Consider inputs."), "signature": .string("signature-1")]),
            .object(["type": .string("tool_use"), "id": .string("toolu-1"), "name": .string("calculator"), "input": .object([:])]),
        ]))
    }

    private func toolStream(arguments: String, stop: String) throws -> Data {
        let delta = JSONValue.object(["type": .string("content_block_delta"), "index": .number(0),
                                       "delta": .object(["type": .string("input_json_delta"), "partial_json": .string(arguments)])])
        return providerSSE([
            #"{"type":"message_start","message":{"id":"msg-tool","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":5,"output_tokens":0}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu-1","name":"calculator","input":{}}}"#,
            String(decoding: try JSONEncoder().encode(delta), as: UTF8.self),
            #"{"type":"content_block_stop","index":0}"#,
            "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stop)\"},\"usage\":{\"output_tokens\":7}}",
            #"{"type":"message_stop"}"#,
        ])
    }
}
