import AgentModels
import Foundation
import Testing

struct NativeDiagnosticCompatibilityTests {
    @Test func preciseInitializerReferencesAndOldExportsRemainUsable() throws {
        let responseFactory: (ResponseInfo, [ModelContent], [ToolCall], ModelUsage, StopReason) -> ModelResponse = ModelResponse.init
        let compactFactory: (ResponseInfo, ModelProviderContinuation?, ModelUsage) -> ModelCompactionResponse = ModelCompactionResponse.init
        let compactReasonFactory: (ResponseInfo, ModelProviderContinuation?, ModelUsage, String?) -> ModelCompactionResponse = ModelCompactionResponse.init
        let info = ResponseInfo(id: "response", model: .init(provider: "fixture", name: "model"))
        let response = responseFactory(info, [.text("answer")], [], .init(), .endTurn)
        let compact = compactFactory(info, nil, .init())
        #expect(compactReasonFactory(info, nil, .init(), "refusal").nativeStopReason == "refusal")
        func oldExport<T: Encodable>(_ value: T, removing: [String]) throws -> Data {
            var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            for key in removing { fields.removeValue(forKey: key) }
            return try JSONSerialization.data(withJSONObject: fields)
        }
        #expect(try JSONDecoder().decode(ModelResponse.self, from: oldExport(response, removing: ["inputTransformations"])) == response)
        #expect(try JSONDecoder().decode(ModelCompactionResponse.self, from: oldExport(compact, removing: ["nativeStopReason", "inputTransformations"])) == compact)
        let snapshot = ModelInputTransformation(kind: "thinking_dropped", reason: "prefix_binding_mismatch", path: "messages.2.content.0", source: nil)
        let event = ModelEvent.inputTransformations([snapshot])
        #expect(try JSONDecoder().decode(ModelEvent.self, from: JSONEncoder().encode(event)) == event)
    }
}
