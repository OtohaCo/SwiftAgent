import AgentCore
import AgentModels
import Foundation
import Testing
@testable import AgentProviders

struct AnthropicSyntheticSummaryTests {
    @Test func encoderKeepsSyntheticSummaryAndTheFollowingUserTurn() throws {
        let search = ToolCall(
            id: .init(rawValue: "search-1"),
            name: "search_resource",
            argumentsJSON: #"{"query":"project A"}"#,
            completeness: .complete
        )
        let request = ModelRequest(
            model: .init(provider: "anthropic", name: "fixture"),
            messages: [
                .system("Prefer identifiers from tool results."),
                .user([.text("Find resources for project A")]),
                .assistant(content: [], toolCalls: [search]),
                .tool(.init(
                    callID: search.id,
                    content: [.json(.object([
                        "resources": .array([
                            .object(["id": .string("resource-1"), "name": .string("Alpha")]),
                        ]),
                    ]))],
                    isError: false
                )),
                .assistant(content: [.text("I found Alpha.")], toolCalls: []),
                .user([.text("Conversation summary:\nGoal: Continue the existing conversation.")]),
                .user([.text("Use the first one.")]),
            ]
        )
        let encoded = try AnthropicRequestEncoder.encode(request, maximumOutputTokens: 128, thinking: .disabled)
        guard case .object(let body) = encoded, case .array(let messages) = body["messages"] else {
            Issue.record("Missing Anthropic messages")
            return
        }
        #expect(body["system"] == .string("Prefer identifiers from tool results."))
        #expect(!messages.contains { value in
            guard case .object(let object) = value else { return false }
            return object["role"] == .string("system")
        })
        guard case .object(let last)? = messages.last, last["role"] == .string("user"),
              case .array(let blocks) = last["content"] else {
            Issue.record("Expected merged user content")
            return
        }
        let texts = blocks.compactMap { value -> String? in
            guard case .object(let block) = value, block["type"] == .string("text"),
                  case .string(let text) = block["text"] else { return nil }
            return text
        }
        #expect(texts.contains { $0.hasPrefix("Conversation summary:") })
        #expect(texts.contains("Use the first one."))
        #expect(messages.contains { value in
            guard case .object(let object) = value, object["role"] == .string("assistant"),
                  case .array(let content) = object["content"] else { return false }
            return content.contains {
                guard case .object(let block) = $0 else { return false }
                return block["type"] == .string("tool_use") && block["id"] == .string("search-1")
            }
        })
    }
}
