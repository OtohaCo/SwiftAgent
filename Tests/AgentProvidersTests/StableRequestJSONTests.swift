import AgentModels
import Foundation
import Testing
@testable import AgentProviders

/// Services cache a prompt by its prefix: a conversation's earlier turns must be the same bytes in every request of
/// it. JSON objects (a tool's result, the request body) are written with their keys in order, never in a
/// dictionary's order, which differs from one encoding to the next.
struct StableRequestJSONTests {
    private static let keys = (0..<40).map { String(format: "k%02d", $0) }
    private static let result = JSONValue.object(Dictionary(uniqueKeysWithValues: keys.map { ($0, JSONValue.string($0)) }))
    private static let resultText = "{" + keys.map { "\"\($0)\":\"\($0)\"" }.joined(separator: ",") + "}"
    private static let call = ToolCall(id: .init(rawValue: "call-1"), name: "read", argumentsJSON: "{}", completeness: .complete)

    private static func request(provider: String) -> ModelRequest {
        .init(model: .init(provider: provider, name: "fixture"), messages: [
            .user([.text("Read it")]),
            .assistant(content: [], toolCalls: [call]),
            .tool(.init(callID: call.id, content: [.json(result)], isError: false)),
            .assistant(content: [], toolCalls: [call]),
            .tool(.init(callID: call.id, content: [.json(result)], isError: true)),
        ])
    }

    @Test func aToolsResultIsWrittenWithItsKeysInOrder() throws {
        let openAI = try OpenAIResponsesRequestEncoder.encode(
            Self.request(provider: "openai"), maximumOutputTokens: 64, reasoningEffort: nil, reasoningSummary: nil)
        let deepSeek = try DeepSeekResponsesRequestEncoder.encode(
            Self.request(provider: "deepseek"), maximumOutputTokens: 64, reasoningEffort: .none)
        let anthropic = try AnthropicRequestEncoder.encode(
            Self.request(provider: "anthropic"), maximumOutputTokens: 64, thinking: .disabled)
        for (name, body) in [("openai", openAI), ("deepseek", deepSeek), ("anthropic", anthropic)] {
            let text = String(decoding: try ProviderJSON.encode(body), as: UTF8.self)
            #expect(text.contains(Self.resultText.replacingOccurrences(of: "\"", with: "\\\"")), "\(name)")
            // The Responses dialects send a failed tool's result inside an error envelope, a string of its own.
            if name != "anthropic" {
                #expect(text.contains("\\\"content\\\":\\\"" + Self.resultText.replacingOccurrences(of: "\"", with: "\\\\\\\"")), "\(name) error envelope")
            }
        }
    }

    @Test func theRequestBodyIsWrittenWithItsKeysInOrder() async throws {
        let probe = ProviderRequestProbe()
        let completed = providerSSE([
            #"{"type":"response.completed","response":{"id":"r","model":"fixture","status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1}}}"#,
        ])
        let provider = try OpenAIResponsesProvider(apiKey: "k", transport: FixtureHTTPTransport(probe: probe, bodies: [completed]))
        // Only the request matters here, not what the fixture answers.
        do { for try await _ in provider.stream(request: Self.request(provider: "openai")) {} } catch {}
        let body = try #require(await probe.requests.first?.httpBody)
        let reencoded = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: body), options: [.sortedKeys])
        #expect(body == reencoded)
    }
}
