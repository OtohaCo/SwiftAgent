import AgentModels
@testable import AgentTools
import Foundation
import Testing

/// Cutting an oversized output keeps whole characters and fits the limit.
struct AgentToolResultLimitCutTests {
    @Test(arguments: ["音", "é", "😀", "\"", "\u{01}"])
    func aCutOutputFitsTheLimitAndKeepsWholeCharacters(_ character: String) throws {
        let output = JSONValue.object(["text": .string(String(repeating: character, count: 30_000))])
        let capped = try AgentToolResultLimit.capped(output, limit: AgentToolResultLimit.minimumBytes)
        #expect(try JSONEncoder().encode(capped).count <= AgentToolResultLimit.minimumBytes)
        guard case .object(let fields) = capped, case .string(let partial)? = fields["partial_json"] else {
            Issue.record("Not cut"); return
        }
        #expect(!partial.contains("\u{FFFD}"))
        #expect(partial.hasPrefix(#"{"text":""#))
    }

    @Test func anOutputWithinTheLimitIsUnchanged() throws {
        let output = JSONValue.array([.string("a"), .number(1), .bool(true)])
        #expect(try AgentToolResultLimit.capped(output, limit: AgentToolResultLimit.minimumBytes) == output)
    }
}
