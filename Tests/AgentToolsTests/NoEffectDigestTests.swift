import AgentModels
import AgentTools
import Foundation
import Testing

struct NoEffectDigestTests {
    @Test func fixedCrossPlatformGoldenEncoding() throws {
        let fixtures: [(String, String, Int, String)] = [
            (#"{"z":"quote\"\\/\n\u0000","a":[true,null,1.2500]}"#,
             #"{"a":[true,null,1.25],"z":"quote\"\\/\u000a\u0000"}"#, 51,
             "d865addc58dce883a9e325c9b2eb1de62aac74a978beab0dbebe3c6d82404d44"),
            (#"{"汉":"😀","e":"e\u0301"}"#, "{\"e\":\"e\u{0301}\",\"汉\":\"😀\"}", 24,
             "4ae8de3aca341c64065e17cdf70ad402704287952a64ca64a0f79b3a432d76e7"),
            (#"{"n":[0,-0,1e3,1e-6,-12.500,12345678901234567890.125]}"#,
             #"{"n":[0,0,1000,0.000001,-12.5,12345678901234567890.125]}"#, 56,
             "7237f920e822c52acad70c92d0d95661ebfa79b21c78a8edb4805133bf3f30b6"),
        ]
        for (source, canonical, bytes, hash) in fixtures {
            let value = try JSONValue.decodeToolArguments(source)
            #expect(try ToolNoEffectDigest.canonicalBytes(value) == Data(canonical.utf8))
            let binding = try ToolNoEffectDigest.arguments(value)
            #expect(binding.encoding == "swiftagent-json-v1")
            #expect(binding.utf8Bytes == bytes)
            #expect(binding.sha256 == hash)
            #expect(source.utf8.count != binding.utf8Bytes)
        }
        let a = try JSONValue.decodeToolArguments(#"{"b":2,"a":1}"#)
        let b = try JSONValue.decodeToolArguments(#"{ "a":1.0, "b":2e0 }"#)
        #expect(try ToolNoEffectDigest.arguments(a) == ToolNoEffectDigest.arguments(b))
        let x = try ToolNoEffectDigest.arguments(.object(["body": .string("x")]))
        let y = try ToolNoEffectDigest.arguments(.object(["body": .string("y")]))
        #expect(x.utf8Bytes == y.utf8Bytes && x.sha256 != y.sha256)
        let composed = try ToolNoEffectDigest.arguments(.string("é"))
        let decomposed = try ToolNoEffectDigest.arguments(.string("e\u{0301}"))
        #expect(composed != decomposed) // No implicit Unicode normalization.
        #expect(ToolNoEffectDigest.operationKey("abc").sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
