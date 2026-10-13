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
    @Test func untrustedDecodeStillValidatesReferenceAndMIME() throws {
        let json = #"{"uri":"http://example.com/report","mediaType":"application/pdf","description":"report","estimatedInputTokens":2000}"#
        #expect(throws: ModelFileReferenceError.invalidReference) {
            try JSONDecoder().decode(ModelFileReference.self, from: Data(json.utf8))
        }
        for invalid in ["https://user:secret@example.com/report", "https://example.com/report#fragment"] {
            #expect(throws: ModelFileReferenceError.invalidReference) {
                try ModelFileReference(uri: URL(string: invalid)!, mediaType: .pdf, description: "report", estimatedInputTokens: 2)
            }
        }
        #expect(throws: ModelFileReferenceError.invalidReference) {
            try ModelFileReference(uri: URL(string: "https://example.com/file")!, mediaType: .plainText, description: "file", estimatedInputTokens: -1)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ModelFileReference.self, from: Data(json.replacingOccurrences(of: "application/pdf", with: "video/mp4").utf8))
        }
    }
    @Test func reflectionRedactsURIAndReferenceIdentityIsExact() throws {
        let file = try ModelFileReference(uri: URL(string: "https://example.com/file?token=secret")!, mediaType: .pdf,
                                          description: "report", estimatedInputTokens: 2)
        #expect(!String(reflecting: file).contains("secret"))
        #expect(!String(describing: Mirror(reflecting: file).children.map { String(describing: $0.value) }).contains("secret"))
        let changed = try ModelFileReference(uri: file.uri, mediaType: .pdf, description: "report", estimatedInputTokens: 3)
        #expect(file != changed)
    }
}
