import AgentModels
import Foundation
import XCTest

final class ModelMessageTests: XCTestCase {
    func testConversationPreservesRolesPartsCallOrderAndResultAssociation() throws {
        let search = ToolCall(id: .init(rawValue: "call-search"), name: "search",
                              argumentsJSON: #"{"query":"property"}"#, completeness: .complete)
        let calculator = ToolCall(id: .init(rawValue: "call-calc"), name: "calculator",
                                  argumentsJSON: #"{"a":2,"b":3}"#, completeness: .complete)
        let messages: [ModelMessage] = [
            .system("Answer with verified data."),
            .developer("Use the supplied tools."),
            .user([.text("Find a listing."), .text("Then calculate the total.")]),
            .assistant(content: [.reasoning("Search first."), .text("Checking.")], toolCalls: [search, calculator]),
            .tool(.init(callID: calculator.id, content: [.json(.number(5))], isError: false)),
            .tool(.init(callID: search.id, content: [.text("Unavailable")], isError: true)),
            .assistant(content: [.text("The total is 5; search is unavailable.")], toolCalls: []),
        ]
        let restored = try JSONDecoder().decode([ModelMessage].self, from: JSONEncoder().encode(messages))
        XCTAssertEqual(restored, messages)
        XCTAssertEqual(restored.map(\.role), [.system, .developer, .user, .assistant, .tool, .tool, .assistant])
        guard case .assistant(let parts, let calls) = restored[3],
              case .tool(let result) = restored[4] else { return XCTFail("Missing tool round") }
        XCTAssertEqual(parts, [.reasoning("Search first."), .text("Checking.")])
        XCTAssertEqual(calls.map(\.id.rawValue), ["call-search", "call-calc"])
        XCTAssertEqual(result.callID.rawValue, "call-calc")
        XCTAssertFalse(result.isError)
    }

    func testIncompleteCallPreservesRawArgumentsAndDefaultsToIncomplete() throws {
        let call = ToolCall(id: .init(rawValue: "partial"), name: "calculator", argumentsJSON: #"{"a": "#)
        let restored = try JSONDecoder().decode(ToolCall.self, from: JSONEncoder().encode(call))
        XCTAssertEqual(restored.argumentsJSON, #"{"a": "#)
        XCTAssertEqual(restored.completeness, .incomplete)
        XCTAssertThrowsError(try JSONDecoder().decode(JSONValue.self, from: Data(restored.argumentsJSON.utf8)))
    }

    func testUnknownRoleDoesNotSilentlyBecomeUserContent() {
        XCTAssertThrowsError(try JSONDecoder().decode(ModelRole.self, from: Data(#""unexpected""#.utf8)))
    }

    func testSyntheticSummaryRoundTripsAsAUserMessageBetweenTurns() throws {
        let messages: [ModelMessage] = [
            .system("Prefer identifiers from tool results."),
            .user([.text("Find resources for project A")]),
            .assistant(content: [.text("I found Alpha.")], toolCalls: []),
            .user([.text("Conversation summary:\nGoal: Continue the existing conversation.")]),
            .user([.text("Use the first one.")]),
        ]
        let restored = try JSONDecoder().decode([ModelMessage].self, from: JSONEncoder().encode(messages))
        XCTAssertEqual(restored, messages)
        XCTAssertEqual(restored.map(\.role), [.system, .user, .assistant, .user, .user])
        guard case .user(let summary) = restored[3], case .text(let text)? = summary.first else {
            return XCTFail("Synthetic summary must remain a user message")
        }
        XCTAssertTrue(text.hasPrefix("Conversation summary:"))
        XCTAssertEqual(restored.last, .user([.text("Use the first one.")]))
    }

    func testMissingCompletenessCannotDecodeAsAnExecutableCall() throws {
        let call = ToolCall(id: .init(rawValue: "c1"), name: "calculator", argumentsJSON: "{}", completeness: .complete)
        let encoded = try JSONEncoder().encode(call)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "completeness")
        XCTAssertThrowsError(try JSONDecoder().decode(ToolCall.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
