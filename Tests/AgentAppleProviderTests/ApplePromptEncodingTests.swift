import AgentModels
import Foundation
import Testing
@testable import AgentAppleProvider

struct ApplePromptEncodingTests {
    @Test func recoverableToolResultPreservesIsErrorTrue() throws {
        let call = ToolCall(id: .init(rawValue: "search-error"), name: "search_resource",
                            argumentsJSON: #"{"query":"missing"}"#, completeness: .complete)
        let request = ModelRequest(
            model: AppleFoundationProvider.modelID,
            messages: [
                .user([.text("Find it")]),
                .assistant(content: [], toolCalls: [call]),
                .tool(.init(callID: call.id, content: [.json(.object([
                    "code": .string("not_found"), "message": .string("No result was found."),
                ]))], isError: true)),
            ]
        )
        let encoded = try JSONSerialization.jsonObject(with: ApplePromptEncoding.encode(request)) as? [String: Any]
        let messages = try #require(encoded?["messages"] as? [[String: Any]])
        #expect(messages.last?["isError"] as? Bool == true)
        #expect(messages.last?["callID"] as? String == call.id.rawValue)
    }

    /// What a tool returns is checked by the runtime, not planned by the model: its schema stays out of
    /// the small on-device prompt, as other adapters leave it out of their requests.
    @Test func toolDeclarationsLeaveTheOutputSchemaOut() throws {
        let input: JSONValue = .object(["type": .string("object"), "properties": .object(["query": .object(["type": .string("string")])])])
        let request = ModelRequest(
            model: AppleFoundationProvider.modelID,
            messages: [.user([.text("Find it")])],
            tools: [.init(name: "search_resource", description: "Find resources", inputSchema: input,
                          outputSchema: .object(["type": .string("object"), "description": .string("Every resource found.")]))]
        )
        let encoded = try JSONSerialization.jsonObject(with: ApplePromptEncoding.encode(request)) as? [String: Any]
        let tools = try #require(encoded?["tools"] as? [[String: Any]])
        #expect(Set(tools[0].keys) == ["name", "description", "inputSchema"])
        #expect(tools[0]["name"] as? String == "search_resource")
    }

    @Test func syntheticSummaryStaysAUserRowBetweenConversationTurns() throws {
        let search = ToolCall(
            id: .init(rawValue: "search-1"),
            name: "search_resource",
            argumentsJSON: #"{"query":"project A"}"#,
            completeness: .complete
        )
        let request = ModelRequest(
            model: AppleFoundationProvider.modelID,
            messages: [
                .system("Planner instructions."),
                .developer("Internal only."),
                .user([.text("Find resources for project A")]),
                .assistant(content: [], toolCalls: [search]),
                .tool(.init(
                    callID: search.id,
                    content: [.json(.object(["id": .string("resource-1")]))],
                    isError: false
                )),
                .assistant(content: [.text("I found Alpha.")], toolCalls: []),
                .user([.text("Conversation summary:\nGoal: Continue the existing conversation.")]),
                .user([.text("Use the first one.")]),
            ],
            tools: [.init(name: "search_resource", description: "Find resources", inputSchema: .object(["type": .string("object")]))]
        )
        let encoded = try JSONSerialization.jsonObject(with: ApplePromptEncoding.encode(request)) as? [String: Any]
        let messages = try #require(encoded?["messages"] as? [[String: Any]])
        #expect(!(messages.contains { $0["role"] as? String == "system" }))
        #expect(!(messages.contains { $0["role"] as? String == "developer" }))
        let roles = messages.compactMap { $0["role"] as? String }
        #expect(roles == ["user", "assistant", "tool", "assistant", "user", "user"])
        let contents = messages.compactMap { $0["content"] as? String }
        #expect(contents.contains("Find resources for project A"))
        #expect(contents.contains { $0.hasPrefix("Conversation summary:") })
        #expect(contents.contains("Use the first one."))
        #expect(contents.last == "Use the first one.")
    }
}
