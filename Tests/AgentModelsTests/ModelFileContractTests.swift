import AgentModels
import Foundation
import Testing

@Suite struct ModelFileContractTests {
    @Test func canonicalFileReferenceHasADecodableTypedRepresentation() throws {
        let source = Data(#"{"file":{"_0":{"uri":"https://generativelanguage.googleapis.com/v1beta/files/immutable-report","mediaType":"application/pdf","description":"immutable report","estimatedInputTokens":2000}}}"#.utf8)
        let content = try JSONDecoder().decode(ModelContent.self, from: source)
        let roundTrip = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(JSONValue.self, from: roundTrip) == JSONDecoder().decode(JSONValue.self, from: source))
    }
}
