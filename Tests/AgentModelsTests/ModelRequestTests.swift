import AgentModels
import Foundation
import XCTest

final class ModelRequestTests: XCTestCase {
    func testRequestPreservesToolAndStructuredOutputSchemas() throws {
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#.utf8))
        let output: JSONValue = .object(["type": .string("number")])
        let model = ModelID(provider: "fixture", name: "reasoner")
        let request = ModelRequest(
            model: model,
            messages: [.system("Use evidence."), .developer("Return JSON."), .user([.text("Search.")])],
            tools: [.init(name: "search", description: "Search public resources", inputSchema: schema, outputSchema: output)],
            structuredOutput: .init(name: "answer", description: "Search answer", schema: schema, strict: true)
        )
        let restored = try JSONDecoder().decode(ModelRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(restored, request)
        XCTAssertEqual(restored.messages.map(\.role), [.system, .developer, .user])
        XCTAssertEqual(restored.tools.first?.name, "search")
        XCTAssertEqual(restored.tools.first?.inputSchema, schema)
        XCTAssertEqual(restored.tools.first?.outputSchema, output)
        XCTAssertEqual(restored.structuredOutput?.strict, true)
        XCTAssertNotEqual(model, ModelID(provider: "another-service", name: "reasoner"))
    }

    func testTextOnlyRequestDoesNotInventToolsOrOutputSchema() {
        let request = ModelRequest(model: .init(provider: "fixture", name: "text"), messages: [])
        XCTAssertTrue(request.messages.isEmpty)
        XCTAssertTrue(request.tools.isEmpty)
        XCTAssertNil(request.structuredOutput)
    }
}
