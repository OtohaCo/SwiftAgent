import AgentModels
import Foundation
import Testing
@testable import AgentProviders

struct RefusedToolHistoryTests {
    @Test(arguments: ["missing.tool", "missing:tool", "missing/tool", "bad name"])
    func rejectedUnknownNamesDoNotPreventLaterRequests(name: String) throws {
        let call = ToolCall(id: .init(rawValue: "refused"), name: name, argumentsJSON: "{}", completeness: .complete)
        let history: [ModelMessage] = [
            .user([.text("Try a tool")]), .assistant(content: [], toolCalls: [call]),
            .tool(.init(callID: call.id, content: [.json(.object(["code": .string("unknown_tool"), "name": .string(name)]))], isError: true)),
            .user([.text("Continue")]),
        ]
        let deepSeek = try DeepSeekResponsesRequestEncoder.encode(.init(model: .init(provider: "deepseek", name: "fixture"), messages: history),
            maximumOutputTokens: 64, reasoningEffort: .none)
        guard case .array(let input) = deepSeek["input"] else { Issue.record("missing input"); return }
        guard case .string(let encodedName) = input[1]["name"] else { Issue.record("missing call name"); return }
        #expect(!encodedName.contains(".") && !encodedName.contains(":") && !encodedName.contains("/") && !encodedName.contains(" "))
        let config = try GeminiConfiguration(baseURL: GeminiProvider.defaultBaseURL, streaming: false, thinking: nil, profile: .preserve,
            maximumOutputTokens: nil, maximumRequestBytes: 100_000, maximumResponseBytes: 100_000, authorizationScopeID: "default", caching: .implicit)
        let context = try GeminiRequestEncoder.context(.init(model: .init(provider: "gemini", name: "fixture"), messages: history), configuration: config)
        #expect(context.contents.count == 4)
    }
}
