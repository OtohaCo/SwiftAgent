import AgentCore
import AgentModels
import Foundation
import Testing
@testable import AgentProviders

/// A model that streams tool arguments which are not one JSON object must not end the Run, and the
/// request that tells it so must be accepted by the same provider.
struct InvalidToolArgumentsReplayTests {
    @Test func openAIResponsesReplaysTheCallWithEmptyArgumentsAndAnErrorOutput() async throws {
        let execution = ProviderExecutionProbe()
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe,
            bodies: [truncatingArguments(openAIToolFixture), openAITextFixture]))
        let result = try await Agent(model: .init(provider: "openai", name: "fixture"), provider: provider,
                                     tools: [try ProviderCalculator(probe: execution)]).makeSession().run("Add 2 and 3").wait()
        #expect(result.outcome == .completed)
        #expect(result.toolCalls == 1 && result.modelTurns == 2)
        #expect(await execution.count == 0)
        let input = try await lastResponsesInput(probe)
        // The native item replays from the continuation, with the same replacement as history.
        #expect(input.contains(.object([
            "type": .string("function_call"), "id": .string("fc-1"), "call_id": .string("call-1"),
            "name": .string("calculator"), "arguments": .string("{}"), "status": .string("completed"),
        ])))
        #expect(errorOutput(in: input, callID: "call-1")?.contains("invalid_arguments") == true)
    }

    @Test func deepSeekResponsesReplaysTheCallWithEmptyArgumentsAndAnErrorOutput() async throws {
        let execution = ProviderExecutionProbe()
        let probe = ProviderRequestProbe()
        let provider = try DeepSeekResponsesProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe,
            bodies: [truncatingArguments(deepSeekReasoningToolFixture(call: 1)), deepSeekTextWithoutReasoningFixture]))
        let result = try await Agent(model: .init(provider: "deepseek", name: "deepseek-flash"), provider: provider,
                                     tools: [try ProviderCalculator(probe: execution)]).makeSession().run("Add 2 and 3").wait()
        #expect(result.outcome == .completed)
        #expect(await execution.count == 0)
        let input = try await lastResponsesInput(probe)
        #expect(input.contains {
            guard case .object(let item) = $0 else { return false }
            return item["type"] == .string("function_call") && item["call_id"] == .string("call-1")
                && item["arguments"] == .string("{}")
        })
        // Thinking with tools needs the reasoning replayed; the continuation is kept.
        #expect(input.contains { if case .object(let item) = $0 { item["type"] == .string("reasoning") } else { false } })
        #expect(errorOutput(in: input, callID: "call-1")?.contains("invalid_arguments") == true)
    }
}

/// Cut every copy of the fixture's `{"a":2,"b":3}` arguments to `{"a":2,"b":`, as a model that stops
/// mid-object would, keeping deltas, `done` and the final item consistent with each other.
private func truncatingArguments(_ fixture: Data) -> Data {
    let text = String(decoding: fixture, as: UTF8.self)
    return Data(text.replacingOccurrences(of: #"\"b\":3}"#, with: #"\"b\":"#).utf8)
}

private func lastResponsesInput(_ probe: ProviderRequestProbe) async throws -> [JSONValue] {
    let requests = await probe.requests
    #expect(requests.count == 2)
    guard case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last?.httpBody)),
          case .array(let input) = body["input"] else { throw ModelProviderError(kind: .invalidRequest, message: "Missing input") }
    return input
}

private func errorOutput(in input: [JSONValue], callID: String) -> String? {
    for value in input {
        guard case .object(let item) = value, item["type"] == .string("function_call_output"),
              item["call_id"] == .string(callID), case .string(let output) = item["output"] else { continue }
        return output
    }
    return nil
}
