import AgentModels
import Foundation
import Testing

struct ModelConcurrencyTests {
    @Test func requestCanBeConstructedAndEncodedOutsideTheMainActor() async throws {
        let request = try await Task.detached {
            let value = ModelRequest(
                model: .init(provider: "fixture", name: "calculator"),
                messages: [.user([.text("Calculate 2 + 3")])],
                tools: [.init(name: "calculator", description: "Add two numbers",
                              inputSchema: .object(["type": .string("object")]))]
            )
            return try JSONDecoder().decode(ModelRequest.self, from: JSONEncoder().encode(value))
        }.value
        #expect(request.model.name == "calculator")
        #expect(request.messages == [.user([.text("Calculate 2 + 3")])])
    }
}
